-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

require "kong.plugins.openid-connect.env"


local log           = require "kong.plugins.openid-connect.log"
local configuration = require "kong.openid-connect.configuration"
local keys          = require "kong.openid-connect.keys"
local hash          = require "kong.openid-connect.hash"
local utils         = require "kong.tools.utils"
local http          = require "resty.http"
local json          = require "cjson.safe"
local workspaces    = require "kong.workspaces"


local concat        = table.concat
local insert        = table.insert
local ipairs        = ipairs
local encode_base64 = ngx.encode_base64
local type          = type
local ngx           = ngx
local null          = ngx.null
local time          = ngx.time
local sub           = string.sub
local find          = string.find
local fmt           = string.format
local tonumber      = tonumber
local tostring      = tostring
local kong          = kong


local TOKEN_DECODE_OPTS = {
  verify_signature = false,
  verify_claims    = false,
}


local TOKEN_DECODE_SIGNATURE_OPTS = {
  verify_signature = true,
  verify_claims    = false,
}


local discovery_data = { n = 0 }


local function cache_get(key, opts, func, ...)
  local options
  if type(opts) == "number" then
    options = { ttl = opts }

  elseif type(opts) == "table" then
    options = opts
  end

  return kong.cache:get(key, options, func, ...)
end


local function cache_key(key, entity)
  if not key then
    return nil
  end

  if entity then
    return kong.db[entity]:cache_key(key)
  end

  return key
end


local function cache_invalidate(key)
  return kong.cache:invalidate_local(key)
end


local function get_expiry_and_cache_ttl(token, ttl)
  local expires_in
  if type(token) == "table" then
    if token.expires_in then
      expires_in = tonumber(token.expires_in)
    end

    if not expires_in then
      if token.exp then
        local exp = tonumber(token.exp)
        if exp then
          if exp == 0 then
            expires_in = 0
          else
            expires_in = exp - ttl.now
          end
        end
      end
    end
  end

  local exp
  local cache_ttl
  if not expires_in then
    exp = 0
    cache_ttl = ttl.default_ttl

  elseif expires_in < 0 then
    exp = ttl.now + expires_in

    if ttl.min_ttl and ttl.min_ttl > 0 and expires_in < ttl.min_ttl then
      cache_ttl = ttl.min_ttl
    else
      cache_ttl = ttl.default_ttl
    end

  elseif expires_in == 0 then
    exp = 0
    if ttl.max_ttl and ttl.max_ttl > 0 then
      cache_ttl = ttl.max_ttl
    else
      cache_ttl = 0
    end

  else
    exp = ttl.now + expires_in

    if ttl.max_ttl and ttl.max_ttl > 0 and expires_in > ttl.max_ttl then
      cache_ttl = ttl.max_ttl
    elseif ttl.min_ttl and ttl.min_ttl > 0 and expires_in < ttl.min_ttl then
      cache_ttl = ttl.min_ttl
    else
      cache_ttl = expires_in
    end
  end

  return exp, cache_ttl
end


local function get_secret()
  return encode_base64(utils.get_rand_bytes(24), true)
end


local function cache_issuer(discovery)
  return discovery
end


local function parse_jwt_response(oic, body, headers, ignore_signature, hint)
  local token, jwt
  if type(headers) == "table" then
    local content_type = headers["Content-Type"]
    if type(content_type) == "string" then
      if find(content_type, "application/jwt", 1, true) == 1 or
         find(content_type, hint, 1, true) == 1
      then
        local decoded, err = oic.token:decode(body, ignore_signature and TOKEN_DECODE_OPTS
                                                                      or TOKEN_DECODE_SIGNATURE_OPTS)
        if not decoded then
          if err then
            return nil, "unable to decode jwt response (" .. err .. ")"
          end

          return nil, "unable to decode jwt response"
        end

        if type(decoded) ~= "table" then
          return nil, "invalid jwt response received"
        end

        if type(decoded.payload) ~= "table" then
          return nil, "invalid jwt response payload received"
        end

        token = decoded.payload
        jwt = body

        if hint == "application/token-introspection+jwt" and type(token.token_introspection) == "table" then
          token = token.token_introspection
        end

        log("jwt response received")
      end
    end
  end

  if not token then
    local err
    token, err = json.decode(body)
    if not token then
      if type(body) == "table" then
        token = body -- backward compatibility with older version of Kong OpenID Connect library

      else
        if err then
          return nil, "unable to decode json response (" .. err .. ")"
        end

        return nil, "unable to decode json response"
      end
    end

    if type(token) ~= "table" then
      return nil, "invalid json response received"
    end

    log("json response received")
  end

  return token, nil, jwt
