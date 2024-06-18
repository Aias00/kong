-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local reports           = require "kong.reports"
local new_tab           = require "table.new"
local math              = require "math"
local request_id        = require "kong.tracing.request_id"
local Queue             = require "kong.tools.queue"
local pb                = require "pb"
local protoc            = require "protoc"
local is_http_module    = ngx.config.subsystem == "http"
local log               = ngx.log
local INFO              = ngx.INFO
local DEBUG             = ngx.DEBUG
local ERR               = ngx.ERR
local WARN              = ngx.WARN
local ngx               = ngx
local kong              = kong
local knode             = (kong and kong.node) and kong.node or
                            require "kong.pdk.node".new()
local re_gmatch         = ngx.re.gmatch
local ipairs            = ipairs
local assert            = assert
local to_hex            = require "resty.string".to_hex
local table_insert      = table.insert
local table_concat      = table.concat
local string_find       = string.find
local string_sub        = string.sub
local Queue_can_enqueue = Queue.can_enqueue
local Queue_enqueue     = Queue.enqueue

local _log_prefix                         = "[analytics] "
local DELAY_LOWER_BOUND                   = 0
local DELAY_UPPER_BOUND                   = 3
local DEFAULT_ANALYTICS_BUFFER_SIZE_LIMIT = 100000
local DEFAULT_ANALYTICS_FLUSH_INTERVAL    = 1
local KEEPALIVE_INTERVAL                  = 1
local KONG_VERSION                        = kong.version


local _M = {}
local _MT = { __index = _M }


local p = protoc.new()
p.include_imports = true
-- the file is uploaded by the build job
p:addpath("/usr/local/kong/include")
-- path for unit tests
p:addpath("kong/include")
p:loadfile("kong/model/analytics/payload.proto")

local EMPTY_PAYLOAD = pb.encode("kong.model.analytics.Payload", {})

local function strip_query(str)
  local idx = string_find(str, "?", 1, true)
  if idx then
    return string_sub(str, 1, idx - 1)
  end

  return str
end


local function keepalive_handler(premature, self)
  if premature then
    return
  end

  if not self.ws_send_func then
    log(INFO, _log_prefix, "no analytics websocket connection, skipping this round of keepalive")
    return
  end

  -- Random delay to avoid thundering herd.
  -- We should not do this at the beginning of this function
  -- because this will block the coroutine the timer is running in
  -- even if we don't need to send the keepalive message (no connection).
  -- So we should do this after we check if the connection is available.
  ngx.sleep(KEEPALIVE_INTERVAL + self:random(DELAY_LOWER_BOUND, DELAY_UPPER_BOUND))

  -- DO NOT YIELD IN THIS SECTION [[
  -- the connection might be closed after the ngx.sleep (yielding)
  if not self.ws_send_func then
    log(INFO, _log_prefix, "no analytics websocket connection, skipping this round of keepalive")
    return
  end

  self.ws_send_func(EMPTY_PAYLOAD)
  -- DO NOT YIELD IN THIS SECTION ]]
end


local function send_entries(self, entries)
  -- DO NOT YIELD IN THIS SECTION [[
  -- the connection might be closed after the yielding

  if not self.ws_send_func then
    -- let the queue know that we are not able to send the entries
    -- so it can retry later or drop them after serveral retries
    return false, "no connection to analytics service"
  end

  local bytes = assert(pb.encode("kong.model.analytics.Payload", {
    data = entries,
  }))
  self.ws_send_func(bytes)
  -- DO NOT YIELD IN THIS SECTION ]]

  return true
end


function _M.new(config)
  assert(config, "conf can not be nil", 2)

  local self = {
    cluster_endpoint = kong.configuration.cluster_telemetry_endpoint,
    path = "analytics/reqlog",
    ws_send_func = nil,
    keepalive_timer = nil, -- the handle of the timer to do keepalive for analytics service
    running = false,
    queue_conf = {
      name = "konnect_analytics_queue",
      log_tag = "konnect_analytics_queue",
      max_batch_size = 200,
      max_coalescing_delay = config.flush_interval or DEFAULT_ANALYTICS_FLUSH_INTERVAL,
      max_entries = config.analytics_buffer_size_limit or DEFAULT_ANALYTICS_BUFFER_SIZE_LIMIT,
      max_bytes = nil,
      initial_retry_delay = 0.2,
      max_retry_time = 60,
      max_retry_delay = 60,
    }
  }

  return setmetatable(self, _MT)
end


function _M:random(low, high)
  return low + math.random() * (high - low);
