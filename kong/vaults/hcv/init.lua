-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]


local cjson = require("cjson.safe").new()
local http = require "resty.aws.request.http.http"


local decode_json = cjson.decode
local encode_json = cjson.encode
local type = type
local byte = string.byte
local sub = string.sub
local fmt = string.format


local SLASH = byte("/")


local REQUEST_OPTS = {
  headers = {
    ["X-Vault-Token"] = ""
  },
  -- TODO: turned off because CLI does not currently support trusted certificates
  ssl_verify = false,
}


local function request(conf, resource, version)
  local client, err = http.new()
  if not client then
    return nil, err
  end

  local mount = conf.mount
  if mount then
    if byte(mount, 1, 1) == SLASH then
      if byte(mount, -1) == SLASH then
        mount = sub(mount, 2, -2)
      else
        mount = sub(mount, 2)
      end

    elseif byte(mount, -1) == SLASH then
      mount = sub(mount, 1, -2)
    end

  else
    mount = "secret"
  end

  local protocol = conf.protocol or "http"
  local host = conf.host or "127.0.0.1"
  local port = conf.port or 8200

  local path
  if conf.kv == "v2" then
    if version then
      path = fmt("%s://%s:%d/v1/%s/data/%s?version=%d", protocol, host, port, mount, resource, version)
    else
      path = fmt("%s://%s:%d/v1/%s/data/%s", protocol, host, port, mount, resource)
    end

  else
    path = fmt("%s://%s:%d/v1/%s/%s", protocol, host, port, mount, resource)
  end

  REQUEST_OPTS.headers["X-Vault-Token"] = conf.token

  local res

  res, err = client:request_uri(path, REQUEST_OPTS)
  if err then
    return nil, err
  end

  local status = res.status
  if status == 404 then
    return nil, "not found"
  elseif status ~= 200 then
    return nil, fmt("invalid status code (%d), 200 was expected", res.status)
  else
    return res.body
  end
end


local function get(conf, resource, version)
  local secret, err = request(conf, resource, version)
  if not secret then
    return nil, fmt("unable to retrieve secret from vault: %s", err)
  end

  local json
  json, err = decode_json(secret)
  if type(json) ~= "table" then
    if err then
      return nil, fmt("unable to json decode value received from vault: %s, ", err)
    end

    return nil, fmt("unable to json decode value received from vault: invalid type (%s), table expected", type(json))
  end

  local data = json.data
  if type(data) ~= "table" then
    return nil, fmt("invalid data received from vault: invalid type (%s), table expected", type(data))
  end

  if conf.kv == "v2" then
    data = data.data
    if type(data) ~= "table" then
      return nil, fmt("invalid data (v2) received from vault: invalid type (%s), table expected", type(data))
    end
  end

  data, err = encode_json(data)
  if not data then
    return nil, fmt("unable to json encode data received from vault: %s", err)
  end

  return data
end


return {
  VERSION = "1.0.0",
  get = get,
  license_required = true,
}