end


local function init_worker()
  if kong.db and kong.db.oic_issuers and ngx.worker.id() == 0 then
    for discovery, err in kong.db.oic_issuers:each() do
      if err then
        log.warn("warmup of issuer cache failed with: ", err)
        break
      end

      local key = cache_key(discovery.issuer, "oic_issuers")
      cache_get(key, nil, cache_issuer, discovery)
    end
  end

  if not kong.worker_events or not kong.worker_events.register then
    return
  end

  kong.worker_events.register(function(data)
    workspaces.set_workspace(data.workspace)
    local operation = data.operation
    log("consumer ", operation or "update", "d, invalidating cache")

    local old_entity = data.old_entity
    local old_username
    local old_custom_id
    if old_entity then
      old_custom_id = old_entity.custom_id
      if old_custom_id and old_custom_id ~= null and old_custom_id ~= "" then
        kong.cache:invalidate(kong.db.consumers:cache_key("custom_id", old_custom_id))
      end

      old_username = old_entity.username
      if old_username and old_username ~= null and old_username ~= "" then
        kong.cache:invalidate(kong.db.consumers:cache_key("username", old_username))
        kong.cache:invalidate(kong.db.consumers:cache_key("username_lower", old_username))
      end
    end

    local entity = data.entity
    if entity then
      local custom_id = entity.custom_id
      if custom_id and custom_id ~= null and custom_id ~= "" and custom_id ~= old_custom_id then
        kong.cache:invalidate(kong.db.consumers:cache_key("custom_id", custom_id))
      end

      local username = entity.username
      if username and username ~= null and username ~= "" and username ~= old_username then
        kong.cache:invalidate(kong.db.consumers:cache_key("username", username))
        kong.cache:invalidate(kong.db.consumers:cache_key("username_lower", username))
      end
    end
  end, "crud", "consumers")

  kong.worker_events.register(function(data)
    workspaces.set_workspace(data.workspace)
    local operation = data.operation
    log("issuer ", operation or "update", "d, invalidating cache")

    local old_issuer
    local old_entity = data.old_entity
    if old_entity then
      old_issuer = old_entity.issuer
      kong.cache:invalidate(cache_key(old_issuer, "oic_issuers"))
    end

    local entity = data.entity
    if entity and entity.issuer ~= old_issuer then
      kong.cache:invalidate(cache_key(entity.issuer, "oic_issuers"))
    end
  end, "crud", "oic_issuers")

  if kong.configuration.database == "off" then
    local remove = table.remove
    kong.worker_events.register(function()
      if discovery_data and discovery_data.n > 0 then
        for i = discovery_data.n, 1, -1 do
          local key = cache_key(discovery_data[i].issuer, "oic_issuers")
          cache_invalidate(key)
        end

        discovery_data = { n = 0 }
      end
    end, "openid-connect", "purge-discovery")
    kong.worker_events.register(function(issuer)
      local data = discovery_data[issuer]
      if data then
        if discovery_data and discovery_data.n > 0 then
          for i = discovery_data.n, 1, -1 do
            if discovery_data[i].id == data.id then
              remove(discovery_data, i)
              discovery_data.n = discovery_data.n - 1
              break
            end
          end
          discovery_data[data.id] = nil
          discovery_data[data.issuer] = nil

          local key = cache_key(data.issuer, "oic_issuers")
          cache_invalidate(key)
        end
      end
    end, "openid-connect", "delete-discovery")
  end
