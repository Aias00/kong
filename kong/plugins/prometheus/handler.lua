-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local exporter = require "kong.plugins.prometheus.exporter"
local kong = kong
local kong_meta = require "kong.meta"


exporter.init()


local PrometheusHandler = {
  PRIORITY = 13,
  VERSION  = kong_meta.core_version,
}

function PrometheusHandler.init_worker()
  exporter.init_worker()
end

local http_subsystem = ngx.config.subsystem == "http"


function PrometheusHandler.log(self, conf)
  local message = kong.log.serialize()

  local serialized = {}
  if conf.per_consumer and message.consumer ~= nil then
    serialized.consumer = message.consumer.username
  end

  if conf.status_code_metrics then
    if http_subsystem and message.response then
      serialized.status_code = message.response.status
    elseif not http_subsystem and message.session then
      serialized.status_code = message.session.status
    end
  end

  if conf.bandwidth_metrics then
    if http_subsystem then
      serialized.egress_size = message.response and tonumber(message.response.size)
      serialized.ingress_size = message.request and tonumber(message.request.size)
    else
      serialized.egress_size = message.response and tonumber(message.session.sent)
      serialized.ingress_size = message.request and tonumber(message.session.received)
    end
  end

  if conf.lantency_metrics then
    serialized.latencies = message.latencies
  end

  if conf.upstream_health_metrics then
    exporter.set_export_upstream_health_metrics(true)
  end

  exporter.log(message, serialized)
end


return PrometheusHandler