end


local function get_server_name()
  local conf = kong.configuration
  local server_name

  -- server_name will be set to the host if it is not explicitly defined here
  if conf.cluster_telemetry_server_name ~= "" then
    server_name = conf.cluster_telemetry_server_name
  elseif conf.cluster_server_name ~= "" then
    server_name = conf.cluster_server_name
  end

  return server_name
end


function _M:init_worker()
  if not kong.configuration.konnect_mode then
    log(INFO, _log_prefix, "the analytics feature is only available to Konnect users.")
    return false
  end

  if not is_http_module then
    log(INFO, _log_prefix, "the analytics don't need to init in non HTTP module.")
    return false
  end

  if self.initialized then
    log(WARN, _log_prefix, "tried to initialize kong.analytics (already initialized)")
    return true
  end

  log(INFO, _log_prefix, "init analytics workers.")

  -- can't define constant for node_id and node_hostname
  -- they will cause rbac integration tests to fail
  local uri = "wss://" .. self.cluster_endpoint .. "/v1/" .. self.path ..
    "?node_id=" .. knode.get_id() ..
    "&node_hostname=" .. knode.get_hostname() ..
    "&node_version=" .. KONG_VERSION

  local server_name = get_server_name()
  local clustering = kong.clustering or require("kong.clustering").new(kong.configuration)

  assert(ngx.timer.at(0, clustering.telemetry_communicate, clustering, uri, server_name, function(connected, send_func)
    if connected then
      ngx.log(ngx.INFO, _log_prefix, "worker id: ", (ngx.worker.id() or -1), ". analytics websocket is connected: ", uri)
      self.ws_send_func = send_func

    else
      ngx.log(ngx.INFO, _log_prefix, "worker id: ", (ngx.worker.id() or -1), ". analytics websocket is disconnected: ", uri)
      self.ws_send_func = nil
    end
  end), nil)

  self.initialized = true
  self:start()

  if ngx.worker.id() == 0 then
    reports.add_ping_value("konnect_analytics", true)
  end

  return true
end


function _M:enabled()
  return kong.configuration.konnect_mode and self.initialized and self.running
end


function _M:register_config_change(events_handler)
  events_handler.register(function(data, event, source, pid)
    log(INFO, _log_prefix, "config change event, incoming analytics: ",
      kong.configuration.konnect_mode)

    if kong.configuration.konnect_mode then
      if not self.initialized then
        self:init_worker()
      end
      if not self.running then
        self:start()
      end
    elseif self.running then
      self:stop()
    end

  end, "kong:configuration", "change")
end


function _M:start()
  local hdl, err = kong.timer:named_every(
    "konnect_analytics_keepalive",
    KEEPALIVE_INTERVAL,
    keepalive_handler,
    self
  )
  if not hdl then
    local msg = string.format(
      "failed to start the initial analytics timer for worker %d: %s",
      ngx.worker.id(), err
    )
    log(ERR, _log_prefix, msg)
  end

  log(INFO, _log_prefix, "initial analytics keepalive timer started for worker ", ngx.worker.id())

  self.keepalive_timer = hdl
  self.running = true
end


function _M:stop()
  log(INFO, _log_prefix, "stopping analytics")
  self.running = false

  if not self.keepalive_timer then
    log(INFO, _log_prefix, "no analytics keepalive timer to stop for worker ", ngx.worker.id())
    return
  end

  local ok, err = kong.timer:cancel(self.keepalive_timer)
  if not ok then
    local msg = string.format(
      "failed to stop the analytics keepalive timer for worker %d: %s",
      ngx.worker.id(), err
    )
    log(ERR, _log_prefix, msg)
  end

  self.keepalive_timer = nil
  log(INFO, _log_prefix, "analytics keepalive timer stopped for worker ", ngx.worker.id())
end


function _M:safe_string(var)
  if var == nil then
    return var
  end

  local tpe = type(var)
  if tpe == "string" then
    return var
  elseif tpe == "table" then
    return table_concat(var, ",")
  end

  return tostring(var)
end