end


local function normalize_issuer(issuer)
  if sub(issuer, -1) == "/" then
    return sub(issuer, 1, -2)
  end

  return issuer
end


local function discover(issuer, opts, now, previous)
  opts = opts or {}

  local cdec

  log.notice("loading configuration for ", issuer, " using discovery")
  local claims, err = configuration.load(issuer, opts)
  if type(claims) ~= "string" then
    if previous then
      log.notice("loading configuration for ", issuer, " using discovery failed: ", err or "unknown error",
                 " (falling back to previous configuration)")
      cdec, err = json.decode(previous.configuration)
      if type(cdec) ~= "table" then
        log.notice("decoding previous discovery document failed: ", err or "unknown error",
                   " (falling back to empty configuration)")
        cdec = {
          issuer = issuer,
        }
      end

    else
      log.notice("loading configuration for ", issuer, " using discovery failed: ", err or "unknown error",
                 " (falling back to empty configuration)")
      cdec = {
        issuer = issuer,
      }
    end

  else
    cdec, err = json.decode(claims)
    if type(cdec) ~= "table" then
      if previous then
        log.notice("decoding discovery document failed: ", err or "unknown error",
                   " (falling back to previous configuration)")

        cdec, err = json.decode(previous.configuration)
        if type(cdec) ~= "table" then
          log.notice("decoding previous discovery document failed: ", err or "unknown error",
                     " (falling back to empty configuration)")
          cdec = {
            issuer = issuer,
          }
        end

      else
        log.notice("decoding discovery document failed: ", err or "unknown error",
                   " (falling back to empty configuration)")
        cdec = {
          issuer = issuer,
        }
      end
    end
  end

  local jwks_uri = cdec.jwks_uri
  local jwks
  if type(jwks_uri) == "string" then
    log.notice("loading jwks from ", jwks_uri)
    jwks, err = keys.load(jwks_uri, opts)
    if type(jwks) ~= "string" then
      log.notice("loading jwks from ", jwks_uri, " failed: ", err or "unknown error")

    else
      jwks, err = json.decode(jwks)
      if type(jwks) ~= "table" then
        log.notice("decoding jwks failed: ", err or "unknown error")

      elseif type(jwks.keys) == "table" then
        jwks = jwks.keys
      end
    end
  end

  local jdec = cdec.jwks
  if type(jdec) == "table" then
    if type(jdec.keys) == "table" then
      jdec = jdec.keys
    end

    if type(jwks) ~= "table" then
      jwks = jdec

    else
      for _, jwk in ipairs(jdec) do
        insert(jwks, jwk)
      end
    end
  end

  local extra_jwks_uris = opts.extra_jwks_uris
  if extra_jwks_uris then
    if type(extra_jwks_uris) ~= "table" then
      extra_jwks_uris = { extra_jwks_uris }
    end

    local extra_jwks
    for _, extra_jwks_uri in ipairs(extra_jwks_uris) do
      if type(extra_jwks_uri) ~= "string" then
        log.notice("extra jwks uri is not a string (", tostring(extra_jwks_uri) , ")")

      else
        log.notice("loading extra jwks from ", extra_jwks_uri)
        extra_jwks, err = keys.load(extra_jwks_uri, opts)
        if type(extra_jwks) ~= "string" then
          log.notice("loading extra jwks from ", extra_jwks_uri, " failed: ", err or "unknown error")

        else
          extra_jwks, err = json.decode(extra_jwks)
          if type(extra_jwks) ~= "table" then
            log.notice("decoding extra jwks failed: ", err or "unknown error")

          else
            if type(extra_jwks.keys) == "table" then
              extra_jwks = extra_jwks.keys
            end

            if type(extra_jwks) ~= "table" then
              log.notice("unknown extra jwks format")

            else
              if not jwks then
                jwks = extra_jwks

              else
                for _, extra_jwk in ipairs(extra_jwks) do
                  insert(jwks, extra_jwk)
                end
              end
            end
          end
        end
      end
    end
  end

  if type(jwks) == "table" then
    jwks, err = json.encode(jwks)
    if type(jwks) ~= "string" then
      if previous then
        log.notice("encoding jwks keys failed: ", err or "unknown error",
                   " (falling back to previous keys)")
        jwks = previous.jwks

      else
        log.notice("encoding jwks keys failed: ", err or "unknown error",
                   " (falling back to empty keys)")
        jwks = "[]"
      end
    end

  else
    if previous then
      log.notice("no keys found (falling back to previous keys)")
      jwks = previous.keys

    else
      log.notice("no keys found (falling back to empty keys)")
      jwks = "[]"
    end
  end

  cdec.updated_at = now or time()

  claims, err = json.encode(cdec)
  if type(claims) ~= "string" then
    if previous then
      log.notice("encoding discovery document failed: ", err or "unknown error",
                 " (falling back to previous configuration)")
      claims = previous.configuration

    else
      log.notice("encoding discovery document failed: ", err or "unknown error",
                 " (falling back to empty configuration)")

      claims = json.encode({
        issuer = issuer,
      })
    end
  end

  return claims, jwks
