return {
  no_consumer = true,
  fields      = {
    client_id     = {
      required    = true,
      type        = "string",
    },
    client_secret = {
      required    = true,
      type        = "string",
    },
    issuer        = {
      required    = true,
      type        = "url",
    },
    tokens       = {
      required   = false,
      type       = "array",
      enum       = { "id_token", "access_token" },
      default    = { "id_token", "access_token" },
    },
    redirect_uri  = {
      required    = true,
      type        = "url",
    },
    scopes        = {
      required    = false,
      type        = "array",
      default     = { "openid" },
    },
    claims        = {
      required    = false,
      type        = "array",
      enum        = { "iss", "sub", "aud", "azp", "exp", "iat", "auth_time", "at_hash", "alg", "nbf", "hd" },
      default     = { "iss", "sub", "aud", "azp", "exp", "iat", "at_hash" },
    },
    domains       = {
      required    = false,
      type        = "array",
    },
    max_age       = {
      required    = false,
      type        = "number",
    },
    leeway        = {
      required    = false,
      type        = "number",
      default     = 0,
    },
    http_version  = {
      required    = false,
      type        = "number",
      enum        = { 1.0, 1.1 },
      default     = 1.1,
    },
    ssl_verify    = {
      required    = false,
      type        = "boolean",
      default     = true,
    },
    timeout       = {
      required    = false,
      type        = "number",
      default     = 10000,
    },
  },
}
