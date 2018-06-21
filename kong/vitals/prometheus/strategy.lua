local fmt        = string.format
local sub        = string.sub
local math_min   = math.min
local math_max   = math.max
local math_floor = math.floor
local log        = ngx.log
local DEBUG      = ngx.DEBUG
local WARN       = ngx.WARN


local http = require "resty.http"
local cjson = require "cjson.safe"
local null = cjson.null -- or ngx.null
local table_insert = table.insert
local table_concat = table.concat
local ngx_escape_uri = ngx.escape_uri
local ngx_time = ngx.time


local ok, new_tab = pcall(require, "table.new")
if not ok or type(new_tab) ~= "function" then
    new_tab = function (narr, nrec) return {} end
end

local MINUTE = 60

local SCRAPE_INTERVAL = 30

local _log_prefix = "[vitals-strategy] "

local _M = { }

local mt = {
  __index = function(_, k, ...)
    local v = _M[k]
    if v ~= nil then
      return v
    end
    -- shouldn't go here, needs to add dummy functions in this module
    log(DEBUG, _log_prefix, fmt("function %s is not implemented for \"prometheus\" strategy\"", k))
    return function(...)
      return true, nil
    end
  end
}

function _M.select_phone_home()
  return {}, nil
end

function _M.node_exists()
  return true, nil
end


function _M.new(_, opts)
  if not opts then
    opts = {
      host = "127.0.0.1",
      port = 9090
    }
  end

  local custom_filters_str = table_concat(opts.custom_filters or {}, ",")

  local common_stats_metrics = {
    -- { label_name_to_be_returned, query string, is_rate }
    { "cache_datastore_hits_total", fmt("sum(kong_cache_datastore_hits_total{%s})", custom_filters_str), true },
    { "cache_datastore_misses_total", fmt("sum(kong_cache_datastore_misses_total{%s})", custom_filters_str), true },
    { "latency_proxy_request_min_ms", fmt("min(kong_latency_proxy_request{%s})", custom_filters_str) }, -- statsd_exporter will sometimes return -1
    { "latency_proxy_request_max_ms", fmt("max(kong_latency_proxy_request{%s})", custom_filters_str) },
    { "latency_upstream_min_ms", fmt("min(kong_latency_upstream{%s})", custom_filters_str) }, -- statsd_exporter will sometimes return -1
    { "latency_upstream_max_ms", fmt("max(kong_latency_upstream{%s})", custom_filters_str) },
    { "requests_proxy_total", fmt("sum(kong_requests_proxy{%s})", custom_filters_str), true },
    { "latency_proxy_request_avg_ms",
      fmt("sum(rate(kong_latency_proxy_request_sum{%s}[1m])) / sum(rate(kong_latency_proxy_request_count{%s}[1m]))",
        custom_filters_str, custom_filters_str) }, -- we only have minute level precision
    { "latency_upstream_avg_ms",
      fmt("sum(rate(kong_latency_upstream_sum{%s}[1m])) / sum(rate(kong_latency_upstream_count{%s}[1m]))",
        custom_filters_str, custom_filters_str) },
  }

  local self = {
    host                 = opts.host,
    port                 = tonumber(opts.port),
    connection_timeout   = tonumber(opts.connection_timeout) or 5000, -- 5s
    custom_filters_str   = custom_filters_str,
    has_custom_filters   = #custom_filters_str > 0,
    common_stats_metrics = common_stats_metrics,
  }

  return setmetatable(self, mt)
end

function _M.init()
  return true, nil
end

function _M:interval_width(level)
  if level == "seconds" then
    return SCRAPE_INTERVAL
  elseif level == "minutes" then
    return 60
  else
    return nil, "interval must be 'seconds' or 'minutes'"
  end
end