end


local function issuer_select(issuer)
  if discovery_data[issuer] then
    return discovery_data[issuer]
  end

  local discovery, err = kong.db.oic_issuers:select_by_issuer(issuer)
  if err then
    log.notice("unable to load discovery data (", err, ")")
  end

  return discovery
end


local issuers = {}


function issuers.rediscover(issuer, opts)
  opts = opts or {}

  issuer = normalize_issuer(issuer)

  log.notice("loading configuration for ", issuer, " from database")

  local discovery = issuer_select(issuer)

  local now = time()

  if discovery then
    local cdec, err = json.decode(discovery.configuration)
    if not cdec then
      return nil, "decoding discovery document failed with " .. err
    end

    local rediscovery_lifetime = opts.rediscovery_lifetime or 30

    local updated_at = cdec.updated_at or 0
    local secs_passed = now - updated_at
    if secs_passed < rediscovery_lifetime then
      log.notice("openid connect rediscovery was done recently (", rediscovery_lifetime - secs_passed,
                 " seconds until next rediscovery)")
      return discovery.keys
    end
  end

  local claims, jwks = discover(issuer, opts, now, discovery)
  if not claims or not jwks then
    log.notice("openid connect rediscovery failed")
  end

  if not discovery then
    discovery = issuer_select(issuer)
  end

  if discovery then
    local data = {
      issuer        = discovery.issuer,
      configuration = claims or discovery.configuration,
      keys          = jwks   or discovery.keys,
      secret        = discovery.secret,
    }

    if kong.configuration.database == "off" then
      data.id = discovery.id
      data.created_at = discovery.created_at

      if discovery_data[data.issuer] then
        for i = 1, discovery_data.n do
          if discovery_data[i].id == data.id then
            discovery_data[i] = data
            break
          end
        end

      else
        discovery_data.n = discovery_data.n + 1
        discovery_data[discovery_data.n] = data
      end

      discovery_data[data.id] = data
      discovery_data[data.issuer] = data

    else
      local stored_data, err = kong.db.oic_issuers:upsert({ id = discovery.id }, data)
      if not stored_data then
        log.warn("unable to upsert issuer ", data.issuer, " discovery documents in database (",
                 err or "unknown error", ")")
      else
        data = stored_data
      end
    end

    return data.keys

  else
    local data = {
      issuer        = issuer,
      configuration = claims or {},
      keys          = jwks   or {},
      secret        = get_secret(),
    }

    if kong.configuration.database == "off" then
      data.id = utils.uuid()
      data.created_at = now
      discovery_data.n = discovery_data.n + 1
      discovery_data[discovery_data.n] = data
      discovery_data[data.id] = data
      discovery_data[data.issuer] = data

    else
      local stored_data, err = kong.db.oic_issuers:upsert_by_issuer(data.issuer, data)
      if not stored_data then
        log.warn("unable to upsert issuer ", issuer, " discovery documents in database (", err
                 or "unknown error", ")")

        discovery = issuer_select(issuer)
        if discovery then
          return discovery.keys
        end

      else
        data = stored_data
      end
    end

    return data.keys
  end
