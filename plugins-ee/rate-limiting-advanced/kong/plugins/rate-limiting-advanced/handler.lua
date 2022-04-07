-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

-- Copyright (C) Kong Inc.

local ratelimiting = require "kong.tools.public.rate-limiting"
local schema       = require "kong.plugins.rate-limiting-advanced.schema"
local event_hooks  = require "kong.enterprise_edition.event_hooks"
local concurrency  = require "kong.concurrency"
local cjson_safe   = require "cjson.safe"
local helpers      = require "kong.enterprise_edition.consumer_groups_helpers"

local kong     = kong
local ceil     = math.ceil
local floor    = math.floor
local max      = math.max
local rand     = math.random
local time     = ngx.time
local tonumber = tonumber


-- all elements from all workspaces
local GLOBAL_QUERY_OPTS = { workspace = ngx.null, show_ws_id = true }

-- semaphore name unique to rl
local GLOBAL_FLIP_OPS = { name = "flip-rl" }


local NewRLHandler = {
  PRIORITY = 902,
  VERSION = "1.6.2"
}


local X_RATELIMIT_LIMIT = "X-RateLimit-Limit"
local X_RATELIMIT_REMAINING = "X-RateLimit-Remaining"


-- Add draft headers for rate limiting RFC
-- https://tools.ietf.org/html/draft-polli-ratelimit-headers-02
local RATELIMIT_LIMIT = "RateLimit-Limit"
local RATELIMIT_REMAINING = "RateLimit-Remaining"
local RATELIMIT_RESET = "RateLimit-Reset"
local RATELIMIT_RETRY_AFTER = "Retry-After"


local human_window_size_lookup = {
  [1]        = "second",
  [60]       = "minute",
  [3600]     = "hour",
  [86400]    = "day",
  [2592000]  = "month",
  [31536000] = "year",
}


local id_lookup = {
  ip = function(conf)
    return kong.client.get_forwarded_ip()
  end,
  credential = function(conf)
    return kong.client.get_credential() and
           kong.client.get_credential().id
  end,
  consumer = function(conf)
    -- try the consumer, fall back to credential
    return kong.client.get_consumer() and
           kong.client.get_consumer().id or
           kong.client.get_credential() and
           kong.client.get_credential().id
  end,
  service = function(conf)
    return kong.router.get_service() and
           kong.router.get_service().id
  end,
  header = function(conf)
    return kong.request.get_header(conf.header_name)
  end,
  path = function(conf)
    return kong.request.get_path() == conf.path and conf.path
  end,
}


local function new_namespace(config, init_timer)
  if not config then
    kong.log.warn("[rate-limiting-advanced] no config was specified.",
      " Skipping the namespace creation.")
    return false
  end
  kong.log.debug("attempting to add namespace ", config.namespace)

  local ok, err = pcall(function()
    local strategy = config.strategy == "cluster" and
                     kong.configuration.database or
                     "redis"

    local strategy_opts = strategy == "redis" and config.redis

    if config.strategy == "local" then
      config.sync_rate = -1
    end

    -- no shm was specified, try the default value specified in the schema
    local dict_name = config.dictionary_name
    if dict_name == nil then
      dict_name = schema.fields.dictionary_name.default
      if dict_name then
        kong.log.warn("[rate-limiting-advanced] no shared dictionary was specified.",
          " Trying the default value '", dict_name, "'...")
      else
        kong.log.warn("[rate-limiting-advanced] no schema default was specified.",
          " Skipping the namespace creation.")
        return false
      end
    end

    -- if dictionary name was passed but doesn't exist, fallback to kong
    if ngx.shared[dict_name] == nil then
      kong.log.notice("[rate-limiting-advanced] specified shared dictionary '", dict_name,
        "' doesn't exist. Falling back to the 'kong' shared dictionary")
      dict_name = "kong"
    end
    kong.log.notice("[rate-limiting-advanced] using shared dictionary '"
                         .. dict_name .. "'")

    ratelimiting.new({
      namespace     = config.namespace,
      sync_rate     = config.sync_rate,
      strategy      = strategy,
      strategy_opts = strategy_opts,
      dict          = dict_name,
      window_sizes  = config.window_size,
      db            = kong.db,
    })
  end)

  local ret = true

  -- if we created a new namespace, start the recurring sync timer and
  -- run an intial sync to fetch our counter values from the data store
  -- (if applicable)
  if ok then
    if init_timer and config.sync_rate > 0 then
      local rate = config.sync_rate
      local when = rate - (ngx.now() - (math.floor(ngx.now() / rate) * rate))
      kong.log.debug("initial sync in ", when, " seconds")
      ngx.timer.at(when, ratelimiting.sync, config.namespace)

      -- run the fetch from a timer because it uses cosockets
      -- kong patches this for psql and c*, but not redis
      ngx.timer.at(0, ratelimiting.fetch, config.namespace, ngx.now())
    end

  else
    kong.log.err("err in creating new ratelimit namespace: ", err)
    ret = false
  end

  return ret
