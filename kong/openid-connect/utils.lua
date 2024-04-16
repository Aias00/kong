-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local random = require "kong.openid-connect.random"
local codec  = require "kong.openid-connect.codec"
local jws    = require "kong.openid-connect.jws"
local uri    = require "kong.openid-connect.uri"


local table_merge = require("kong.tools.table").table_merge


local base64url = codec.base64url
local tostring  = tostring
local time      = ngx.time


local function generate_client_secret_jwt(client_id, client_secret, endpoint, client_alg)
  local alg = client_alg
  if alg ~= "HS256" and alg ~= "HS384" and alg ~= "HS512" then
    alg = "HS256"
  end

  local iat = time()
  local exp = iat + 60

  local payload = {
    iss = client_id,
    sub = client_id,
    aud = endpoint,
    jti = base64url.encode(random(32)),
    exp = exp,
    iat = iat,
  }

  local jwk = {
    alg = alg,
    k   = base64url.encode(client_secret),
  }

  jwk.kid = nil

  local signed_token, err = jws.encode({
    payload = payload,
    jwk     = jwk,
  })

  if not signed_token then
    return nil, "unable to encode JWT for client secret jwt authentication (" .. err .. ")"
  end

  return signed_token
end


local function generate_private_key_jwt(client_id, client_jwk, endpoint)
  local iat = time()
  local exp = iat + 60

  local payload = {
    iss = client_id,
    sub = client_id,
    aud = endpoint,
    jti = base64url.encode(random(32)),
    exp = exp,
    iat = iat,
  }

  local signed_token, err = jws.encode({
    payload = payload,
    jwk     = client_jwk,
  })

  if not signed_token then
    return nil, "unable to encode JWT for private key jwt authentication (" .. err .. ")"
  end

  return signed_token
end


local function generate_request_object(client_id, client_jwk, endpoint, args)
  local iat = time()
  local exp = iat + 60

  local payload = {
    iss = client_id,
    aud = endpoint,
    jti = base64url.encode(random(32)),
    exp = exp,
    iat = iat,
  }

  if args then
    payload = table_merge(payload, args)
  end

  local signed_token, err = jws.encode({
    payload = payload,
    jwk     = client_jwk,
  })

  if not signed_token then
    return nil, "unable to encode JWT for request object usage (" .. err .. ")"
  end

  return signed_token
end


-- Returns a pool key for the httpc connection pool which includes the client
-- certificate hash.
--
-- This prevents reusing non-mTLS connections (e.g. opened during requests to
-- the configuration endpoint) for mTLS requests (i.e. to the token endpoint)
--
-- see: https://github.com/ledgetech/lua-resty-http/blob/4ab4269cf442ba52507aa2
--      c718f606054452fcad/lib/resty/http_connect.lua#L165-L172
local function pool_key(endpoint, ssl_verify, cert_hash, proxy_uri, proxy_authorization)
  local parsed_url, err = uri.parse(endpoint)
  if not parsed_url then
    return nil, "endpoint url parsing failed: " .. err
  end

  return (parsed_url.scheme or "")
          .. ":" .. (parsed_url.host or "")
          .. ":" .. (parsed_url.port or "")
          .. ":" .. tostring(ssl_verify)
          .. ":" .. (proxy_uri or "")
          .. ":" .. (parsed_url.scheme == "https" and proxy_authorization or "")
          .. ":" .. (cert_hash or "")
end


return {
  generate_client_secret_jwt = generate_client_secret_jwt,
  generate_private_key_jwt = generate_private_key_jwt,
  generate_request_object = generate_request_object,
  pool_key = pool_key,
}
