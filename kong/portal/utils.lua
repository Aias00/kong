local enums  = require "kong.enterprise_edition.dao.enums"
local ee_jwt = require "kong.enterprise_edition.jwt"
local time   = ngx.time


local _M = {}


-- Validates an email address
_M.validate_email = function(str)
  if str == nil then
    return nil, "missing"
  end

  if type(str) ~= "string" then
    return nil, "must be a string"
  end

  local at = str:find("@")

  if not at then
    return nil, "missing '@' symbol"
  end

  local last_at = str:find("[^%@]+$")

  if not last_at then
    return nil, "missing domain"
  end

  local local_part = str:sub(1, (last_at - 2)) -- Returns the substring before '@' symbol
  -- we werent able to split the email properly
  if local_part == nil or local_part == "" then
    return nil, "missing local-part"
  end

  local domain_part = str:sub(last_at, #str) -- Returns the substring after '@' symbol

  -- This may be redundant
  if domain_part == nil or domain_part == "" then
    return nil, "missing domain"
  end

  -- local part is maxed at 64 characters
  if #local_part > 64 then
    return nil, "local-part over 64 characters"
  end

  -- domains are maxed at 253 characters
  if #domain_part > 253 then
    return nil, "domain over 253 characters"
  end

  local quotes = local_part:find("[\"]")
  if type(quotes) == "number" and quotes > 1 then
    return nil, "local-part invalid quotes"
  end

  if local_part:find("%@+") and quotes == nil then
    return nil, "local-part invalid '@' character"
  end

  if not domain_part:find("%.") then
    return nil, "domain missing '.' character"
  end

  if domain_part:find("%.%.") then
    return nil, "domain cannot contain consecutive '.'"
  end
  if local_part:find("%.%.") then
    return nil, "local-part cannot contain consecutive '.'"
  end

  if not str:match('[%w]*[%p]*%@+[%w]*[%.]?[%w]*') then
    return nil, "invalid format"
  end

  return true
end


_M.get_developer_status = function(consumer)
  local status = consumer.status
  return {
    status = status,
    label  = enums.CONSUMERS.STATUS_LABELS[status],
  }
end


_M.validate_reset_jwt = function(token_param)
  -- Decode jwt
  local jwt, err = ee_jwt.parse_JWT(token_param)
  if err then
    return nil, ee_jwt.INVALID_JWT
  end

  if not jwt.header or jwt.header.typ ~= "JWT" or jwt.header.alg ~= "HS256" then
    return nil, ee_jwt.INVALID_JWT
  end

  if not jwt.claims or not jwt.claims.exp then
    return nil, ee_jwt.INVALID_JWT
  end

  if jwt.claims.exp <= time() then
    return nil, ee_jwt.EXPIRED_JWT
  end

  if not jwt.claims.id then
    return nil, ee_jwt.INVALID_JWT
  end

  return jwt
end


return _M