function _M:create_payload(message)
  -- declare the table here for optimization
  local payload = {
    client_ip = "",
    started_at = 0,
    trace_id = "",
    request_id = "",
    upstream = {
      upstream_uri = ""
    },
    request = {
      header_user_agent = "",
      header_host = "",
      http_method = "",
      body_size = 0,
      uri = ""
    },
    response = {
      http_status = 0,
      body_size = 0,
      header_content_length = 0,
      header_content_type = "",
      header_ratelimit_limit = 0,
      header_ratelimit_remaining = 0,
      header_ratelimit_reset = 0,
      header_retry_after = 0,
      header_x_ratelimit_limit_second = 0,
      header_x_ratelimit_limit_minute = 0,
      header_x_ratelimit_limit_hour = 0,
      header_x_ratelimit_limit_day = 0,
      header_x_ratelimit_limit_month = 0,
      header_x_ratelimit_limit_year = 0,
      header_x_ratelimit_remaining_second = 0,
      header_x_ratelimit_remaining_minute = 0,
      header_x_ratelimit_remaining_hour = 0,
      header_x_ratelimit_remaining_day = 0,
      header_x_ratelimit_remaining_month = 0,
      header_x_ratelimit_remaining_year = 0,
      ratelimit_enabled = false,
      ratelimit_enabled_second = false,
      ratelimit_enabled_minute = false,
      ratelimit_enabled_hour = false,
      ratelimit_enabled_day = false,
      ratelimit_enabled_month = false,
      ratelimit_enabled_year = false

    },
    route = {
      id = "",
      name = ""
    },
    service = {
      id = "",
      name = "",
      port = 0,
      protocol = ""
    },
    latencies = {
      kong_gateway_ms = 0,
      upstream_ms = 0,
      response_ms = 0,
      receive_ms = 0,
    },
    tries = {},
    consumer = {
      id = "",
    },
    auth = {
      id = "",
      type = ""
    },
    upstream_status = "",
    source = "",
    application_context = {
      application_id = "",
      portal_id = "",
      organization_id = "",
      developer_id = "",
      product_version_id = "",
    },
    consumer_groups = {},
    websocket = false,
    sse = false,
  }

  payload.client_ip = message.client_ip
  payload.started_at = message.started_at

  local root_span = ngx.ctx.KONG_SPANS and ngx.ctx.KONG_SPANS[1]
  local trace_id = root_span and root_span.trace_id
  if trace_id and root_span.should_sample then
    log(DEBUG, _log_prefix, "Attaching raw trace_id of to_hex(trace_id): ", to_hex(trace_id))
    payload.trace_id = trace_id
  end

  local request_id_value, err = request_id.get()
  if request_id_value then
    payload.request_id = request_id_value

  else
    log(WARN, _log_prefix, "failed to get request id: ", err)
  end

  if message.upstream_uri ~= nil then
    payload.upstream.upstream_uri = strip_query(message.upstream_uri)
  end

  if message.request ~= nil then
    local request = payload.request
    local req = message.request
    request.header_user_agent = self:safe_string(req.headers["user-agent"])
    request.header_host = self:safe_string(req.headers["host"])
    request.http_method = req.method
    request.body_size = req.size
    request.uri = strip_query(req.uri)
  end

  if message.response ~= nil then
    local response = payload.response
    local resp = message.response
    response.http_status = resp.status
    response.body_size = resp.size
    response.header_content_length = resp.headers["content-length"]
    response.header_content_type = resp.headers["content-type"]
    response.header_ratelimit_limit = tonumber(resp.headers["ratelimit-limit"])
    response.header_ratelimit_remaining = tonumber(resp.headers["ratelimit-remaining"])
    response.header_ratelimit_reset = tonumber(resp.headers["ratelimit-reset"])
    response.header_retry_after = tonumber(resp.headers["retry-after"])
    response.header_x_ratelimit_limit_second = tonumber(resp.headers["x-ratelimit-limit-second"])
    response.header_x_ratelimit_limit_minute = tonumber(resp.headers["x-ratelimit-limit-minute"])
    response.header_x_ratelimit_limit_hour = tonumber(resp.headers["x-ratelimit-limit-hour"])
    response.header_x_ratelimit_limit_day = tonumber(resp.headers["x-ratelimit-limit-day"])
    response.header_x_ratelimit_limit_month = tonumber(resp.headers["x-ratelimit-limit-month"])
    response.header_x_ratelimit_limit_year = tonumber(resp.headers["x-ratelimit-limit-year"])
    response.header_x_ratelimit_remaining_second = tonumber(resp.headers["x-ratelimit-remaining-second"])
    response.header_x_ratelimit_remaining_minute = tonumber(resp.headers["x-ratelimit-remaining-minute"])
    response.header_x_ratelimit_remaining_hour = tonumber(resp.headers["x-ratelimit-remaining-hour"])
    response.header_x_ratelimit_remaining_day = tonumber(resp.headers["x-ratelimit-remaining-day"])
    response.header_x_ratelimit_remaining_month = tonumber(resp.headers["x-ratelimit-remaining-month"])
    response.header_x_ratelimit_remaining_year = tonumber(resp.headers["x-ratelimit-remaining-year"])
    if resp.headers["ratelimit-limit"] ~= nil then
      response.ratelimit_enabled = true
    end
    if resp.headers["x-ratelimit-limit-second"] ~= nil then
      response.ratelimit_enabled_second = true
    end
    if resp.headers["x-ratelimit-limit-minute"] ~= nil then
      response.ratelimit_enabled_minute = true
    end
    if resp.headers["x-ratelimit-limit-hour"] ~= nil then
      response.ratelimit_enabled_hour = true
    end
    if resp.headers["x-ratelimit-limit-day"] ~= nil then
      response.ratelimit_enabled_day = true
    end
    if resp.headers["x-ratelimit-limit-month"] ~= nil then
      response.ratelimit_enabled_month = true
    end
    if resp.headers["x-ratelimit-limit-year"] ~= nil then
      response.ratelimit_enabled_year = true
    end

    local upgrade = resp.headers["upgrade"]
    local connection = resp.headers["connection"]
    if type(upgrade) == "string"
       and upgrade:lower() == "websocket"
       and type(connection) == "string"
       and connection:lower() == "upgrade"
    then
      payload.websocket = true
    end

    local content_type = resp.headers["content-type"]
    if type(content_type) == "string"
      and content_type:lower() == "text/event-stream"
    then
      payload.sse = true
    end
  end

  if message.route ~= nil then
    local route = payload.route
    route.id = message.route.id
    route.name = message.route.name
  end

  if message.service ~= nil then
    local service = payload.service
    local svc = message.service
    service.id = svc.id
    service.name = svc.name
    service.port = svc.port
    service.protocol = svc.protocol
  end

  if message.latencies ~= nil then
    local latencies = payload.latencies
    local ml = message.latencies
    latencies.kong_gateway_ms = ml.kong or 0
    latencies.upstream_ms = ml.proxy
    latencies.response_ms = ml.request
    latencies.receive_ms = ml.receive
  end

  if message.tries ~= nil then
    local tries = new_tab(#message.tries, 0)
    for i, try in ipairs(message.tries) do
      tries[i] = {
        balancer_latency = try.balancer_latency,
        ip = try.ip,
        port = try.port
      }
    end

    payload.tries = tries
  end

  if message.consumer ~= nil then
    local consumer = payload.consumer
    consumer.id = message.consumer.id
  end

  -- auth_type is only not nil when konnect-application-auth plugin is enabled
  -- authenticated_entity should only be collected when the plugin is enabled
  if message.auth_type ~= nil then
    local auth = payload.auth
    auth.type = message.auth_type
    if message.authenticated_entity ~= nil then
      auth.id = message.authenticated_entity.id
    end
  end

  if message.upstream_status ~= nil then
    payload.upstream_status = self:safe_string(message.upstream_status)
  end
  if message.source ~= nil then
    payload.source = message.source
  end

  local app_context = kong.ctx.shared.kaa_application_context
  if app_context then
    local app = payload.application_context
    app.application_id = app_context.application_id or ""
    app.portal_id = app_context.portal_id or ""
    app.organization_id = app_context.organization_id or ""
    app.developer_id = app_context.developer_id or ""
    app.product_version_id = app_context.product_version_id or ""
  end

  local consumer_groups = kong.client.get_consumer_groups()
  for _, v in ipairs(consumer_groups or {}) do
    table_insert(payload.consumer_groups, { id = v.id })
  end
  return payload
end


function _M:split(str, sep)
  if sep == nil then
    sep = "%s"
  end
  local t = new_tab(2, 0)
  local i = 1
  for m, _ in re_gmatch(str, "([^" .. sep .. "]+)", "jo") do
    t[i] = m[0]
    i = i + 1
  end
  return t
end


function _M:log_request()
  if not self:enabled() then
    return
  end

  local queue_conf = self.queue_conf

  if not Queue_can_enqueue(queue_conf) then
    log(WARN, _log_prefix, "Local buffer size limit reached for the analytics request log. ",
        "The current limit is ", queue_conf.max_entries)
    return
  end

  local ok, err = Queue_enqueue(
    queue_conf,
    send_entries,
    self,
    self:create_payload(kong.log.serialize())
  )

  if not ok then
    log(ERR, _log_prefix, "failed to log request: ", err)
  end
end


return _M
