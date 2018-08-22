local openssl_digest = require "openssl.digest"
local responses = require "kong.tools.responses"
local constants = require "kong.constants"
local singletons = require "kong.singletons"
local ldap_cache = require "kong.plugins.ldap-auth-advanced.cache"
local ldap = require "kong.plugins.ldap-auth-advanced.ldap"

local ffi = require "ffi"


ffi.cdef[[
char *crypt(const char *key, const char *salt);
]]


local function crypt(key, salt)
  return ffi.string(ffi.C.crypt(key, salt))
end


local match = string.match
local lower = string.lower
local find = string.find
local sub = string.sub
local fmt = string.format
local ngx_log = ngx.log
local request = ngx.req
local ngx_error = ngx.ERR
local ngx_debug = ngx.DEBUG
local md5 = ngx.md5
local decode_base64 = ngx.decode_base64
local ngx_socket_tcp = ngx.socket.tcp
local ngx_set_header = ngx.req.set_header
local tostring =  tostring
local ipairs = ipairs
local type = type
local next = next

local AUTHORIZATION = "authorization"
local PROXY_AUTHORIZATION = "proxy-authorization"


local ldap_config_cache = setmetatable({}, { __mode = "k" })


local _M = {}

local function retrieve_credentials(authorization_header_value, conf)
  local username, password
  if authorization_header_value then
    local s, e = find(lower(authorization_header_value), "^%s*" ..
                      lower(conf.header_type) .. "%s+")
    if s == 1 then
      local cred = sub(authorization_header_value, e + 1)
      local decoded_cred = decode_base64(cred)
      username, password = match(decoded_cred, "(.+):(.+)")
    end
  end
  return username, password
end

local function ldap_authenticate(given_username, given_password, conf)
  local is_authenticated
  local err, suppressed_err, ok

  local sock = ngx_socket_tcp()
  sock:settimeout(conf.timeout)
  ok, err = sock:connect(conf.ldap_host, conf.ldap_port)
  if not ok then
    ngx_log(ngx_error, "[ldap-auth-advanced] failed to connect to ", conf.ldap_host,
            ":", tostring(conf.ldap_port),": ", err)
    return nil, err
  end

  if conf.start_tls then
    local success, err = ldap.start_tls(sock)
    if not success then
      return false, err
    end
    local _, err = sock:sslhandshake(true, conf.ldap_host, conf.verify_ldap_host)
    if err ~= nil then
      return false, fmt("failed to do SSL handshake with %s:%s: %s",
                        conf.ldap_host, tostring(conf.ldap_port), err)
    end
  end

  if conf.bind_dn then
    is_authenticated = false
    ok, err = ldap.bind_request(sock, conf.bind_dn, conf.ldap_password)
    if ok then
      local search_results = ldap.search_request(sock, {
        base = conf.base_dn;
        scope = "sub";
        filter = conf.attribute .. "=" .. given_username;
        attrs = "userPassword";
      })
      local user, value = next(search_results)
      if user and type(value.userPassword) == "string" then
        if value.userPassword:match("^%{[Cc][Rr][Yy][Pp][Tt]%}") then
          local hash = value.userPassword:sub(8)
          is_authenticated = crypt(given_password, hash) == hash
        elseif value.userPassword:match("^%{[Ss][Hh][Aa]%}") then
          local hash = decode_base64(value.userPassword:sub(6))
          local digest = openssl_digest.new("sha1"):final(given_password)
          is_authenticated = digest == hash
        elseif value.userPassword:match("^%{[Ss][Ss][Hh][Aa]%}") then
          local hash = decode_base64(value.userPassword:sub(7))
          local salt = hash:sub(21)
          local digest = openssl_digest.new("sha1"):update(given_password):final(salt) .. salt
          is_authenticated = digest == hash
        end
      end
    end
  else
    local who = conf.attribute .. "=" .. given_username .. "," .. conf.base_dn
    is_authenticated, err = ldap.bind_request(sock, who, given_password)
  end

  ok, suppressed_err = sock:setkeepalive(conf.keepalive)
  if not ok then
    ngx_log(ngx_error, "[ldap-auth-advanced] failed to keepalive to ", conf.ldap_host, ":",
            tostring(conf.ldap_port), ": ", suppressed_err)
  end
  return is_authenticated, err
end

local function load_credential(given_username, given_password, conf)
  local ok, err = ldap_authenticate(given_username, given_password, conf)
  if err ~= nil then
    ngx_log(ngx_error, err)
  end

  if ok == nil then
    return nil
  end
  if ok == false then
    return false
  end
  return {username = given_username, password = given_password}
end


local function cache_key(conf, username, password)
  if not ldap_config_cache[conf] then
    ldap_config_cache[conf] = md5(fmt("%s:%u:%s:%s:%u",
      lower(conf.ldap_host),
      conf.ldap_port,
      conf.base_dn,
      conf.attribute,
      conf.cache_ttl
    ))
  end

  return fmt("ldap_auth_cache:%s:%s:%s", ldap_config_cache[conf],
             username, password)
end