end


local function issuers_init(issuer, opts)
  issuer = normalize_issuer(issuer)

  log.notice("loading configuration for ", issuer, " from database")

  local discovery = issuer_select(issuer)
  if discovery then
    return discovery
  end

  local now = time()

  local claims, jwks = discover(issuer, opts or {}, now)
  if not claims then
    return nil, "openid connect discovery failed"
  end

  discovery = issuer_select(issuer)
  if discovery then
    return discovery
  end

  local data = {
    issuer        = issuer,
    configuration = claims or {},
    keys          = jwks   or {},
    secret        = get_secret(),
  }

  if kong.configuration.database == "off" then
    data.id = utils.uuid()
    data.created_at = now
    discovery_data.n = discovery_data.n + 1
    discovery_data[discovery_data.n] = data
    discovery_data[data.id] = data
    discovery_data[data.issuer] = data

  else
    local stored_data, err = kong.db.oic_issuers:upsert_by_issuer(data.issuer, data)
    if not stored_data then
      log.err("unable to upsert ", data.issuer, " discovery documents in database (", err, ")")

      discovery = issuer_select(data.issuer)
      if discovery then
        return discovery
      end

      if not data.id then
        data.id = utils.uuid()
      end

      if not data.created_at then
        data.created_at = time()
      end
    end
  end

  return data
end


function issuers.load(issuer, opts)
  issuer = normalize_issuer(issuer)

  local key = cache_key(issuer, "oic_issuers")
  return cache_get(key, nil, issuers_init, issuer, opts)
end

local function log_multiple_matches(subject, matches)
  local match_info = {}

  for _, match in pairs(matches) do
    table.insert(match_info, fmt("%s (id: %s)", match.username, match.id))
  end
  log.notice(fmt("multiple consumers match '%s' by username case-insensitively: %s",
                 subject,
                 table.concat(match_info, ", ")))
end

local consumers = {}

local function consumers_load(subject, key, by_username_ignore_case)
  if not subject or subject == "" then
    return nil, "unable to load consumer by a missing subject"
  end

  local result, err

  log.notice("loading consumer by ", key, " using ", subject)

  if key == "id" then
    if utils.is_valid_uuid(subject) then
      result, err = kong.db.consumers:select({ id = subject })
    end

  elseif key == "username" then
    result, err = kong.db.consumers:select_by_username(subject)
    if not result and by_username_ignore_case then
      result, err = kong.db.consumers:select_by_username_ignore_case(subject)
      if #result > 1 then
        log_multiple_matches(subject, result)
      end

      result = result[1]
    end
  elseif key == "custom_id" then
    result, err = kong.db.consumers:select_by_custom_id(subject)
  else
    return nil, "consumer cannot be loaded by " .. key
  end

  if type(result) == "table" then
    return result
  end

  if err then
    log.notice("failed to load consumer by ", key, " (", err, ")")
  else
    log.notice("failed to load consumer by ", key)
  end

  return nil, err
end


function consumers.load(subject, anonymous, consumer_by, ttl, by_username_ignore_case)
  local field_names
  -- when `anonymous` is set, expect format to be either "id" or "username"
  if anonymous then
    field_names = { "id", "username" }

  -- allow overwrites with `consumer_by`
  elseif consumer_by then
    field_names = consumer_by

  -- by default, search for all known fields -> custom_id, username and uuid
  else
    field_names = { "custom_id", "username", "id" }
  end

  local err
  for _, field_name in ipairs(field_names) do
    local key

    if field_name == "id" then
      key = kong.db.consumers:cache_key(subject)

    elseif field_name == "username" and by_username_ignore_case then
      key = kong.db.consumers:cache_key(field_name .. "_lower", subject)

    else
      key = kong.db.consumers:cache_key(field_name, subject)
    end

    local consumer
    consumer, err = cache_get(key, ttl, consumers_load, subject, field_name, by_username_ignore_case)
    if consumer then
      return consumer
    end
  end

  return nil, err
