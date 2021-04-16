-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local utils = require "kong.tools.utils"


local cache_warmup = {}


local tostring = tostring
local ipairs = ipairs
local math = math
local kong = kong
local ngx = ngx


function cache_warmup._mock_kong(mock_kong)
  kong = mock_kong
end


local function warmup_dns(premature, hosts, count)
  if premature then
    return
  end

  ngx.log(ngx.NOTICE, "warming up DNS entries ...")

  local start = ngx.now()

  for i = 1, count do
    kong.dns.toip(hosts[i])
  end

  local elapsed = math.floor((ngx.now() - start) * 1000)

  ngx.log(ngx.NOTICE, "finished warming up DNS entries",
                      "' into the cache (in ", tostring(elapsed), "ms)")
end


local function cache_warmup_single_entity(dao)
  local entity_name = dao.schema.name

  ngx.log(ngx.NOTICE, "Preloading '", entity_name, "' into the cache ...")

  local start = ngx.now()

  local hosts_array, hosts_set, host_count
  if entity_name == "services" then
    hosts_array = {}
    hosts_set = {}
    host_count = 0
  end

  local id_to_ws = kong.db.workspace_entities:select_all({
    entity_type= entity_name,
    unique_field_name=dao.schema.primary_key[1] or "id"
  })


  -- id_to_ws == {{ id='123',..., workspace_id='w1' },
  --              { id='123',..., workspace_id='w2' }}

  local id_to_ws_h = {}
  for _, v in ipairs(id_to_ws) do
    id_to_ws_h[v.unique_field_value] = id_to_ws_h[v.unique_field_value] or {}
    table.insert(id_to_ws_h[v.unique_field_value], { workspace_id = v.workspace_id, workspace_name = v.workspace_name })
  end

  -- {'123'= {'w1', 'w2'} }
  local cache = kong.cache

  for entity, err in dao:each() do
    if err then
      return nil, err
    end

    if entity_name == "services" then
      if utils.hostname_type(entity.host) == "name"
         and hosts_set[entity.host] == nil then
        host_count = host_count + 1
        hosts_array[host_count] = entity.host
        hosts_set[entity.host] = true
      end
    end

    for _, v in ipairs(id_to_ws_h[entity.id] or {{ workspace_id = false }}) do
      local cache_key, cache_key_ws, ok, err

      if entity_name == 'plugins' then
        cache_key = dao:cache_key(entity)
        cache_key_ws = dao:cache_key(entity, nil , nil, nil, nil, nil, v.workspace_id)
        entity["workspace_id"] = v.workspace_id
        entity["workspace_name"] = v.workspace_name

        ok, err = cache:safe_set(cache_key_ws, entity)

        if not ok then
          return nil, err
        end
      else
        cache_key = dao:cache_key(entity, nil , nil, nil, nil, nil, v.workspace_id)
      end

      -- consumers:123:21::ws_id
      -- consumers:123:21::::ws_id2


      ok, err = kong.cache:safe_set(cache_key, entity)

      if not ok then
        return nil, err
      end
    end
  end

  if entity_name == "services" and host_count > 0 then
    ngx.timer.at(0, warmup_dns, hosts_array, host_count)
  end

  local elapsed = math.floor((ngx.now() - start) * 1000)

  ngx.log(ngx.NOTICE, "finished preloading '", entity_name,
                      "' into the cache (in ", tostring(elapsed), "ms)")
  return true
end


-- Loads entities from the database into the cache, for rapid subsequent
-- access. This function is intented to be used during worker initialization.
function cache_warmup.execute(entities)
  if not kong.cache then
    return true
  end

  for _, entity_name in ipairs(entities) do
    if entity_name == "routes" then
      -- do not spend shm memory by caching individual Routes entries
      -- because the routes are kept in-memory by building the router object
      kong.log.notice("the 'routes' entry is ignored in the list of ",
                      "'db_cache_warmup_entities' because Kong ",
                      "caches routes in memory separately")
      goto continue
    end

    local dao = kong.db[entity_name]
    if not (type(dao) == "table" and dao.schema) then
      kong.log.warn(entity_name, " is not a valid entity name, please check ",
                    "the value of 'db_cache_warmup_entities'")
      goto continue
    end

    local ok, err = cache_warmup_single_entity(dao)
    if not ok then
      if err == "no memory" then
        kong.log.warn("cache warmup has been stopped because cache ",
                      "memory is exhausted, please consider increasing ",
                      "the value of 'mem_cache_size' (currently at ",
                      kong.configuration.mem_cache_size, ")")

        return true
      end
      return nil, err
    end

    ::continue::
  end

  return true
end


return cache_warmup
