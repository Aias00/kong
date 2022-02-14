-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local utils = require "kong.tools.utils"
local typedefs = require "kong.db.schema.typedefs"


local function check_user(anonymous)
  if anonymous == "" or utils.is_valid_uuid(anonymous) then
    return true
  end

  return false, "the anonymous user must be empty or a valid uuid"
end

local function check_ldaps_tls(entity)
  local ldaps = entity.config.ldaps
  local start_tls = entity.config.start_tls

  if ldaps and start_tls then
    return nil, "ldaps and StartTLS cannot be enabled simultaneously."
  end
  return true
end

-- If you add more configuration parameters, be sure to check if it needs to be added to cache key

return {
  name = "ldap-auth-advanced",
  fields = {
    { consumer = typedefs.no_consumer },
    { config = {
      type = "record",
      fields = {
        { ldap_host = {
          type = "string",
          required = true,
        }},
        { ldap_password = {
          type = "string",
          encrypted = true,
          referenceable = true,
        }},
        { ldap_port = {
          type = "number",
          default = 389
        }},
        { bind_dn = {
          type = "string",
          referenceable = true,
        }},
        { ldaps = {
          type = "boolean",
          required = true,
          default = false
        }},
        { start_tls = {
          type = "boolean",
          required = true,
          default = false
        }},
        { verify_ldap_host = {
          type = "boolean",
          required = true,
          default = false
        }},
        { base_dn = {
          type = "string",
          required = true
        }},                            -- used for cache key
        { attribute = {
          type = "string",
          required = true
        }},                          -- used for cache key
        { cache_ttl = {
          type = "number",
          required = true,
          default = 60
        }},            -- used for cache key
        { hide_credentials = {
          type = "boolean",
          default = false
        }},
        { timeout = {
          type = "number",
          default = 10000
        }},
        { keepalive = {
          type = "number",
          default = 60000
        }},
        { anonymous = {
          type = "string",
          len_min = 0,
          default = "",
          custom_validator = check_user
        }},
        { header_type = {
          type = "string",
          default = "ldap"
        }},
        { consumer_optional = {
          type = "boolean",
          required = false,
          default = false
        }},
        { consumer_by = {
          type = "array",
          elements = { type = "string", one_of = { "username", "custom_id" }},
          required = false,
          default = { "username", "custom_id" },
        }},
        { group_base_dn = {
          type = "string"
        }},
        { group_name_attribute = {
          type = "string"
        }},
        { group_member_attribute = {
          type = "string",
          default = "memberOf"
        }},
        { log_search_results = {
          type = "boolean",
          required = false,
          default = false,
        }},
      }
    }}
  },
  entity_checks = {
    { custom_entity_check = {
      field_sources = { "config" },
      fn = check_ldaps_tls
    }}
  }
}