end


local kong_oauth2 = {}


local function kong_oauth2_credential(credential)
  return kong.db.oauth2_credentials:select(credential)
end


local function kong_oauth2_consumer(consumer)
  return kong.db.consumers:select(consumer)
end


local function kong_oauth2_load(access_token, ttl)
  log.notice("loading kong oauth2 token from database")
  local token, err = kong.db.oauth2_tokens:select_by_access_token(access_token)
  if err then
    return nil, err
  end

  if not token then
    return nil, "unable to load kong oauth2 token from database"
  end

  local _, cache_ttl = get_expiry_and_cache_ttl(token, ttl)

  return token, nil, cache_ttl
end


function kong_oauth2.load(ctx, access_token, ttl, use_cache)
  local key = cache_key(access_token, "oauth2_tokens")
  local token
  local err

  if use_cache then
    token, err = cache_get(key, ttl, kong_oauth2_load, access_token, ttl)
    if not token then
      return nil, err
    end

    local exp = get_expiry_and_cache_ttl(token, ttl)
    if exp ~= 0 and exp < ttl.now then
      cache_invalidate(key)
      token, err = kong_oauth2_load(access_token, ttl)
    end

  else
    token, err = kong_oauth2_load(access_token, ttl)
  end

  if not token then
    return nil, err or "kong oauth was not found"
  end

  if not token.access_token or token.access_token ~= access_token then
    return nil, "kong oauth access token was not found"
  end

  if token.service and ctx.service and ctx.service.id ~= token.service.id then
    return nil, "kong access token is for different service"
  end

  local ttl_new
  local exp = get_expiry_and_cache_ttl(token, ttl)
  if exp > 0 then
    local iat = token.created_at
    if (ttl.now - iat) > (exp - ttl.now) then
      return nil, "kong access token has expired"
    end

    local token_ttl = exp - ttl.now
    if token_ttl > 0 then
      if ttl.max_ttl and ttl.max_ttl > 0 then
        if token_ttl > ttl.max_ttl then
          token_ttl = ttl.max_ttl
        end
      end

      if ttl.min_ttl and ttl.min_ttl > 0 then
        if token_ttl < ttl.min_ttl then
          token_ttl = ttl.min_ttl
        end
      end

      ttl_new = {
        ttl = token_ttl,
        neg_ttl = ttl.neg_ttl,
        resurrect_ttl = ttl.resurrect_ttl,
      }

    else
      ttl_new = ttl
    end

  else
    ttl_new = ttl
  end

  local credential_cache_key = cache_key(token.credential.id, "oauth2_credentials")
  local credential
  credential, err = cache_get(credential_cache_key, ttl_new, kong_oauth2_credential, token.credential)
  if not credential then
    return nil, err
  end

  local consumer_cache_key = cache_key(credential.consumer.id, "consumers")
  local consumer
  consumer, err = cache_get(consumer_cache_key, ttl_new, kong_oauth2_consumer, credential.consumer)
  if not consumer then
    return nil, err
  end

  return token, nil, credential, consumer
end


local introspection = {}


local function introspection_load(oic, access_token, hint, ttl, ignore_signature, opts)
  log.notice("introspecting access token with identity provider")
  local body, err, headers = oic.token:introspect(access_token, hint or "access_token", opts)
  if not body then
    return nil, err or "unable to introspect token"
  end

  local token
  local jwt

  token, err, jwt = parse_jwt_response(oic, body, headers, ignore_signature, "application/token-introspection+jwt")
  if not token then
    if err then
      return nil, "unable to parse introspection response: " .. err
    else
      return nil, "unable to parse introspection response"
    end
  end

  local exp, cache_ttl = get_expiry_and_cache_ttl(token, ttl)

  return { exp, token, jwt }, nil, cache_ttl