local function authenticate(conf, given_credentials)
  local given_username, given_password = retrieve_credentials(given_credentials,
                                                              conf)
  if given_username == nil then
    return false
  end

  local credential, err = singletons.cache:get(cache_key(conf, given_username, given_password), {
    ttl = conf.cache_ttl,
    neg_ttl = conf.cache_ttl
  }, load_credential, given_username, given_password, conf)
  if err or credential == nil then
    return responses.send_HTTP_INTERNAL_SERVER_ERROR(err)
  end

  return credential and credential.password == given_password, credential
end


-- in case of auth plugins concatenation, remove remnants of anonymous
local function remove_headers(consumer)
  ngx.ctx.authenticated_consumer = nil
  ngx_set_header(constants.HEADERS.ANONYMOUS, nil)

  if not consumer then
    ngx_set_header(constants.HEADERS.CONSUMER_ID, nil)
    ngx_set_header(constants.HEADERS.CONSUMER_CUSTOM_ID, nil)
    ngx_set_header(constants.HEADERS.CONSUMER_USERNAME, nil)
  end
end


local function set_consumer(consumer, credential, anonymous)
  if credential then
    ngx_set_header(constants.HEADERS.CREDENTIAL_USERNAME, credential.username)
    ngx.ctx.authenticated_credential = credential
  end

  if consumer and not anonymous then
    ngx_set_header(constants.HEADERS.CONSUMER_ID, consumer.id)
    ngx_set_header(constants.HEADERS.CONSUMER_CUSTOM_ID, consumer.custom_id)
    ngx_set_header(constants.HEADERS.CONSUMER_USERNAME, consumer.username)
    remove_headers(consumer)

    ngx.ctx.authenticated_consumer = consumer
    return
  end

  if consumer and anonymous then
    ngx_set_header(constants.HEADERS.CONSUMER_ID, consumer.id)
    ngx_set_header(constants.HEADERS.CONSUMER_CUSTOM_ID, consumer.custom_id)
    ngx_set_header(constants.HEADERS.CONSUMER_USERNAME, consumer.username)
    ngx_set_header(constants.HEADERS.ANONYMOUS, true)
    ngx.ctx.authenticated_consumer = consumer
    return
  end

  remove_headers()
end


local function find_consumer(consumer_field, value)
  local result, err

  result, err = singletons.dao.consumers:find_all { [consumer_field] = value }

  if err then
    ngx_log(ngx_debug, "failed to load consumer", err)
    return
  end

  return result[1]
end


local function load_consumers(value, consumer_by, ttl)
  local err

  for _, field_name in ipairs(consumer_by) do
    local key
    local consumer

    if field_name == "id" then
      key = singletons.dao.consumers:cache_key(value)
    else
      key = ldap_cache.consumer_field_cache_key(field_name, value)
    end

    consumer, err = singletons.cache:get(key, ttl, find_consumer, field_name,
                                         value)

    if consumer then
      return consumer
    end
  end

  return nil, err
end


local function do_authentication(conf)
  local headers = request.get_headers()
  local authorization_value = headers[AUTHORIZATION]
  local proxy_authorization_value = headers[PROXY_AUTHORIZATION]
  local anonymous = conf.anonymous
  local consumer, err
  local ttl = conf.ttl

  -- If both headers are missing, return 401
  if not (authorization_value or proxy_authorization_value) then
    ngx.header["WWW-Authenticate"] = 'LDAP realm="kong"'
    consumer, err = load_consumers(anonymous, { 'id' }, ttl)

    if err then
      return false, { status = 500 }
    end

    if consumer then
      set_consumer(consumer, nil, anonymous)
      return true
    end

    -- anonymous is configured but doesn't exist
    if anonymous ~= "" and not consumer then
      return false, { status = 500 }
    end

    return false, { status = 401 }
  end

  local is_authorized, credential = authenticate(conf, proxy_authorization_value)
  if not is_authorized then
    is_authorized, credential = authenticate(conf, authorization_value)
  end

  if not is_authorized then
    consumer, err = load_consumers(anonymous, { 'id' }, ttl)
    if consumer then
      set_consumer(consumer, credential, anonymous)
      return true
    end

    if err then
      return false, { status = 500 }
    end

    return false, {status = 403, message = "Invalid authentication credentials"}
  end

  if conf.hide_credentials then
    request.clear_header(AUTHORIZATION)
    request.clear_header(PROXY_AUTHORIZATION)
  end

  if not conf.consumer_optional then
    consumer, err = load_consumers(credential.username, conf.consumer_by, ttl)

    if not consumer then
      if err then
        return false, { status = 403, "kong consumer was not found (" .. err .. ")" }
      end

      consumer, err = load_consumers(anonymous, { 'id' }, ttl)

      if err then
        return false, { status = 403, "kong consumer was not found (" .. err .. ")" }
      end

    else
      -- we found a consumer to map, so no need to fallback to anonymous
      anonymous = nil
    end
  end

  set_consumer(consumer, credential, anonymous)

  return true
end


function _M.execute(conf)
  if ngx.ctx.authenticated_credential and conf.anonymous ~= "" then
    -- we're already authenticated, and we're configured for using anonymous,
    -- hence we're in a logical OR between auth methods and we're already done.
    return
  end

  local ok, err = do_authentication(conf)
  if not ok then
    return responses.send(err.status, err.message)
  end
end


return _M
