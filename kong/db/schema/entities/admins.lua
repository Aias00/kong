local typedefs = require "kong.db.schema.typedefs"
local ee_typedefs = require "kong.enterprise_edition.db.typedefs"

return {
  name         = "admins",
  primary_key  = { "id" },
  endpoint_key = "username",
  dao          = "kong.db.dao.admins",

  fields = {
    { id             = typedefs.uuid },
    { created_at     = typedefs.auto_timestamp_s },
    { updated_at     = typedefs.auto_timestamp_s },
    { username       = { type = "string", unique = true, required = true }, },
    { custom_id      = { type = "string", unique = true }, },
    { email          = ee_typedefs.email { unique = true } },
    { status         = ee_typedefs.admin_status { required = true } },
    { rbac_token_enabled = { type = "boolean", required = true, default = true } },
    { consumer       = { type = "foreign", reference = "consumers", required = true } },
    { rbac_user      = { type = "foreign", reference = "rbac_users", required = true } },
  },
}