end


function introspection.load(oic, access_token, hint, ttl, use_cache, ignore_signature, opts)
  if not access_token then
    return nil, "no access token given for token introspection"
  end

  local key = cache_key(encode_base64(hash.S256(concat({
    opts.introspection_endpoint or oic.configuration.issuer,
    access_token
  }, "#introspection=")), true))

  local res
  local err

  if use_cache and key then
    res, err = cache_get("oic:" .. key, ttl, introspection_load, oic, access_token, hint, ttl, ignore_signature, opts)
    if type(res) ~= "table" then
      return nil, err or "unable to introspect token"
    end

    local exp = res[1]
    if exp ~= 0 and exp < ttl.now then
      cache_invalidate("oic:" .. key)
      res, err = introspection_load(oic, access_token, hint, ttl, ignore_signature, opts)
    end

  else
    res, err = introspection_load(oic, access_token, hint, ttl, ignore_signature, opts)
  end

  if type(res) ~= "table" then
    return nil, err or "unable to introspect token"
  end

  local token = res[2]
  local jwt   = res[3]
  return token, nil, jwt
end


local tokens = {}


local function tokens_load(oic, args, ttl)
  log.notice("loading tokens from the identity provider")
  local tokens_encoded, err, headers = oic.token:request(args)
  if not tokens_encoded then
    return nil, err
  end

  local exp, cache_ttl = get_expiry_and_cache_ttl(tokens_encoded, ttl)

  return { exp, tokens_encoded, headers }, nil, cache_ttl
end


function tokens.load(oic, args, ttl, use_cache, flush, salt)
  local iss = oic.configuration.issuer
  local key
  local res
  local err

  if use_cache or flush then
    if args.grant_type == "refresh_token" then
      if not args.refresh_token then
        return nil, "no credentials given for refresh token grant"
      end

      key = cache_key(encode_base64(hash.S256(concat {
        iss,
        "#grant_type=refresh_token&",
        args.refresh_token,
        salt and "&",
        salt,
      }), true))

    elseif args.grant_type == "password" then
      if not args.username or not args.password then
        return nil, "no credentials given for password grant"
      end

      key = cache_key(encode_base64(hash.S256(concat {
        iss,
        "#grant_type=password&",
        args.username,
        "&",
        args.password,
        salt and "&",
        salt,
      }), true))

    elseif args.grant_type == "client_credentials" then
      if not ((args.client_id and args.client_secret) or args.assertion) then
        return nil, "no credentials given for client credentials grant"
      end

      if args.assertion then
        key = cache_key(encode_base64(hash.S256(concat {
          iss,
          "#grant_type=client_credentials&",
          args.assertion,
          salt and "&",
          salt,
        }), true))

      else
        key = cache_key(encode_base64(hash.S256(concat {
          iss,
          "#grant_type=client_credentials&",
          args.client_id,
          "&",
          args.client_secret,
          salt and "&",
          salt,
        }), true))
      end
    end

    if flush and key then
      cache_invalidate("oic:" .. key)
    end
  end

  if use_cache and key then
    res, err = cache_get("oic:" .. key, ttl, tokens_load, oic, args, ttl)
    if type(res) ~= "table" then
      return nil, err or "unable to exchange credentials"
    end

    local exp = res[1]
    if exp ~= 0 and exp < ttl.now then
      cache_invalidate("oic:" .. key)
      res, err = tokens_load(oic, args, ttl)
    end

  else
    res, err = tokens_load(oic, args, ttl)
  end

  if not res then
    return nil, err or "unable to exchange credentials"
  end

  local tokens_encoded = res[2]
  local headers        = res[3]

  return tokens_encoded, nil, headers
end


local token_exchange = {}


