-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local typedefs = require "kong.db.schema.typedefs"

return {
  name = "consumer_group_consumers",
  generate_admin_api = false,
  primary_key = {"consumer_group","consumer"},
  cache_key = {"consumer_group","consumer"},
  fields = {
    { created_at = typedefs.auto_timestamp_s },
    { consumer_group = { type = "foreign", required = true, reference = "consumer_groups", on_delete = "cascade" }, },
    { consumer = { type = "foreign", required = true, reference = "consumers", on_delete = "cascade" }, },
  }
}
