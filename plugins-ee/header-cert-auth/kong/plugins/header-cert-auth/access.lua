-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

--- Copyright 2019-2020 Kong Inc.
local _M = {}


local openssl_x509 = require("resty.openssl.x509")
local openssl_x509_chain = require("resty.openssl.x509.chain")
local openssl_x509_store = require("resty.openssl.x509.store")
local cache = require("kong.plugins.header-cert-auth.cache")
local ocsp_client = require("kong.plugins.header-cert-auth.ocsp_client")
local crl_client = require("kong.plugins.header-cert-auth.crl_client")
local constants = require("kong.constants")
local certificate  = require "kong.runloop.certificate"


local kong = kong
local ngx = ngx
local ngx_re_gmatch = ngx.re.gmatch
local ipairs = ipairs
local pairs = pairs
local new_tab = require("table.new")
local tb_concat = table.concat
local table_concat = table.concat
local flag_partial_chain = openssl_x509_store.verify_flags.X509_V_FLAG_PARTIAL_CHAIN
local set_header = kong.service.request.set_header
local clear_header = kong.service.request.clear_header


local function load_credential(cache_key)
  local cred, err = kong.db.header_cert_auth_credentials
                    :select_by_cache_key(cache_key)
  if not cred then
    return nil, err
  end

  return cred
end


local function find_credential(subject_name, ca_id, ttl)
  local opts = {
    ttl = ttl,
    neg_ttl = ttl,
  }

  local credential_cache_key = kong.db.header_cert_auth_credentials
                               :cache_key(subject_name, ca_id)
  local credential, err = kong.cache:get(credential_cache_key, opts,
                                         load_credential, credential_cache_key)
  if err then
    kong.log.err(err)
    return kong.response.exit(500, { message = "An unexpected error occurred" })
  end

  if credential then
    return credential
  end

  -- try wildcard match
  credential_cache_key = kong.db.header_cert_auth_credentials
                         :cache_key(subject_name, nil)
  kong.log.debug("cache key is: ", credential_cache_key)
  credential, err = kong.cache:get(credential_cache_key, nil, load_credential,
                                   credential_cache_key)
  if err then
    kong.log.err(err)
    return kong.response.exit(500, { message = "An unexpected error occurred" })
  end

  return credential
end


local function load_consumer(consumer_field, value)
  local result, err
  local dao = kong.db.consumers

  if consumer_field == "id" then
    result, err = dao:select({ id = value })

  else
     result, err = dao["select_by_" .. consumer_field](dao, value)
  end

  if err then
    return nil, err
  end

  return result
end


local function find_consumer(value, consumer_by, ttl)

  local opts = {
    ttl = ttl,
    neg_ttl = ttl,
  }

  for _, field_name in ipairs(consumer_by) do
    local key, consumer, err

    if field_name == "id" then
      key = kong.db.consumers:cache_key(value)

    else
      key = cache.consumer_field_cache_key(field_name, value)
    end

    consumer, err = kong.cache:get(key, opts, load_consumer, field_name,
                                   value)

    if err then
      kong.log.err(err)
      return kong.response.exit(500, { message = "An unexpected error occurred" })
    end

    if consumer then
      return consumer
    end
  end

  return nil
end


local function set_consumer(consumer, credential)
  if consumer and consumer.id then
    set_header(constants.HEADERS.CONSUMER_ID, consumer.id)

  else
    clear_header(constants.HEADERS.CONSUMER_ID)
  end

  if consumer and consumer.custom_id then
    set_header(constants.HEADERS.CONSUMER_CUSTOM_ID, consumer.custom_id)

  else
    clear_header(constants.HEADERS.CONSUMER_CUSTOM_ID)
  end

  if consumer and consumer.username then
    set_header(constants.HEADERS.CONSUMER_USERNAME, consumer.username)

  else
    clear_header(constants.HEADERS.CONSUMER_USERNAME)
  end

  kong.client.authenticate(consumer, credential)

  if credential then
    if credential.username then
      set_header(constants.HEADERS.CREDENTIAL_IDENTIFIER, credential.username)

    else
      clear_header(constants.HEADERS.CREDENTIAL_IDENTIFIER)
    end

    clear_header(constants.HEADERS.ANONYMOUS)

  else
    clear_header(constants.HEADERS.CREDENTIAL_IDENTIFIER)
    set_header(constants.HEADERS.ANONYMOUS, true)
  end
end


local function parse_fullchain(pem)
  return ngx_re_gmatch(pem,
                      "-----BEGIN CERTIFICATE-----.+?-----END CERTIFICATE-----",
                      "jos")
end


