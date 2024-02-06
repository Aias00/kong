-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local typedefs = require "kong.db.schema.typedefs"
local redis_schema = require "kong.tools.redis.schema"
local deprecation = require "kong.deprecation"

local SYNC_RATE_REALTIME = -1


local ORDERED_PERIODS = { "second", "minute", "hour", "day", "month", "year"}


local function validate_periods_order(config)
  for i, lower_period in ipairs(ORDERED_PERIODS) do
    local v1 = config[lower_period]
    if type(v1) == "number" then
      for j = i + 1, #ORDERED_PERIODS do
        local upper_period = ORDERED_PERIODS[j]
        local v2 = config[upper_period]
        if type(v2) == "number" and v2 < v1 then
          return nil, string.format("The limit for %s(%.1f) cannot be lower than the limit for %s(%.1f)",
                                    upper_period, v2, lower_period, v1)
        end
      end
    end
  end

  if config.policy ~= "redis" and config.sync_rate ~= SYNC_RATE_REALTIME then
    return nil, "sync_rate can only be used with the redis policy"
  end

  if config.policy == "redis" then
    if config.sync_rate ~= SYNC_RATE_REALTIME and config.sync_rate < 0.02 then
      return nil, "sync_rate must be greater than 0.02, or -1 to disable"
    end
  end

  return true
end


local function is_dbless()
  local _, database, role = pcall(function()
    return kong.configuration.database,
           kong.configuration.role
  end)

  return database == "off" or role == "control_plane"
end


local policy
if is_dbless() then
  policy = { description = "The rate-limiting policies to use for retrieving and incrementing the limits.", type = "string",
    default = "local",
    len_min = 0,
    one_of = {
      "local",
      "redis",
    },
  }

else
  policy = { description = "The rate-limiting policies to use for retrieving and incrementing the limits.", type = "string",
    default = "local",
    len_min = 0,
    one_of = {
      "local",
      "cluster",
      "redis",
    },
  }
end


return {
  name = "rate-limiting",
  fields = {
    { protocols = typedefs.protocols_http },
    { config = {
        type = "record",
        fields = {
          { second = { description = "The number of HTTP requests that can be made per second.", type = "number", gt = 0 }, },
          { minute = { description = "The number of HTTP requests that can be made per minute.", type = "number", gt = 0 }, },
          { hour = { description = "The number of HTTP requests that can be made per hour.", type = "number", gt = 0 }, },
          { day = { description = "The number of HTTP requests that can be made per day.", type = "number", gt = 0 }, },
          { month = { description = "The number of HTTP requests that can be made per month.", type = "number", gt = 0 }, },
          { year = { description = "The number of HTTP requests that can be made per year.", type = "number", gt = 0 }, },
          { limit_by = { description = "The entity that is used when aggregating the limits.", type = "string",
              default = "consumer",
              one_of = { "consumer", "credential", "ip", "service", "header", "path", "consumer-group" },
          }, },
          { header_name = typedefs.header_name },
          { path = typedefs.path },
          { policy = policy },
          { fault_tolerant = { description = "A boolean value that determines if the requests should be proxied even if Kong has troubles connecting a third-party data store. If `true`, requests will be proxied anyway, effectively disabling the rate-limiting function until the data store is working again. If `false`, then the clients will see `500` errors.", type = "boolean", required = true, default = true }, },
          { redis = redis_schema.config_schema },
          { hide_client_headers = { description = "Optionally hide informative response headers.", type = "boolean", required = true, default = false }, },
          { error_code = { description = "Set a custom error code to return when the rate limit is exceeded.", type = "number", default = 429, gt = 0 }, },
          { error_message = { description = "Set a custom error message to return when the rate limit is exceeded.", type = "string", default = "API rate limit exceeded" }, },
          { sync_rate = { description = "How often to sync counter data to the central data store. A value of -1 results in synchronous behavior.", type = "number", required = true, default = -1 }, },
        },
        custom_validator = validate_periods_order,
        shorthand_fields = {
          -- TODO: deprecated forms, to be removed in Kong 4.0
          { redis_host = {
            type = "string",
            translate_backwards = {'redis', 'host'},
            func = function(value)
              deprecation("rate-limiting: config.redis_host is deprecated, please use config.redis.host instead",
                { after = "4.0", })
              return { redis = { host = value } }
            end
          } },
          { redis_port = {
            type = "integer",
            translate_backwards = {'redis', 'port'},
            func = function(value)
              deprecation("rate-limiting: config.redis_port is deprecated, please use config.redis.port instead",
                { after = "4.0", })
              return { redis = { port = value } }
            end
          } },
          { redis_password = {
            type = "string",
            len_min = 0,
            translate_backwards = {'redis', 'password'},
            func = function(value)
              deprecation("rate-limiting: config.redis_password is deprecated, please use config.redis.password instead",
                { after = "4.0", })
              return { redis = { password = value } }
            end
          } },
          { redis_username = {
            type = "string",
            translate_backwards = {'redis', 'username'},
            func = function(value)
              deprecation("rate-limiting: config.redis_username is deprecated, please use config.redis.username instead",
                { after = "4.0", })
              return { redis = { username = value } }
            end
          } },
          { redis_ssl = {
            type = "boolean",
            translate_backwards = {'redis', 'ssl'},
            func = function(value)
              deprecation("rate-limiting: config.redis_ssl is deprecated, please use config.redis.ssl instead",
                { after = "4.0", })
              return { redis = { ssl = value } }
            end
          } },
          { redis_ssl_verify = {
            type = "boolean",
            translate_backwards = {'redis', 'ssl_verify'},
            func = function(value)
              deprecation("rate-limiting: config.redis_ssl_verify is deprecated, please use config.redis.ssl_verify instead",
                { after = "4.0", })
              return { redis = { ssl_verify = value } }
            end
          } },
          { redis_server_name = {
            type = "string",
            translate_backwards = {'redis', 'server_name'},
            func = function(value)
              deprecation("rate-limiting: config.redis_server_name is deprecated, please use config.redis.server_name instead",
                { after = "4.0", })
              return { redis = { server_name = value } }
            end
          } },
          { redis_timeout = {
            type = "integer",
            translate_backwards = {'redis', 'timeout'},
            func = function(value)
              deprecation("rate-limiting: config.redis_timeout is deprecated, please use config.redis.timeout instead",
                { after = "4.0", })
              return { redis = { timeout = value } }
            end
          } },
          { redis_database = {
            type = "integer",
            translate_backwards = {'redis', 'database'},
            func = function(value)
              deprecation("rate-limiting: config.redis_database is deprecated, please use config.redis.database instead",
                { after = "4.0", })
              return { redis = { database = value } }
            end
          } },
        },
      },
    },
  },
  entity_checks = {
    { at_least_one_of = { "config.second", "config.minute", "config.hour", "config.day", "config.month", "config.year" } },
    { conditional = {
      if_field = "config.policy", if_match = { eq = "redis" },
      then_field = "config.redis.host", then_match = { required = true },
    } },
    { conditional = {
      if_field = "config.policy", if_match = { eq = "redis" },
      then_field = "config.redis.port", then_match = { required = true },
    } },
    { conditional = {
      if_field = "config.policy", if_match = { eq = "redis" },
      then_field = "config.redis.timeout", then_match = { required = true },
    } },
    { conditional = {
      if_field = "config.limit_by", if_match = { eq = "header" },
      then_field = "config.header_name", then_match = { required = true },
    } },
    { conditional = {
      if_field = "config.limit_by", if_match = { eq = "path" },
      then_field = "config.path", then_match = { required = true },
    } },
  },
}
