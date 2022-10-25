-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local workspaces = require "kong.workspaces"
local sni_filter = require("kong.enterprise_edition.tls.plugins.sni_filter")
local plugin_name = require("kong.plugins.mtls-auth.schema").name

local kong = kong
local null = ngx.null
local ipairs = ipairs


local _M = {}

local TTL_FOREVER = { ttl = 0 }
local SNI_CACHE_KEY = "mtls-auth:cert_enabled_snis"
_M.SNI_CACHE_KEY = SNI_CACHE_KEY
_M.TTL_FOREVER = TTL_FOREVER

function _M.consumer_field_cache_key(key, value)
  return kong.db.consumers:cache_key(key, value, "consumers")
end

local function invalidate_sni_cache()
  kong.cache:invalidate(SNI_CACHE_KEY)
end


function _M.init_worker()
  -- warmup SNI filter cache
  local _, err = kong.cache:get(SNI_CACHE_KEY, TTL_FOREVER,
     sni_filter.build_ssl_route_filter_set, plugin_name)

  if err then
    kong.log.err("unable to warmup SNI filter: ", err)
  end

  if not kong.worker_events or not kong.worker_events.register then
    return
  end

  local register = kong.worker_events.register
  for _, v in ipairs({"services", "routes", "plugins"}) do
    register(invalidate_sni_cache, "crud", v)
  end

  register(
    function(data)
      workspaces.set_workspace(data.workspace)
      local cache_key = _M.consumer_field_cache_key

      local old_entity = data.old_entity
      if old_entity then
        if old_entity.custom_id and old_entity.custom_id ~= null and old_entity.custom_id ~= "" then
          kong.cache:invalidate(cache_key("custom_id", old_entity.custom_id))
        end

        if old_entity.username and old_entity.username ~= null and old_entity.username ~= "" then
          kong.cache:invalidate(cache_key("username", old_entity.username))
        end
      end

      local entity = data.entity
      if entity then
        if entity.custom_id and entity.custom_id ~= null and entity.custom_id ~= "" then
          kong.cache:invalidate(cache_key("custom_id", entity.custom_id))
        end

        if entity.username and entity.username ~= null and entity.username ~= "" then
          kong.cache:invalidate(cache_key("username", entity.username))
        end
      end
    end, "crud", "consumers")
end


return _M