local function token_exchange_load(endpoint, opts)
  log.notice("exchanging access token")
  local httpc = http.new()

  if httpc.set_timeouts then
    httpc:set_timeouts(opts.timeout, opts.timeout, opts.timeout)

  else
    httpc:set_timeout(opts.timeout)
  end

  if httpc.set_proxy_options and (opts.http_proxy  or
                                  opts.https_proxy) then
    httpc:set_proxy_options({
      http_proxy                = opts.http_proxy,
      http_proxy_authorization  = opts.http_proxy_authorization,
      https_proxy               = opts.https_proxy,
      https_proxy_authorization = opts.https_proxy_authorization,
      no_proxy                  = opts.no_proxy,
    })
  end

  local res = httpc:request_uri(endpoint, opts)
  if not res then
    local err
    res, err = httpc:request_uri(endpoint, opts)
    if not res then
      return nil, err
    end
  end

  local body = res.body
  if sub(body, -1) == "\n" then
    body = sub(body, 1, -2)
  end

  return { body, res.status }
end


function token_exchange.load(access_token, endpoint, opts, ttl, use_cache)
  if not access_token then
    return nil, "no access token given for token exchange"
  end

  if not endpoint then
    return nil, "no token exchange endpoint given for token exchange"
  end

  local key = cache_key(encode_base64(hash.S256(concat({
    endpoint,
    access_token
  }, "#exchange=")), true))

  local res
  local err

  if use_cache and key then
    res, err = cache_get("oic:" .. key, ttl, token_exchange_load, endpoint, opts)
    if not res then
      return nil, err or "unable to exchange access token"
    end

  else
    res, err = token_exchange_load(endpoint, opts)
  end

  if not res then
    if err then
      return nil, err, 500

    else
      return nil, "unexpected error on token exchange", 500
    end
  end

  local token  = res[1]
  local status = res[2]

  return token, nil, status
end


local userinfo = {}


local function userinfo_load(oic, access_token, ttl, ignore_signature, opts)
  log.notice("loading user info using access token from identity provider")

  local body, err, headers = oic:userinfo(access_token, opts)
  if not body then
    return nil, err
  end

  local token
  local jwt

  token, err, jwt = parse_jwt_response(oic, body, headers, ignore_signature, "application/userinfo+jwt")
  if not token then
    if err then
      return nil, "unable to parse userinfo response: " .. err
    else
      return nil, "unable to parse userinfo response"
    end
  end

  local exp, cache_ttl = get_expiry_and_cache_ttl(token, ttl)

  return { exp, token, jwt }, nil, cache_ttl
end


function userinfo.load(oic, access_token, ttl, use_cache, ignore_signature, opts)
  if not access_token then
    return nil, "no access token given for user info"
  end

  local key = cache_key(encode_base64(hash.S256(concat({
    oic.configuration.issuer,
    access_token
  }, "#userinfo=")), true))

  local res, err
  if use_cache and key then
    res, err = cache_get("oic:" .. key, ttl, userinfo_load, oic, access_token, ttl, ignore_signature, opts)
    if type(res) ~= "table" then
      return nil, err or "unable to load user info"
    end

    local exp = res[1]
    if exp ~= 0 and exp < ttl.now then
      cache_invalidate("oic:" .. key)
      res, err = userinfo_load(oic, access_token, ttl, ignore_signature, opts)
    end
  else
    res, err = userinfo_load(oic, access_token, ttl, ignore_signature, opts)
  end

  if type(res) ~= "table" then
    return nil, err or "unable to load user info"
  end

  local token = res[2]
  local jwt   = res[3]

  return token, nil, jwt
end


return {
  init_worker    = init_worker,
  keys           = keys,
  issuers        = issuers,
  consumers      = consumers,
  kong_oauth2    = kong_oauth2,
  introspection  = introspection,
  tokens         = tokens,
  token_exchange = token_exchange,
  userinfo       = userinfo,
  discovery_data = discovery_data,
}