local function get_subject_names_from_cert(x509)
  -- per RFC 6125, check subject alternate names first
  -- before falling back to common name

  local names = new_tab(4, 0)
  local names_n = 0
  local cn
  local dn

  local subj_alt, _ = x509:get_subject_alt_name()

  if subj_alt then
    for _, val in pairs(subj_alt) do
      names_n = names_n + 1
      names[names_n] = val
    end
  end

  local subj, err = x509:get_subject_name()
  if err then
    return nil, nil, nil, err
  end

  if subj then
    local entry, _
    dn = subj:tostring()
    entry, _, err = subj:find("CN")
    if err then
      return nil, nil, err
    end
    if entry then
      names_n = names_n + 1
      names[names_n] = entry.blob
      cn = entry.blob
    end
  end

  return names, cn, dn
end


local authenticate_group_by = {
  ["DN"] = function(cn, dn)
    if not dn then
      return nil, "Certificate missing Subject DN"
    end

    local group = {
      dn
    }
    return group
  end,
  ["CN"] = function(cn, dn)
    if not cn then
      return nil, "Certificate missing Common Name"
    end

    local group = {
      cn
    }
    return group
  end,
}


local hex_to_char = function(x)
  return string.char(tonumber(x, 16))
end


local unescape = function(url)
  return url:gsub("%%(%x%x)", hex_to_char)
end


local function set_cert_headers(names, dn)
  set_header("X-Client-Cert-DN", dn)

  if #names ~= 0 then
    set_header("X-Client-Cert-SAN", table_concat(names, ","))
  end
end


local function is_cert_revoked(conf, proof_chain, store)
  kong.log.debug("cache miss for revocation status")

  local ocsp_status, err = ocsp_client.validate_cert(conf, proof_chain)
  if err then
    kong.log.warn("OCSP verify: ", err)
  end
  -- URI set and no communication error
  if ocsp_status ~= nil then
    return not ocsp_status
  end

  -- no OCSP URI set, check for CRL
  local crl_status
  crl_status, err = crl_client.validate_cert(conf, proof_chain, store)
  if err then
    kong.log.warn("CRL verify: ", err)
  end

  -- URI set and no communication error
  if crl_status ~= nil then
    return not crl_status
  end

  -- returns an error string so that mlcache won't cache the value
  return nil, "fail to check revocation"
end