end


function NewRLHandler:init_worker()
  event_hooks.publish("rate-limiting-advanced", "rate-limit-exceeded", {
    fields = { "consumer", "ip", "service", "rate", "limit", "window" },
    unique = { "consumer", "ip", "service" },
    description = "Run an event when a rate limit has been exceeded",
  })

  local worker_events = kong.worker_events
  local cluster_events = kong.cluster_events
  -- event handlers to update recurring sync timers

  worker_events.register(function()
    if ngx.worker.exiting() then
      kong.log.notice("declarative flip config canceled: process exiting")
      return true
    end

    local ok, err = concurrency.with_coroutine_mutex(GLOBAL_FLIP_OPS, function()
      local namespaces = {}

      for plugin, err in kong.db.plugins:each(nil, GLOBAL_QUERY_OPTS) do
        if err then
          kong.log.crit("could not obtain list of plugins: ", err)
          return nil, err
        end

        if plugin.name == "rate-limiting-advanced" then
          namespaces[plugin.config.namespace] = true

          kong.log.debug("clear and reset ", plugin.config.namespace)

          -- previous config doesn't exist for this worker
          -- create a namespace for the new config and return, similar to "rl:create"
          if not ratelimiting.config[plugin.config.namespace] then
            new_namespace(plugin.config, true)
            goto continue
          end

          -- if the previous config did not have a background timer,
          -- we need to start one
          local start_timer = false
          if ratelimiting.config[plugin.config.namespace].sync_rate <= 0 and
             plugin.config.sync_rate > 0 then

            start_timer = true
          end

          ratelimiting.clear_config(plugin.config.namespace)
          new_namespace(plugin.config, start_timer)

          -- recommendation have changed with FT-928
          if plugin.config.sync_rate > 0 and plugin.config.sync_rate < 1 then
            kong.log.warn("Config option 'sync_rate' " .. plugin.config.sync_rate .. " is between 0 and 1; a config update is recommended")
          end

          -- clear the timer if we dont need it
          if plugin.config.sync_rate <= 0 then
            if ratelimiting.config[plugin.config.namespace] then
              ratelimiting.config[plugin.config.namespace].kill = true

            else
              kong.log.warn("did not find namespace ", plugin.config.namespace, " to kill")
            end
          end

          ::continue::
        end
      end

      for namespace in pairs(ratelimiting.config) do
        if not namespaces[namespace] then
          -- namespace not found on kong.db.plugins: plugin was deleted
          ratelimiting.config[namespace].kill = true
        end
      end

      return true
    end)

    if not ok then
      kong.log.err("rl config flip failed: ", err)
    end
  end, "declarative", "flip_config")


  -- catch any plugins update and forward config data to each worker
  worker_events.register(function(data)
    local operation = data.operation
    local config = data.entity.config

    local json, err = cjson_safe.encode({ operation, config })
    if not json then
      kong.log.err("could not encode worker_events register cb data: ", err)
    end

    -- => to cluster_events handler
    local ok, err = cluster_events:broadcast("rl", json)
    if not ok then
      kong.log.err("failed broadcasting rl ", operation, " to cluster: ", err)
    end

    if data.entity.name == "rate-limiting-advanced" then
      worker_events.post("rl", operation, config)
    end
  end, "crud", "plugins")

  -- new plugin? try to make a namespace!
  worker_events.register(function(config)
    if not ratelimiting.config[config.namespace] then
      new_namespace(config, true)
    end
  end, "rl", "create")

  -- updates should clear the existing config and create a new
  -- namespace config. we do not initiate a new fetch/sync recurring
  -- timer as it's already running in the background
  worker_events.register(function(config)
    kong.log.debug("clear and reset ", config.namespace)

    -- previous config doesn't exist for this worker
    -- create a namespace for the new config and return, similar to "rl:create"
    if not ratelimiting.config[config.namespace] then
      new_namespace(config, true)
      return
    end

    -- if the previous config did not have a background timer,
    -- we need to start one
    local start_timer = false
    if ratelimiting.config[config.namespace].sync_rate <= 0 and
       config.sync_rate > 0 then

      start_timer = true
    end

    ratelimiting.clear_config(config.namespace)
    new_namespace(config, start_timer)

    -- recommendation have changed with FT-928
    if config.sync_rate > 0 and config.sync_rate < 1 then
      kong.log.warn("Config option 'sync_rate' " .. config.sync_rate .. " is between 0 and 1; a config update is recommended")
    end

    -- clear the timer if we dont need it
    if config.sync_rate <= 0 then
      if ratelimiting.config[config.namespace] then
        ratelimiting.config[config.namespace].kill = true

      else
        kong.log.warn("did not find namespace ", config.namespace, " to kill")
      end
    end
  end, "rl", "update")

  -- nuke this from orbit
  worker_events.register(function(config)
    -- set the kill flag on this namespace
    -- this will clear the config at the next sync() execution, and
    -- abort the recurring syncs
    if ratelimiting.config[config.namespace] then
      ratelimiting.config[config.namespace].kill = true

    else
      kong.log.warn("did not find namespace ", config.namespace, " to kill")
    end
  end, "rl", "delete")

  cluster_events:subscribe("rl", function(data)
    if not data then
      kong.log.err("received empty data in cluster_events subscription")
      return
    end

    local json, err = cjson_safe.decode(data)

    if not json then
      kong.log.err("could not decode cluster_events subscribe cb data: ", err)
      return
    end

    local operation = json[1]
    local config = json[2]

    -- => to worker_events node handler
    local ok, err = worker_events.post("rl", operation, config)
    if not ok then
      kong.log.err("failed broadcasting rl ", operation, " to workers: ", err)
    end
  end)
