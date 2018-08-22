local arguments = require "kong.plugins.jwt-resigner.arguments"
local cache     = require "kong.plugins.jwt-resigner.cache"
local errors    = require "kong.dao.errors"


local get_phase = ngx.get_phase


local function self_check(_, conf)
  local phase = get_phase()
  if phase == "access" or phase == "content" then
    local args = arguments(conf)

    local access_token_jwks_uri = args.get_conf_arg("access_token_jwks_uri")
    if access_token_jwks_uri then
      local ok, err = cache.load_keys(access_token_jwks_uri)
      if not ok then
        return false, errors.schema(err)
      end
    end

    local channel_token_jwks_uri = args.get_conf_arg("channel_token_jwks_uri")
    if channel_token_jwks_uri then
      local ok, err = cache.load_keys(channel_token_jwks_uri)
      if not ok then
        return false, errors.schema(err)
      end
    end

    local ok, err = cache.load_keys("kong")
    if not ok then
      return false, errors.schema(err)
    end
  end

  return true
end


return {
  self_check                                  = self_check,
  fields                                      = {
    realm                                     = {
      required                                = false,
      type                                    = "string",
    },
    access_token_issuer                       = {
      required                                = false,
      type                                    = "string",
      default                                 = "kong"
    },
    access_token_jwks_uri                     = {
      required                                = false,
      type                                    = "url",
    },
    access_token_request_header               = {
      required                                = false,
      type                                    = "string",
      default                                 = "authorization:bearer",
    },
    access_token_leeway                       = {
      required                                = false,
      type                                    = "number",
      default                                 = 0,
    },
    access_token_scopes_required              = {
      required                                = false,
      type                                    = "array",
    },
    access_token_scopes_claim                 = {
      required                                = true,
      type                                    = "array",
      default                                 = {
        "scope"
      },
    },
    access_token_upstream_header              = {
      required                                = false,
      type                                    = "string",
      default                                 = "authorization:bearer",
    },
    access_token_upstream_leeway              = {
      required                                = false,
      type                                    = "number",
      default                                 = 0,
    },
    access_token_introspection_endpoint       = {
      required                                = false,
      type                                    = "url",
    },
    access_token_introspection_authorization  = {
      required                                = false,
      type                                    = "string",
    },
    access_token_introspection_hint           = {
      required                                = false,
      type                                    = "string",
      default                                 = "access_token",
    },
    access_token_introspection_claim          = {
      required                                = false,
      type                                    = "string",
    },
    access_token_signing_algorithm            = {
      required                                = true,
      type                                    = "enum",
      enum = {
        "RS256",
        "RS512",
      },
      default                                 = "RS256",
    },
    verify_access_token_signature             = {
      required                                = false,
      type                                    = "boolean",
      default                                 = true,
    },
    verify_access_token_expiry                = {
      required                                = false,
      type                                    = "boolean",
      default                                 = true,
    },
    verify_access_token_scopes                = {
      required                                = false,
      type                                    = "boolean",
      default                                 = true,
    },
    channel_token_issuer                      = {
      required                                = false,
      type                                    = "string",
      default                                 = "kong"
    },
    channel_token_jwks_uri                    = {
      required                                = false,
      type                                    = "url",
    },
    channel_token_request_header              = {
      required                                = false,
      type                                    = "string",
    },
    channel_token_leeway                      = {
      required                                = false,
      type                                    = "number",
      default                                 = 0,
    },
    channel_token_scopes_required             = {
      required                                = false,
      type                                    = "array",
    },
    channel_token_scopes_claim                = {
      required                                = false,
      type                                    = "array",
      default                                 = {
        "scope"
      },
    },
    channel_token_upstream_header             = {
      required                                = false,
      type                                    = "string",
    },
    channel_token_upstream_leeway             = {
      required                                = false,
      type                                    = "number",
      default                                 = 0,
    },
    channel_token_introspection_endpoint      = {
      required                                = false,
      type                                    = "url",
    },
    channel_token_introspection_hint           = {
      required                                = false,
      type                                    = "string",
    },
    channel_token_introspection_authorization = {
      required                                = false,
      type                                    = "string",
    },
    channel_token_introspection_claim         = {
      required                                = false,
      type                                    = "string",
    },
    channel_token_signing_algorithm           = {
      required                                = true,
      type                                    = "enum",
      enum = {
        "RS256",
        "RS512",
      },
      default                                 = "RS256",
    },
    verify_channel_token_signature            = {
      required                                = false,
      type                                    = "boolean",
      default                                 = true,
    },
    verify_channel_token_expiry               = {
      required                                = false,
      type                                    = "boolean",
      default                                 = true,
    },
    verify_channel_token_scopes               = {
      required                                = false,
      type                                    = "boolean",
      default                                 = true,
    },
  },
}