function _M:query(start_ts, metrics_query, interval)
  start_ts = tonumber(start_ts)
  if not start_ts then
    return nil, "expect first paramter to be a number"
  end

  if type(metrics_query) ~= "table" then
    return nil, "expect second paramter to be a table"
  end

  -- resty.http can only be initialized per request
  local client, err = http.new()
  if not client then
    return nil, "error initializing resty http: " .. err
  end

  client:set_timeout(self.connection_timeout)

  local _, err = client:connect(self.host, self.port)

  if err then
    return nil, "error connecting Prometheus: " .. err
  end

  local stats = {}

  local end_ts = ngx_time()
  if start_ts >= end_ts then
    return nil, "expect first parameter to be a timestamp in the past"
  end

  -- round to nearest next interval
  end_ts = end_ts - end_ts % interval + interval
  -- round to nearest previous interval
  start_ts = start_ts - start_ts % interval - interval


  for i, q in ipairs(metrics_query) do

    local res, err = client:request {
        method = "GET",
        path = "/api/v1/query_range?query=" ..  ngx_escape_uri(q[2]) .. "&start=" .. start_ts 
                  .. "&end=" .. end_ts .. "&step=" .. interval,
    }
    if not res then
      return nil, "request Prometheus failed: " .. err
    end

    local body, err = res:read_body()
    if not body then
      return nil, "read Prometheus response failed: " .. err
    end

    local stat, err = cjson.decode(body)

    if not stat then
      return nil, "json decode failed " .. err
    elseif stat.status ~= "success" then
      return nil, "Prometheus reported " .. stat.errorType .. ": " .. stat.error
    end

    stats[i] = stat.data.result
  end
  
  client:set_keepalive()

  return stats, nil, end_ts - start_ts
end