end

function NewRLHandler:access(conf)
  local now = time()
  local key = id_lookup[conf.identifier](conf)

  -- legacy logic, if authenticated consumer or credential is not found
  -- use the IP
  if not key then
    key = id_lookup["ip"]()
  end

  local deny

  -- if this worker has not yet seen the "rl:create" event propagated by the
  -- instatiation of a new plugin, create the namespace. in this case, the call
  -- to new_namespace in the registered rl handler will never be called on this
  -- worker
  --
  -- this workaround will not be necessary when real IPC is implemented for
  -- inter-worker communications
  --
  -- changes in https://github.com/Kong/kong-plugin-enterprise-rate-limiting/pull/35
  -- currently rely on this in scenarios where workers initialize without database availability
  if not ratelimiting.config[conf.namespace] then
    new_namespace(conf, true)
  end

  local config
  -- check to apply consumer groups
  if conf.enforce_consumer_groups then
    if kong.client.get_consumer() and conf.consumer_groups then
      local consumer = kong.client.get_consumer()
      for i = 1, #conf.consumer_groups do
        -- if found a match, overrides the configuration value
        local consumer_group = helpers.get_consumer_group(conf.consumer_groups[i])
        if consumer_group and helpers.is_consumer_in_group(consumer.id, consumer_group.id) then
          local config_raw = helpers.get_consumer_group_config(consumer_group.id, "rate-limiting-advanced")
          if config_raw then
            config = config_raw.config
          else
            kong.log.warn("Consumer group " .. consumer_group.name ..
            " enforced but no consumer group configurations provided. Original plugin configurations will apply.")
          end
          break --exit on the first matching group found
        end
      end
    end
  end

  -- fall back to the original plugin configurations
  if not config then
    config = conf
  end

  local limit
  local window
  local remaining
  local reset
  local namespace = conf.namespace
  local window_type = config.window_type
  local shm = ngx.shared[conf.dictionary_name]
  for i = 1, #config.window_size do
    local current_window = tonumber(config.window_size[i])
    local current_limit = tonumber(config.limit[i])

    -- if we have exceeded any rate, we should not increment any other windows,
    -- butwe should still show the rate to the client, maintaining a uniform
    -- set of response headers regardless of whether we block the request
    local rate
    if deny then
      rate = ratelimiting.sliding_window(key, current_window, nil, namespace)
    else
      rate = ratelimiting.increment(key, current_window, 1, namespace,
                                    config.window_type == "fixed" and 0 or nil)
    end

    -- Ensure the window start time persists using shared memory
    -- This handles the thundering herd problem for the sliding window reset
    -- calculation to be extended longer than the actual window size
    local window_start = floor(now / current_window) * current_window
    local window_start_timstamp_key = "timestamp:" .. current_window .. ":window_start"
    if rate > current_limit and window_type == "sliding" then
      shm:add(window_start_timstamp_key, window_start)
      window_start = shm:get(window_start_timstamp_key) or window_start
    else
      shm:delete(window_start_timstamp_key)
    end

    -- legacy logic of naming rate limiting headers. if we configured a window
    -- size that looks like a human friendly name, give that name
    local window_name = human_window_size_lookup[current_window] or current_window

    local current_remaining = floor(max(current_limit - rate, 0))
    if not conf.hide_client_headers then
      ngx.header[X_RATELIMIT_LIMIT .. "-" .. window_name] = current_limit
      ngx.header[X_RATELIMIT_REMAINING .. "-" .. window_name] = current_remaining

      -- calculate the reset value based on the window type (if applicable)
      if not limit or (current_remaining < remaining)
                   or (current_remaining == remaining and
                       current_window > window) then
        -- Ensure that the proper window reset value is set
        limit = current_limit
        window = current_window
        remaining = current_remaining

        -- Calculate the fixed window reset value
        reset = max(1.0, window - (now - window_start))

        -- Add some weight to the current reset value based on the window
        -- and the rate difference. Apply the adjustment to the current
        -- calculated reset value for a more accurate sliding window estimate.
        if window_type == "sliding" then
          local window_adjustment = max(0.0, (((rate - limit) / limit) * window))
          reset = ceil(reset + window_adjustment)
        end
      end
    end

    if rate > current_limit then
      deny = true
      -- only gets emitted when kong.configuration.databus_enabled = true
      -- no need to if here
      -- XXX we are doing it on this flow of code because it's easier to
      -- get the rate and the limit that triggered it. Move it somewhere
      -- general later.
      event_hooks.emit("rate-limiting-advanced", "rate-limit-exceeded", {
        consumer = kong.client.get_consumer() or {},
        ip = kong.client.get_forwarded_ip(),
        service = kong.router.get_service() or {},
        rate = rate,
        limit = current_limit,
        window = window_name,
      })
    end
  end

  -- Add draft headers for rate limiting RFC; FTI-1447
  ngx.header[RATELIMIT_LIMIT] = limit
  ngx.header[RATELIMIT_REMAINING] = remaining
  ngx.header[RATELIMIT_RESET] = reset

  if deny then
    local retry_after = reset
    local jitter_max = config.retry_after_jitter_max

    -- Add a random value (a jitter) to the Retry-After value
    -- to reduce a chance of retries spike occurrence.
    if retry_after and jitter_max > 0 then
      retry_after = retry_after + rand(jitter_max)
    end

    -- Only added for denied requests (if hide_client_headers == false)
    ngx.header[RATELIMIT_RETRY_AFTER] = retry_after
    return kong.response.exit(429, { message = "API rate limit exceeded" })
  end
end

return NewRLHandler