local function do_authentication(conf)
  local chain = new_tab(2, 0)
  local chain_n = 0
  local it, err

  local pem = kong.request.get_header(conf.certificate_header_name)
  if not pem then
    -- client failed to provide certificate while handshaking
    ngx.ctx.CLIENT_VERIFY_OVERRIDE = "NONE"
    return nil, "No required TLS certificate header was sent"
  end

  -- this can be short-hand, but it's too hard to read tbh
  if conf.certificate_header_format == "base64_encoded" then
    chain_n = chain_n + 1
    chain[chain_n] = string.format("-----BEGIN CERTIFICATE-----\n%s\n-----END CERTIFICATE-----", pem)
  elseif conf.certificate_header_format == "url_encoded" then
    pem = unescape(pem)

    it, err = parse_fullchain(pem)
    if not it then
      kong.log.err(err)
      return kong.response.exit(500, "An unexpected error occurred")
    end

    while true do
      local m, err = it()
      if err then
        kong.log.err(err)
        return kong.response.exit(500, "An unexpected error occurred")
      end

      if not m then
        -- no match found (any more)
        break
      end

      chain_n = chain_n + 1
      chain[chain_n] = m[0]
    end
  end

  local intermediate
  if #chain > 1 then
    intermediate, err = openssl_x509_chain.new()
    if err then
      kong.log.err(err)
      return kong.response.exit(500, "An unexpected error occurred")
    end
  end

  for i, c in ipairs(chain) do
    local x509
    x509, err = openssl_x509.new(c, "PEM")
    if err then
      kong.log.err(err)
      return kong.response.exit(500, "An unexpected error occurred")
    end
    chain[i] = x509

    if i > 1 then
      local _
      _, err = intermediate:add(x509)
      if err then
        kong.log.err(err)
        return kong.response.exit(500, "An unexpected error occurred")
      end
    end
  end

  local ca_ids = conf.ca_certificates

  local store, err = certificate.get_ca_certificate_store_for_plugin(ca_ids)

  if err or not store then
    kong.log.err(err)
    return kong.response.exit(500, "An unexpected error occurred")
  end

  local flags
  if conf.allow_partial_chain then
    flags = flag_partial_chain
  end

  local proof_chain
  proof_chain, err = store:verify(chain[1], intermediate, true, nil, nil, flags)
  if proof_chain then
    local names, cn, dn
    names, cn, dn, err = get_subject_names_from_cert(chain[1])
    if err then
      return nil, err
    end
    kong.log.debug("names = ", tb_concat(names, ", "))

    -- revocation check
    if conf.revocation_check_mode ~= "SKIP" then
      local revoked
      revoked, err = kong.cache:get(dn,
        { ttl = conf.cert_cache_ttl }, is_cert_revoked,
        conf, proof_chain, store)
      if err then
        if conf.revocation_check_mode == "IGNORE_CA_ERROR" and
          err:find("fail to check revocation", nil, true) then
          kong.log.notice(err .. ". Ignored this as `revocation_check_mode` is `IGNORE_CA_ERROR`.")
        else
          kong.log.err(err)
        end
      end

      -- there was communication error or neither of OCSP URI or CRL URI set
      if revoked == nil then
        if conf.revocation_check_mode == "IGNORE_CA_ERROR" then
          revoked = false
        else
          revoked = true
        end
      end

      if revoked == true then
        ngx.ctx.CLIENT_VERIFY_OVERRIDE = "FAILED:certificate revoked"
        return nil, "TLS certificate failed verification"
      end
    end

    if conf.skip_consumer_lookup then
      if conf.authenticated_group_by then
        local group
        group, err = authenticate_group_by[conf.authenticated_group_by](cn, dn)
        if not group then
          return nil, err
        end

        ngx.ctx.authenticated_groups = group
      end
      set_cert_headers(names, dn)
      return true
    end

    -- get the matching CA id
    local ca = proof_chain[#proof_chain]
    local ca_id, err = cache.get_ca_id_from_x509(ca)
    if err then
      return nil, err
    end

    for _, n in ipairs(names) do
      local credential = find_credential(n, ca_id, conf.cache_ttl)
      if credential then
        local consumer = find_consumer(credential.consumer.id, { "id", },
                                       conf.cache_ttl)

        if consumer then
          set_consumer(consumer, { id = consumer.id, })
          return true
        end
      end
    end

    kong.log.debug("unable to match certificate to consumers via credentials")

    local consumer_by = conf.consumer_by

    if consumer_by and #consumer_by > 0 then
      kong.log.debug("auto matching")

      for _, n in ipairs(names) do
        local consumer = find_consumer(n, conf.consumer_by,
                                       conf.cache_ttl)

        if consumer then
          set_consumer(consumer, { id = consumer.id, })
          return true
        end
     end
    end

    local default_consumer = conf.default_consumer
    if default_consumer then
      kong.log.debug("looking up default consumer")

      local consumer_cache_key = kong.db.consumers:cache_key(default_consumer)
      local consumer, err = kong.cache:get(consumer_cache_key, nil,
                                                kong.client.load_consumer,
                                                default_consumer, true)

      if err then
        kong.log.err(err)
        return kong.response.exit(500, { message = "An unexpected error occurred" })
      end

      if consumer then
        kong.log.debug("using default consumer: " .. (consumer.username or consumer.id))
        set_consumer(consumer, { id = consumer.id, })
        set_cert_headers(names, dn)
        return true
      end

      -- default_consumer is configured but doesn't exist
      kong.log.err('default consumer not found with conf.default_consumer="',
                    default_consumer, '"')
      return kong.response.exit(401, { message = "Unauthorized" })
    end

    kong.log.warn("certificate is valid but consumer matching failed, ",
                  "using cn = ", cn,
                  " fields = ", tb_concat(consumer_by, ", "))
    ngx.ctx.CLIENT_VERIFY_OVERRIDE = "FAILED:consumer not found"
  end

  kong.log.err("client certificate verify failed: ", (err and err or "UNKNOWN"))
  ngx.ctx.CLIENT_VERIFY_OVERRIDE = "FAILED:" .. (err and err or "UNKNOWN")

  return nil, "TLS certificate failed verification"
end


function _M.execute(conf)
  if conf.secure_source then
    if not kong.ip.is_trusted(kong.client.get_ip()) then
      return kong.response.exit(403, { message = "Forbidden" })
    end
  end

  if conf.anonymous and kong.client.get_credential() then
    -- we're already authenticated, and we're configured for using anonymous,
    -- hence we're in a logical OR between auth methods and we're already done.
    return
  end

  local res, message = do_authentication(conf)
  if not res then
    -- failed authentication
    if conf.anonymous then
      local consumer_cache_key = kong.db.consumers:cache_key(conf.anonymous)
      local consumer, err = kong.cache:get(consumer_cache_key, nil,
                                                kong.client.load_consumer,
                                                conf.anonymous, true)

      if err then
        kong.log.err(err)
        return kong.response.exit(500, { message = "An unexpected error occurred" })
      end

      if not consumer then
        local err_msg = "anonymous consumer " .. conf.anonymous .. " is configured but doesn't exist"
        kong.log.err(err_msg)
        return kong.response.error(500, err_msg)
      end

      set_consumer(consumer, nil)

    else
      return kong.response.exit(401, { message = message })
    end

  else
    ngx.ctx.CLIENT_VERIFY_OVERRIDE = "SUCCESS"
  end
end


return _M