-- Converts common metrics from prometheus format to vitals format
-- @param[type=table] metrics_query A table containing expected labels and prometheus query strings
-- @param[type=table] prometheus_stats Json-decoded array returned from prometheus
-- @param[type=number] interval The datapoint step
-- @param[type=number] duration_seconds The time range of query
-- @param[type=boolean] aggregate If we are showing cluster metrics or not, only influence the meta.level value, there won't be any aggregation
-- @return A table in vitals format
local function translate_vitals_stats(metrics_query, prometheus_stats, interval, duration_seconds, aggregate)
  local ret = {
    meta = {
      nodes = {},
      stat_labels = new_tab(#metrics_query, 0)
    },
    stats = {},
  }
  
  if interval == MINUTE then
    ret.meta.interval = "minutes"
  elseif interval == SCRAPE_INTERVAL then
    ret.meta.interval = "seconds"
  else
    return nil, "invalid interval value, got ", interval, ", expecting 'minutes' or 'seconds'"
  end

  ret.meta.interval_width = interval

  if aggregate then
    ret.meta.level = "cluster"
  else
    ret.meta.level = "node"
  end

  local earliest_ts = 0xFFFFFFFF
  local latest_ts = 0

  local node_stats = ret.stats
  local last_metric_name
  local expected_dp_count = duration_seconds / interval
  for idx, series_list in ipairs(prometheus_stats) do
    local metric_name = metrics_query[idx][1]
    if last_metric_name ~= metric_name then
      last_metric_name = metric_name
      table_insert(ret.meta.stat_labels, metric_name)
    end

    local is_rate = metrics_query[idx][3]
    
    local series_not_empty = false
    -- make sure every metrics is aggreated to one time series
    for series_idx, series in ipairs(series_list) do
      if series_idx > 1 then
        log(WARN, _log_prefix, "metrics ", metric_name, " has ", series_idx, " series, may be it's not correctly aggregated?")
        break
      end

      series_not_empty = true
      -- Add to meta,nodes
      -- TODO: change according to exporter tags
      local host = nil -- agg.tags.instance
      -- TODO: cluster type
      if aggregate then
        host = "cluster"
      end
      if not node_stats[host] then
        node_stats[host] = new_tab(0, expected_dp_count)
        ret.meta.nodes[host] = { hostname = host }
      end

      local dps = series.values

      local n = node_stats[host]
      local start_k, current_earliest_ts, current_latest_ts

      current_earliest_ts = dps[1][1]
      current_latest_ts = dps[#dps][1]

      earliest_ts = math_min(earliest_ts, current_earliest_ts)
      latest_ts = math_max(latest_ts, current_latest_ts)
      -- add empty data points
      for ts = earliest_ts, current_earliest_ts - 1, interval do
        -- key should always be string, as we inserted them as string
        ts = tostring(ts)
        if not n[ts] then
          n[ts] = {}
        end
        -- add empty data points for other metrics that didn't reached this timestamp
        for i = #n[ts] + 1, #ret.meta.stat_labels, 1 do
          n[ts][i] = null
        end
      end

      for ts = current_latest_ts + 1, latest_ts, interval do
        -- key should always be string, as we inserted them as string
        ts = tostring(ts)
        if not n[ts] then
          n[ts] = {}
        end
        -- add empty data points for other metrics that didn't reached this timestamp
        for i = #n[ts] + 1, #ret.meta.stat_labels, 1 do
          n[ts][i] = null
        end
      end

      local last_value, incr_value
      start_k = earliest_ts
      for _, dp in ipairs(dps) do
        -- if we use integer as key, cjson will complain excessively sparse array
        local k = fmt("%d", dp[1])
        -- 'NaN' will be parsed to math.nan and cjson will not encode it
        local v = tonumber(dp[2])
        -- See http://lua-users.org/wiki/InfAndNanComparisons
        if v ~= v then
          v = nil
        end
        while k - start_k > interval do
          start_k = tostring(start_k + interval)
          if not n[start_k] then
            n[start_k] = {}
          end
          -- add empty data points for other metrics that didn't reached this timestamp
          for i = #n[start_k] + 1, #ret.meta.stat_labels, 1 do
            n[start_k][i] = null
          end
        end

        if not n[k] then
          n[k] = {}
        end
        -- add empty placeholder for other metrics
        for i = #n[k] + 1, #ret.meta.stat_labels - 1, 1 do
          n[k][i] = null
        end
        -- add the real data point
        if is_rate and v ~= nil then
          if last_value ~= nil then -- skip the first data point
            -- add the data point
            if last_value > v then-- detect counter reset
              incr_value = v
            else
              incr_value = v - last_value
            end
            n[k][#n[k] + 1] = incr_value
          end
          last_value = v
        else
          n[k][#n[k] + 1] = v == nil and null or math_floor(v)
        end

        start_k = k

      end -- for series_idx, series in ipairs(series_list) do

    end -- for idx, series in ipairs(prometheus_stats) do

    if not series_not_empty then
      log(DEBUG, _log_prefix, "metrics ", metric_name, " has no series")
    end

  end

  ret.meta.earliest_ts = earliest_ts
  ret.meta.latest_ts = latest_ts

  return ret, nil
end


-- Converts status codes metrics from prometheus format to vitals format
-- @param[type=table] metrics_query A table containing expected labels and prometheus query strings
-- @param[type=table] prometheus_stats Json-decoded array returned from prometheus
-- @param[type=number] interval The datapoint step
-- @param[type=number] duration_seconds The time range of query
-- @param[type=boolean] aggregate If we are showing cluster metrics or not, only influence the meta.level value, there won't be any aggregation
-- @param[type=boolean] merge_status_class If we are showing "2xx" instead of "200", "201"
-- @param[type=string] key_by (optional) Group result by the value of this label
-- @return A table in vitals format
local function translate_vitals_status(metrics_query, prometheus_stats, interval, duration_seconds, aggregate, merge_status_class, key_by)
  local ret = {
    meta = {
      nodes = {},
      stat_labels = {}
    },
    stats = {},
  }
  
  if interval == MINUTE then
    ret.meta.interval = "minutes"
  elseif interval == SCRAPE_INTERVAL then
    ret.meta.interval = "seconds"
  else
    return nil, "invalid interval value, got ", interval, ", expecting 'minutes' or 'seconds'"
  end

  ret.meta.interval_width = interval

  if aggregate then
    ret.meta.level = "cluster"
  else
    ret.meta.level = "node"
  end

  local stats = ret.stats
  local stat_labels_inserted = false
  local expected_dp_count = duration_seconds / interval
  -- we only has one query
  for idx, series in ipairs(prometheus_stats[1]) do
    if not stat_labels_inserted then
      local metric_name = metrics_query[idx][1]
      table_insert(ret.meta.stat_labels, metric_name)
      stat_labels_inserted = true
    end

    local n
    if not key_by then
      -- default by host name
      -- Add to meta,nodes
      -- TODO: change according to exporter tags
      local host = nil -- agg.tags.instance
      -- TODO: cluster type
      if aggregate then
        host = "cluster"
      end
      if not stats[host] then
        stats[host] = new_tab(0, expected_dp_count)
        ret.meta.nodes[host] = { hostname = host }
      end
      n = stats[host]
    else
      local tag_value = series.metric[key_by]
      if tag_value == nil then
        -- FIXME: broken metrics or old statsd rules? ignoring this metric
        n = {}
      else
        if not stats[tag_value] then
          stats[tag_value] = new_tab(0, expected_dp_count)
        end
        n = stats[tag_value]
      end
    end

    local status_code_tag = series.metric['status_code']
    if status_code_tag then
      local code
      if merge_status_class then
        code = sub(status_code_tag, 1, 1) .. "xx"
      else
        code = status_code_tag
      end

      local last_value, incr_value
      for _, dp in ipairs(series.values) do
        -- if we use integer as key, cjson will complain excessively sparse array
        local k = fmt("%d", dp[1])
        -- 'NaN' will be parsed to math.nan and cjson will not encode it
        local v = tonumber(dp[2])
        -- See http://lua-users.org/wiki/InfAndNanComparisons
        if v ~= v then
          v = nil
        end
        if v ~= null and v ~= 0 then
          if not n[k] then
              n[k] = {}
          end
          
          if last_value ~= nil then -- skip the first data point
            -- add the data point
            if last_value > v then-- detect counter reset
              incr_value = v
            else
              incr_value = v - last_value
            end

            if merge_status_class then
              n[k][code] = incr_value + (n[k][code] or 0)
            else
              n[k][code] = incr_value
            end
          end
          last_value = v
        end

      end -- for _, dp in ipairs(series.values) do
    end -- do

  end -- for idx, series in ipairs(prometheus_stats[1]) do

  return ret, nil
end


function _M:select_stats(query_type, level, node_id, start_ts)
  -- rate{dropcounter,,0}: treat the rate at the missing datapoint as 0, otherwise we'll get a negative rate
  local interval
  if query_type == "minutes" then
    interval = MINUTE
    -- backward compatibility for client that doesn't send start_ts
    if start_ts == nil then
      start_ts = ngx_time() - 720 * 60
    end
  else
    interval = SCRAPE_INTERVAL
    -- backward compatibility for client that doesn't send start_ts
    if start_ts == nil then
      start_ts = ngx_time() - 5 * 60
    end
  end

  local metrics = self.common_stats_metrics

  local res, err, duration_seconds = self:query(
    start_ts,
    metrics,
    interval
  )

  if res then
    return translate_vitals_stats(metrics, res, interval, duration_seconds,
      true -- Cloud: use true to hide node-level metrics
    )
  else
    return res, err
  end
end

function _M:select_status_codes(opts)
  local interval
  local start_ts = opts.start_ts
  if opts.duration == MINUTE then
    interval = MINUTE
    -- backward compatibility for client that doesn't send start_ts
    if start_ts == nil then
      start_ts = ngx_time() - 720 * 60
    end
  else
    interval = SCRAPE_INTERVAL
    -- backward compatibility for client that doesn't send start_ts
    if start_ts == nil then
      start_ts = ngx_time() - 5 * 60
    end
  end
  
  local merge_status_class = true

  -- build the filter table
  local filters = { }
  local filters_count = 0
  if self.has_custom_filters then
    filters_count = filters_count + 1
    filters[1] = self.custom_filters_str
  end

  local entity_type = opts.entity_type
  if entity_type ~= "cluster" then
    merge_status_class = false
  end

  local metric_name = "kong_status_code"
  local filter_fmt = "sum(%s{%s}) by (status_code)"

  if entity_type == "route" then
    metric_name = "kong_status_code_per_consumer"
    filters[filters_count + 1] = "route_id=\"" .. opts.entity_id .. "\""
    -- filter_fmt = "sum(%s{%s}) by (status_code)"
  elseif entity_type == "consumer_route" then
    metric_name = "kong_status_code_per_consumer"
    -- in statsd plugin we are regulating \. to _
    filters[filters_count + 1] = "consumer=\"" .. opts.entity_id .. "\""
    filters[filters_count + 2] = "route_id!=\"\"" -- route_id = "" will be per consumer per service events
    filter_fmt = "sum(%s{%s}) by (status_code, route_id)"
  elseif entity_type == "consumer" then
    metric_name = "kong_status_code_per_consumer"
    -- in statsd plugin we are regulating \. to _
    filters[filters_count + 1] = "consumer=\"" .. opts.entity_id .. "\""
    filters[filters_count + 2] = "route_id!=\"\"" -- route_id = "" will be per consumer per service events
    -- filter_fmt = "sum(%s{%s}) by (status_code)"
  elseif entity_type == "service" then
    -- don't merge kong_status_code_per_consumer with kong_status_code
    -- because there's not always consumer present

    -- use the default status_code metrics
    -- in statsd plugin we are regulating \. to _
    filters[filters_count + 1] = "service=\"" .. opts.entity_id .. "\""
  end
  
  filters = table_concat(filters, ",")

  -- we only query one metric for select_status_codes
  local metric = { "status_code", fmt(filter_fmt, metric_name, filters), true }

  local res, err, duration_seconds = self:query(
    start_ts,
    { metric },
    interval
  )

  if res then
    return translate_vitals_status({ metric }, res, interval, duration_seconds,
      true, -- aggregate: GUI will not ask for node-level metrics
      merge_status_class,
      opts.key_by
    )
  end

  return nil, err
end

function _M:select_consumer_stats(opts)
  -- TODO: needs implementing when vitals in dev portal is merged
  return {}
end



return _M
