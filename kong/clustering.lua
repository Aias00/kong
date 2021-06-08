-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local _M = {}


local semaphore = require("ngx.semaphore")
local ws_client = require("resty.websocket.client")
local ws_server = require("resty.websocket.server")
local ssl = require("ngx.ssl")
local http = require("resty.http")
local cjson = require("cjson.safe")
local declarative = require("kong.db.declarative")
local utils = require("kong.tools.utils")
local openssl_x509 = require("resty.openssl.x509")
local system_constants = require("lua_system_constants")
local ffi = require("ffi")
local pl_tablex = require("pl.tablex")
local kong_constants = require("kong.constants")
local string = string
local assert = assert
local setmetatable = setmetatable
local type = type
local math = math
local pcall = pcall
local pairs = pairs
local tostring = tostring
local ngx = ngx
local ngx_log = ngx.log
local ngx_sleep = ngx.sleep
local cjson_decode = cjson.decode
local cjson_encode = cjson.encode
local kong = kong
local ngx_exit = ngx.exit
local exiting = ngx.worker.exiting
local ngx_time = ngx.time
local ngx_now = ngx.now
local ngx_var = ngx.var
local io_open = io.open
local table_insert = table.insert
local table_remove = table.remove
local inflate_gzip = utils.inflate_gzip
local deflate_gzip = utils.deflate_gzip

-- XXX EE
local get_cn_parent_domain = utils.get_cn_parent_domain

local kong_dict = ngx.shared.kong
local KONG_VERSION = kong.version
local MAX_PAYLOAD = 4 * 1024 * 1024 -- 4MB
local PING_INTERVAL = 30 -- 30 seconds
local PING_WAIT = PING_INTERVAL * 1.5
local OCSP_TIMEOUT = 5000
local WS_OPTS = {
  timeout = 5000,
  max_payload_len = MAX_PAYLOAD,
}
local ngx_OK = ngx.OK
local ngx_ERR = ngx.ERR
local ngx_WARN = ngx.WARN
local ngx_DEBUG = ngx.DEBUG
local ngx_INFO = ngx.INFO
local ngx_NOTICE = ngx.NOTICE
local WEAK_KEY_MT = { __mode = "k", }
local CERT_DIGEST, CERT_CN_PARENT
local CERT, CERT_KEY
local PLUGINS_LIST
local PLUGINS_MAP = {}
local clients = setmetatable({}, WEAK_KEY_MT)
local prefix = ngx.config.prefix()
local CONFIG_CACHE = prefix .. "/config.cache.json.gz"
local CLUSTERING_SYNC_STATUS = kong_constants.CLUSTERING_SYNC_STATUS
local deflated_reconfigure_payload -- Contains a compressed (zlib) payload of the latest database export,
                                   -- that can be used to send configuration to new clients even in a case
                                   -- of a database outage.
local declarative_config
local next_config

local server_on_message_callbacks = {}


local function update_config(config_table, update_cache)
  assert(type(config_table) == "table")

  if not declarative_config then
    declarative_config = declarative.new_config(kong.configuration)
  end

  local entities, err, _, meta, new_hash = declarative_config:parse_table(config_table)
  if not entities then
    return nil, "bad config received from control plane " .. err
  end

  if declarative.get_current_hash() == new_hash then
    ngx_log(ngx_DEBUG, "same config received from control plane, ",
            "no need to reload")
    return true
  end

  -- NOTE: no worker mutex needed as this code can only be
  -- executed by worker 0
  local res, err =
    declarative.load_into_cache_with_events(entities, meta, new_hash)
  if not res then
    return nil, err
  end

  if update_cache then
    -- local persistence only after load finishes without error
    local f, err = io_open(CONFIG_CACHE, "w")
    if not f then
      ngx_log(ngx_ERR, "unable to open cache file: ", err)

    else
      res, err = f:write(assert(deflate_gzip(cjson_encode(config_table))))
      if not res then
        ngx_log(ngx_ERR, "unable to write cache file: ", err)
      end

      f:close()
    end
  end

  return true
end


local function is_timeout(err)
  return err and string.sub(err, -7) == "timeout"
end


local function send_ping(c)
  local hash = declarative.get_current_hash()

  if hash == true then
    hash = string.rep("0", 32)
  end

  local _, err = c:send_ping(hash)
  if err then
    ngx_log(is_timeout(err) and ngx_NOTICE or ngx_WARN, "unable to ping control plane node: ", err)

  else
    ngx_log(ngx_DEBUG, "sent PING packet to control plane")
  end
end


local function communicate(premature, conf)
  if premature then
    -- worker wants to exit
    return
  end

  -- TODO: pick one random CP
  local address = conf.cluster_control_plane

  local c = assert(ws_client:new(WS_OPTS))
  local uri = "wss://" .. address .. "/v1/outlet?node_id=" ..
              kong.node.get_id() ..
              "&node_hostname=" .. kong.node.get_hostname() ..
              "&node_version=" .. KONG_VERSION

  local opts = {
    ssl_verify = true,
    client_cert = CERT,
    client_priv_key = CERT_KEY,
  }
  if conf.cluster_mtls == "shared" then
    opts.server_name = "kong_clustering"
  else
    -- server_name will be set to the host if it is not explicitly defined here
    if conf.cluster_server_name ~= "" then
      opts.server_name = conf.cluster_server_name
    end
  end

  local reconnection_delay = math.random(5, 10)
  local res, err = c:connect(uri, opts)
  if not res then
    ngx_log(ngx_ERR, "connection to control plane ", uri, " broken: ", err,
                     " (retrying after ", reconnection_delay, " seconds)")

    assert(ngx.timer.at(reconnection_delay, communicate, conf))
    return
  end

  -- connection established
  -- first, send out the plugin list to CP so it can make decision on whether
  -- sync will be allowed later
  local _
  _, err = c:send_binary(cjson_encode({ type = "basic_info",
                                        plugins = PLUGINS_LIST, }))
  if err then
    ngx_log(ngx_ERR, "unable to send basic information to control plane: ", uri,
                     " err: ", err,
                     " (retrying after ", reconnection_delay, " seconds)")

    c:close()
    assert(ngx.timer.at(reconnection_delay, communicate, conf))
    return
  end

  local config_semaphore = semaphore.new(0)

  -- how DP connection management works:
  -- three threads are spawned, when any of these threads exits,
  -- it means a fatal error has occurred on the connection,
  -- and the other threads are also killed
  --
  -- * config_thread: it grabs a received declarative config and apply it
  --                  locally. In addition, this thread also persists the
  --                  config onto the local file system
  -- * read_thread: it is the only thread that sends WS frames to the CP
  --                by sending out periodic PING frames to CP that checks
  --                for the healthiness of the WS connection. In addition,
  --                PING messages also contains the current config hash
  --                applied on the local Kong DP
  -- * write_thread: it is the only thread that receives WS frames from the CP,
  --                 and is also responsible for handling timeout detection

  local config_thread = ngx.thread.spawn(function()
    while not exiting() do
      local ok, err = config_semaphore:wait(1)
      if ok then
        local config_table = next_config
        if config_table then
          local pok, res
          pok, res, err = pcall(update_config, config_table, true)
          if pok then
            if not res then
              ngx_log(ngx_ERR, "unable to update running config: ", err)
            end

          else
            ngx_log(ngx_ERR, "unable to update running config: ", res)
          end

          if next_config == config_table then
            next_config = nil
          end
        end

      elseif err ~= "timeout" then
        ngx_log(ngx_ERR, "semaphore wait error: ", err)
      end
    end
  end)

  local write_thread = ngx.thread.spawn(function()
    while not exiting() do
      send_ping(c)

      for _ = 1, PING_INTERVAL do
        ngx_sleep(1)
        if exiting() then
          return
        end
      end
    end
  end)

  local read_thread = ngx.thread.spawn(function()
    local last_seen = ngx_time()
    while not exiting() do
      local data, typ, err = c:recv_frame()
      if err then
        if not is_timeout(err) then
          return nil, "error while receiving frame from control plane: " .. err
        end

        local waited = ngx_time() - last_seen
        if waited > PING_WAIT then
          return nil, "did not receive pong frame from control plane within " .. PING_WAIT .. " seconds"
        end

      else
        if typ == "close" then
          ngx_log(ngx_DEBUG, "received CLOSE frame from control plane")
          return
        end

        last_seen = ngx_time()

        if typ == "binary" then
          data = assert(inflate_gzip(data))

          local msg = assert(cjson_decode(data))

          if msg.type == "reconfigure" then
            if msg.timestamp then
              ngx_log(ngx_DEBUG, "received RECONFIGURE frame from control plane with timestamp: ", msg.timestamp)

            else
              ngx_log(ngx_DEBUG, "received RECONFIGURE frame from control plane")
            end

            next_config = assert(msg.config_table)

            if config_semaphore:count() <= 0 then
              -- the following line always executes immediately after the `if` check
              -- because `:count` will never yield, end result is that the semaphore
              -- count is guaranteed to not exceed 1
              config_semaphore:post()
            end

            send_ping(c)
          end

        elseif typ == "pong" then
          ngx_log(ngx_DEBUG, "received PONG frame from control plane")

        else
          ngx_log(ngx_NOTICE, "received UNKNOWN (", tostring(typ), ") frame from control plane")
        end
      end
    end
  end)

  local ok, err, perr = ngx.thread.wait(read_thread, write_thread, config_thread)

  ngx.thread.kill(read_thread)
  ngx.thread.kill(write_thread)
  ngx.thread.kill(config_thread)

  c:close()

  if not ok then
    ngx_log(ngx_ERR, err)

  elseif perr then
    ngx_log(ngx_ERR, perr)
  end

  if not exiting() then
    assert(ngx.timer.at(reconnection_delay, communicate, conf))
  end
end

_M.communicate = communicate


local check_for_revocation_status
do
  local get_full_client_certificate_chain = require("resty.kong.tls").get_full_client_certificate_chain
  check_for_revocation_status = function ()
    --- XXX EE: ensure the OCSP code path is isolated
    local ocsp = require("ngx.ocsp")
    --- EE

    local cert, err = get_full_client_certificate_chain()
    if not cert then
      return nil, err
    end

    local der_cert
    der_cert, err = ssl.cert_pem_to_der(cert)
    if not der_cert then
      return nil, "failed to convert certificate chain from PEM to DER: " .. err
    end

    local ocsp_url
    ocsp_url, err = ocsp.get_ocsp_responder_from_der_chain(der_cert)
    if not ocsp_url then
      return nil, err or "OCSP responder endpoint can not be determined, " ..
                         "maybe the client certificate is missing the " ..
                         "required extensions"
    end

    local ocsp_req
    ocsp_req, err = ocsp.create_ocsp_request(der_cert)
    if not ocsp_req then
      return nil, "failed to create OCSP request: " .. err
    end

    local c = http.new()
    local res
    res, err = c:request_uri(ocsp_url, {
      headers = {
        ["Content-Type"] = "application/ocsp-request"
      },
      timeout = OCSP_TIMEOUT,
      method = "POST",
      body = ocsp_req,
    })

    if not res then
      return nil, "failed sending request to OCSP responder: " .. tostring(err)
    end
    if res.status ~= 200 then
      return nil, "OCSP responder returns bad HTTP status code: " .. res.status
    end

    local ocsp_resp = res.body
    if not ocsp_resp or #ocsp_resp == 0 then
      return nil, "unexpected response from OCSP responder: empty body"
    end

    res, err = ocsp.validate_ocsp_response(ocsp_resp, der_cert)
    if not res then
      return false, "failed to validate OCSP response: " .. err
    end

    return true
  end
end

local function validate_client_cert(cert)
  if not cert then
    return false, "Data Plane failed to present client certificate " ..
                  "during handshake"
  end

  cert = assert(openssl_x509.new(cert, "PEM"))
  if kong.configuration.cluster_mtls == "shared" then
    local digest = assert(cert:digest("sha256"))

    if digest ~= CERT_DIGEST then
      return false, "Data Plane presented incorrect client certificate " ..
                     "during handshake, expected digest: " .. CERT_DIGEST ..
                     " got: " .. digest
    end

  elseif kong.configuration.cluster_mtls == "pki_check_cn" then
    local cn, cn_parent = get_cn_parent_domain(cert)
    if not cn then
      return false, "Data Plane presented incorrect client certificate " ..
                    "during handshake, unable to extract CN: " .. cn_parent

    elseif cn_parent ~= CERT_CN_PARENT then
      return false, "Data Plane presented incorrect client certificate " ..
                    "during handshake, expected CN as subdomain of: " ..
                    CERT_CN_PARENT .. " got: " .. cn
    end
  elseif kong.configuration.cluster_ocsp ~= "off" then
    local res, err = check_for_revocation_status()
    if res == false then
      ngx_log(ngx_ERR, "DP client certificate was revoked: ", err)
      return ngx_exit(444)

    elseif not res then
      ngx_log(ngx_WARN, "DP client certificate revocation check failed: ", err)
      if kong.configuration.cluster_ocsp == "on" then
        return ngx_exit(444)
      end
    end
  end
  -- with cluster_mtls == "pki", always return true as in this mode we only check
  -- if client cert matches CA and it's already done by Nginx

  return true
end

-- For test only
_M._validate_client_cert = validate_client_cert


-- XXX EE only used for telemetry, remove cruft
local function ws_event_loop(ws, on_connection, on_error, on_message)
  local sem = semaphore.new()
  local queue = { sem = sem, }

  local function queued_send(msg)
    table_insert(queue, msg)
    queue.sem:post()
  end

  local recv = ngx.thread.spawn(function()
    while not exiting() do
      local data, typ, err = ws:recv_frame()
      if err then
        ngx.log(ngx.ERR, "error while receiving frame from peer: ", err)
        if ws.close then
          ws:close()
        end

        if on_connection then
          local _, err = on_connection(false)
          if err then
            ngx_log(ngx_ERR, "error when executing on_connection function: ", err)
          end
        end

        if on_error then
          local _, err = on_error(err)
          if err then
            ngx_log(ngx_ERR, "error when executing on_error function: ", err)
          end
        end
        return
      end

      if (typ == "ping" or typ == "binary") and on_message then
        local cbs
        if typ == "binary" then
          data = assert(inflate_gzip(data))
          data = assert(cjson_decode(data))

          cbs = on_message[data.type]
        else
          cbs = on_message[typ]
        end

        if cbs then
          for _, cb in ipairs(cbs) do
            local _, err = cb(data, queued_send)
            if err then
              ngx_log(ngx_ERR, "error when executing on_message function: ", err)
            end
          end
        end
      elseif typ == "pong" then
        ngx_log(ngx_DEBUG, "received PONG frame from peer")
      end
    end
  end)

  local send = ngx.thread.spawn(function()
    while not exiting() do
      local ok, err = sem:wait(10)
      if ok then
        local payload = table_remove(queue, 1)
        assert(payload, "client message queue can not be empty after semaphore returns")

        if payload == "PONG" then
          local _
          _, err = ws:send_pong()
          if err then
            ngx_log(ngx_ERR, "failed to send PONG back to peer: ", err)
            return ngx_exit(ngx_ERR)
          end

          ngx_log(ngx_DEBUG, "sent PONG packet back to peer")
        elseif payload == "PING" then
          local _
          _, err = send_ping(ws)
          if err then
            ngx_log(ngx_ERR, "failed to send PING to peer: ", err)
            return ngx_exit(ngx_ERR)
          end

          ngx_log(ngx_DEBUG, "sent PING packet to peer")
        else
          payload = assert(deflate_gzip(payload))
          local _, err = ws:send_binary(payload)
          if err then
            ngx_log(ngx_ERR, "unable to send binary to peer: ", err)
          end
        end

      else -- not ok
        if err ~= "timeout" then
          ngx_log(ngx_ERR, "semaphore wait error: ", err)
        end
      end
    end
  end)

  local wait = function()
    return ngx.thread.wait(recv, send)
  end

  return queued_send, wait

end

local function telemetry_communicate(premature, uri, server_name, on_connection, on_message)
  if premature then
    -- worker wants to exit
    return
  end

  local reconnect = function(delay)
    return ngx.timer.at(delay, telemetry_communicate, uri, server_name, on_connection, on_message)
  end

  local c = assert(ws_client:new(WS_OPTS))

  local opts = {
    ssl_verify = true,
    client_cert = CERT,
    client_priv_key = CERT_KEY,
    server_name = server_name,
  }

  local res, err = c:connect(uri, opts)
  if not res then
    local delay = math.random(5, 10)

    ngx_log(ngx_ERR, "connection to control plane ", uri, " broken: ", err,
            " retrying after ", delay , " seconds")

    assert(reconnect(delay))
    return
  end

  local queued_send, wait = ws_event_loop(c,
    on_connection,
    function()
      assert(reconnect(9 + math.random()))
    end,
    on_message)


  if on_connection then
    local _, err = on_connection(true, queued_send)
    if err then
      ngx_log(ngx_ERR, "error when executing on_connection function: ", err)
    end
  end

  wait()

end

_M.telemetry_communicate = telemetry_communicate


function _M.handle_cp_telemetry_websocket()
  -- use mutual TLS authentication
  local ok, err = validate_client_cert(ngx_var.ssl_client_raw_cert)
  if not ok then
    ngx_log(ngx_ERR, err)
    return ngx_exit(444)
  end

  local node_id = ngx_var.arg_node_id
  if not node_id then
    ngx_exit(400)
  end

  local wb, err = ws_server:new(WS_OPTS)
  if not wb then
    ngx_log(ngx_ERR, "failed to perform server side WebSocket handshake: ", err)
    return ngx_exit(444)
  end

  local current_on_message_callbacks = {}
  for k, v in pairs(server_on_message_callbacks) do
    current_on_message_callbacks[k] = v
  end

  local _, wait = ws_event_loop(wb,
    nil,
    function(_)
      return ngx_exit(ngx_ERR)
    end,
    current_on_message_callbacks)

  wait()
end


local MAJOR_MINOR_PATTERN = "^(%d+)%.(%d+)%.%d+"

local function should_send_config_update(node_version, node_plugins)
  if not node_version or not node_plugins then
    return false, "your DP did not provide version information to the CP, " ..
                  "Kong CP after 2.3 requires such information in order to " ..
                  "ensure generated config is compatible with DPs. " ..
                  "Sync is suspended for this DP and will resume " ..
                  "automatically once this DP also upgrades to 2.3 or later"
  end

  local major_cp, minor_cp = KONG_VERSION:match(MAJOR_MINOR_PATTERN)
  local major_node, minor_node = node_version:match(MAJOR_MINOR_PATTERN)
  minor_cp = tonumber(minor_cp)
  minor_node = tonumber(minor_node)

  if major_cp ~= major_node or minor_cp - 2 > minor_node or minor_cp < minor_node then
    return false, "version incompatible, CP version: " .. KONG_VERSION ..
                  " DP version: " .. node_version ..
                  " DP versions acceptable are " ..
                  major_cp .. "." .. math.max(0, minor_cp - 2) .. " to " ..
                  major_cp .. "." .. minor_cp .. "(edges included)",
                  CLUSTERING_SYNC_STATUS.KONG_VERSION_INCOMPATIBLE
  end

  -- iterate over control plane plugins map
  for plugin_name, plugin_meta in pairs(PLUGINS_MAP) do

    -- check plugin only if it is included in the current config export
    if plugin_meta.included == 1 then
      -- if plugin isn't enabled on the data plane node return immediately
      if not node_plugins[plugin_name] then
        return false, "CP and DP do not have same set of plugins installed, " ..
          "plugin: " .. tostring(plugin_name) .. " is missing",
                        CLUSTERING_SYNC_STATUS.PLUGIN_SET_INCOMPATIBLE
      end

      -- ignore plugins without a version (route-by-header is deprecated)
      if plugin_meta.version and node_plugins[plugin_name].version then
        local major_minor_p = plugin_meta.version:match("^(%d+%.%d+)") or "not_a_version"
        local major_minor_np = node_plugins[plugin_name].version:match("^(%d+%.%d+)") or "still_not_a_version"
        
        if major_minor_p ~= major_minor_np then
          return false, "plugin \"" .. plugin_name .. "\" version incompatible, " ..
            "CP version: " .. tostring(plugin_meta.version) ..
            " DP version: " .. tostring(node_plugins[plugin_name].version) ..
            " DP plugin version acceptable is "..
            major_minor_p .. ".x",
          CLUSTERING_SYNC_STATUS.PLUGIN_VERSION_INCOMPATIBLE
        end
      end
    end
  end

  return true
end


local function export_deflated_reconfigure_payload()
  local config_table, err = declarative.export_config()
  if not config_table then
    return nil, err
  end

  -- reset plugins map
  for _, plugin_meta in pairs(PLUGINS_MAP) do
    plugin_meta.included = 0
  end

  -- update plugins map
  if config_table.plugins then
    for _, plugin in pairs(config_table.plugins) do
      PLUGINS_MAP[plugin.name].included = 1
    end
  end

  -- store serialized plugins map for troubleshooting purposes
  local shm_key_name = "clustering:cp_plugins_map:worker_" .. ngx.worker.id()
  kong_dict:set(shm_key_name, cjson_encode(PLUGINS_MAP));

  ngx_log(ngx_DEBUG, "plugin configuration map key: " .. shm_key_name .. " configuration: ", kong_dict:get(shm_key_name))

  local payload, err = cjson_encode({
    type = "reconfigure",
    timestamp = ngx_now(),
    config_table = config_table,
  })
  if not payload then
    return nil, err
  end

  payload, err = deflate_gzip(payload)
  if not payload then
    return nil, err
  end

  deflated_reconfigure_payload = payload

  return payload
end


function _M.handle_cp_websocket()
  -- use mutual TLS authentication
  local ok, err = validate_client_cert(ngx_var.ssl_client_raw_cert)
  if not ok then
    ngx_log(ngx_ERR, err)
    return ngx_exit(444)
  end

  local node_id = ngx_var.arg_node_id
  if not node_id then
    ngx_exit(400)
  end

  local node_hostname = ngx_var.arg_node_hostname
  local node_ip = ngx_var.remote_addr
  local node_version = ngx_var.arg_node_version
  local node_plugins

  local wb, err = ws_server:new(WS_OPTS)
  if not wb then
    ngx_log(ngx_ERR, "failed to perform server side WebSocket handshake: ", err)
    return ngx_exit(444)
  end

  -- connection established
  -- receive basic_info
  local data, typ
  data, typ, err = wb:recv_frame()
  if err then
    ngx_log(ngx_ERR, "failed to receive WebSocket basic_info frame: ", err)
    wb:close()
    return ngx_exit(444)

  elseif typ == "binary" then
    data = cjson_decode(data)
    assert(data.type =="basic_info")
    node_plugins = assert(data.plugins)
  end

  local queue
  do
    local queue_semaphore = semaphore.new()
    queue = {
      wait = function(...)
        return queue_semaphore:wait(...)
      end,
      post = function(...)
        return queue_semaphore:post(...)
      end
    }
  end

  local NODE_PLUGINS_MAP = {}
  for _, plugin in pairs(node_plugins) do
    NODE_PLUGINS_MAP[plugin.name] = { version = plugin.version }
  end

  clients[wb] = {
    queue = queue,
    node_hostname = node_hostname,
    node_ip = node_ip,
    node_version = node_version,
    node_plugins = NODE_PLUGINS_MAP
  }

  if not deflated_reconfigure_payload then
    assert(export_deflated_reconfigure_payload())
  end

  local res, sync_status
  res, err, sync_status = should_send_config_update(node_version, NODE_PLUGINS_MAP)
  if res then
    sync_status = CLUSTERING_SYNC_STATUS.NORMAL

    if deflated_reconfigure_payload then
      table_insert(queue, deflated_reconfigure_payload)
      queue.post()
    else
      ngx_log(ngx_ERR, "unable to export config from database: ".. err)
    end

  else
    ngx_log(ngx_WARN, "unable to send updated configuration to " ..
                      "DP node with hostname: " .. node_hostname ..
                      " ip: " .. node_ip ..
                      " reason: " .. err)
  end
  -- how CP connection management works:
  -- two threads are spawned, when any of these threads exits,
  -- it means a fatal error has occurred on the connection,
  -- and the other thread is also killed
  --
  -- * read_thread: it is the only thread that receives WS frames from the DP
  --                and records the current DP status in the database,
  --                and is also responsible for handling timeout detection
  -- * write_thread: it is the only thread that sends WS frames to the DP by
  --                 grabbing any messages currently in the send queue and
  --                 send them to the DP in a FIFO order. Notice that the
  --                 PONG frames are also sent by this thread after they are
  --                 queued by the read_thread

  local read_thread = ngx.thread.spawn(function()
    local last_seen = ngx_time()
    while not exiting() do
      local data, typ, err = wb:recv_frame()

      if exiting() then
        return
      end

      if err then
        if not is_timeout(err) then
          return nil, err
        end

        local waited = ngx_time() - last_seen
        if waited > PING_WAIT then
          return nil, "did not receive ping frame from data plane within " ..
                      PING_WAIT .. " seconds"
        end

      else
        if typ == "close" then
          return
        end

        if not data then
          return nil, "did not receive ping frame from data plane"
        end

        -- dps only send pings
        if typ ~= "ping" then
          return nil, "invalid websocket frame received from a data plane: " .. typ
        end

        -- queue PONG to avoid races
        table_insert(queue, "PONG")
        queue.post()

        last_seen = ngx_time()

        local ok
        ok, err = kong.db.clustering_data_planes:upsert({ id = node_id, }, {
          last_seen = last_seen,
          config_hash = data ~= "" and data or nil,
          hostname = node_hostname,
          ip = node_ip,
          version = node_version,
          sync_status = sync_status,
        }, { ttl = kong.configuration.cluster_data_plane_purge_delay, })
        if not ok then
          ngx_log(ngx_ERR, "unable to update clustering data plane status: ", err)
        end
      end
    end
  end)

  local write_thread = ngx.thread.spawn(function()
    while not exiting() do
      local ok, err = queue.wait(5)
      if exiting() then
        return
      end
      if ok then
        local payload = table_remove(queue, 1)
        if not payload then
          return nil, "config queue can not be empty after semaphore returns"
        end

        if payload == "PONG" then
          local _, err = wb:send_pong()
          if err then
            if not is_timeout(err) then
              return nil, "failed to send PONG back to data plane: " .. err
            end

            ngx_log(ngx_NOTICE, "failed to send PONG back to data plane: ", err)

          else
            ngx_log(ngx_DEBUG, "sent PONG packet to data plane")
          end

        else
          ok, err = should_send_config_update(node_version, NODE_PLUGINS_MAP)
          if ok then
            -- config update
            local _, err = wb:send_binary(payload)
            if err then
              if not is_timeout(err) then
                return nil, "unable to send updated configuration to node: " .. err
              end

              ngx_log(ngx_NOTICE, "unable to send updated configuration to node: ", err)

            else
              ngx_log(ngx_DEBUG, "sent config update to node")
            end

          else
            ngx_log(ngx_WARN, "unable to send updated configuration to " ..
                              "DP node with hostname: " .. node_hostname ..
                              " ip: " .. node_ip ..
                              " reason: " .. err)
          end
        end

      elseif err ~= "timeout" then
        return nil, "semaphore wait error: " .. err
      end
    end
  end)

  local ok, err, perr = ngx.thread.wait(write_thread, read_thread)

  ngx.thread.kill(write_thread)
  ngx.thread.kill(read_thread)

  wb:send_close()

  if not ok then
    ngx_log(ngx_ERR, err)
    return ngx_exit(ngx_ERR)
  end

  if perr then
    ngx_log(ngx_ERR, perr)
    return ngx_exit(ngx_ERR)
  end

  return ngx_exit(ngx_OK)
end


local function push_config()
  local payload, err = export_deflated_reconfigure_payload()
  if not payload then
    ngx_log(ngx_ERR, "unable to export config from database: " .. err)
    return
  end

  local n = 0
  for _, client in pairs(clients) do
    -- perform plugin compatibility check
    local res, err = should_send_config_update(client.node_version, client.node_plugins)
    if res then
      table_insert(client.queue, payload)
      client.queue.post()
      n = n + 1
    else
      ngx_log(ngx_WARN, "unable to send updated configuration to " ..
        "DP node with hostname: " .. client.node_hostname ..
        " ip: " .. client.node_ip ..
        " reason: " .. err)
    end
  end

  ngx_log(ngx_DEBUG, "config pushed to ", n, " clients")
end


local function push_config_timer(premature, push_config_semaphore, delay)
  if premature then
    return
  end

  local _, err = export_deflated_reconfigure_payload()
  if err then
    ngx_log(ngx_ERR, "unable to export initial config from database: " .. err)
  end

  while not exiting() do
    local ok, err = push_config_semaphore:wait(1)
    if exiting() then
      return
    end
    if ok then
      ok, err = pcall(push_config)
      if ok then
        local sleep_left = delay
        while sleep_left > 0 do
          if sleep_left <= 1 then
            ngx.sleep(sleep_left)
            break
          end

          ngx.sleep(1)

          if exiting() then
            return
          end

          sleep_left = sleep_left - 1
        end

      else
        ngx_log(ngx_ERR, "export and pushing config failed: ", err)
      end

    elseif err ~= "timeout" then
      ngx_log(ngx_ERR, "semaphore wait error: ", err)
    end
  end
end


local function init_mtls(conf)
  local f, err = io_open(conf.cluster_cert, "r")
  if not f then
    return nil, "unable to open cluster cert file: " .. err
  end

  local cert
  cert, err = f:read("*a")
  if not cert then
    f:close()
    return nil, "unable to read cluster cert file: " .. err
  end

  f:close()

  CERT, err = ssl.parse_pem_cert(cert)
  if not CERT then
    return nil, err
  end

  cert = openssl_x509.new(cert, "PEM")

  CERT_DIGEST = cert:digest("sha256")
  local _
  _, CERT_CN_PARENT = get_cn_parent_domain(cert)

  f, err = io_open(conf.cluster_cert_key, "r")
  if not f then
    return nil, "unable to open cluster cert key file: " .. err
  end

  local key
  key, err = f:read("*a")
  if not key then
    f:close()
    return nil, "unable to read cluster cert key file: " .. err
  end

  f:close()

  CERT_KEY, err = ssl.parse_pem_priv_key(key)
  if not CERT_KEY then
    return nil, err
  end

  return true
end


function _M.init(conf)
  assert(conf, "conf can not be nil", 2)

  if conf.role ~= "data_plane" and conf.role ~= "control_plane" then
    return
  end

  assert(init_mtls(conf))
end


function _M.init_worker(conf)
  assert(conf, "conf can not be nil", 2)

  if conf.role ~= "data_plane" and conf.role ~= "control_plane" then
    return
  end

  PLUGINS_LIST = assert(kong.db.plugins:get_handlers())
  table.sort(PLUGINS_LIST, function(a, b)
    return a.name:lower() < b.name:lower()
  end)

  PLUGINS_LIST = pl_tablex.map(function(p)
    return { name = p.name, version = p.handler.VERSION, }
  end, PLUGINS_LIST)

  if conf.role == "control_plane" then
    for _, plugin in pairs(PLUGINS_LIST) do
      PLUGINS_MAP[plugin.name] = { version = plugin.version, included = 0 }
    end
  end

  if conf.role == "data_plane" then
    -- ROLE = "data_plane"

    if ngx.worker.id() == 0 then
      local f = io_open(CONFIG_CACHE, "r")
      if f then
        local config, err = f:read("*a")
        if not config then
          ngx_log(ngx_ERR, "unable to read cached config file: ", err)
        end

        f:close()

        if config and #config > 0 then
          ngx_log(ngx_INFO, "found cached copy of data-plane config, loading..")

          local err

          config, err = inflate_gzip(config)
          if config then
            config = cjson_decode(config)

            if config then
              local res
              res, err = update_config(config, false)
              if not res then
                ngx_log(ngx_ERR, "unable to update running config from cache: ", err)
              end
            end

          else
            ngx_log(ngx_ERR, "unable to inflate cached config: ",
                    err, ", ignoring...")
          end
        end

      else
        -- CONFIG_CACHE does not exist, pre create one with 0600 permission
        local fd = ffi.C.open(CONFIG_CACHE, bit.bor(system_constants.O_RDONLY(),
                                                    system_constants.O_CREAT()),
                                            bit.bor(system_constants.S_IRUSR(),
                                                    system_constants.S_IWUSR()))
        if fd == -1 then
          ngx_log(ngx_ERR, "unable to pre-create cached config file: ",
                  ffi.string(ffi.C.strerror(ffi.errno())))

        else
          ffi.C.close(fd)
        end
      end

      assert(ngx.timer.at(0, communicate, conf))
    end

  elseif conf.role == "control_plane" then
    -- ROLE = "control_plane"

    local push_config_semaphore = semaphore.new()

    -- Sends "clustering", "push_config" to all workers in the same node, including self
    local function post_push_config_event()
      local res, err = kong.worker_events.post("clustering", "push_config")
      if not res then
        ngx_log(ngx_ERR, "unable to broadcast event: ", err)
      end
    end

    -- Handles "clustering:push_config" cluster event
    local function handle_clustering_push_config_event(data)
      ngx_log(ngx_DEBUG, "received clustering:push_config event for ", data)
      post_push_config_event()
    end


    -- Handles "dao:crud" worker event and broadcasts "clustering:push_config" cluster event
    local function handle_dao_crud_event(data)
      if type(data) ~= "table" or data.schema == nil or data.schema.db_export == false then
        return
      end

      kong.cluster_events:broadcast("clustering:push_config", data.schema.name .. ":" .. data.operation)

      -- we have to re-broadcast event using `post` because the dao
      -- events were sent using `post_local` which means not all workers
      -- can receive it
      post_push_config_event()
    end

    -- The "clustering:push_config" cluster event gets inserted in the cluster when there's
    -- a crud change (like an insertion or deletion). Only one worker per kong node receives
    -- this callback. This makes such node post push_config events to all the cp workers on
    -- its node
    kong.cluster_events:subscribe("clustering:push_config", handle_clustering_push_config_event)

    -- The "dao:crud" event is triggered using post_local, which eventually generates an
    -- ""clustering:push_config" cluster event. It is assumed that the workers in the
    -- same node where the dao:crud event originated will "know" about the update mostly via
    -- changes in the cache shared dict. Since DPs don't use the cache, nodes in the same
    -- kong node where the event originated will need to be notified so they push config to
    -- their DPs
    kong.worker_events.register(handle_dao_crud_event, "dao:crud")

    -- When "clustering", "push_config" worker event is received by a worker,
    -- it loads and pushes the config to its the connected DPs
    kong.worker_events.register(function(_)
      if push_config_semaphore:count() <= 0 then
        -- the following line always executes immediately after the `if` check
        -- because `:count` will never yield, end result is that the semaphore
        -- count is guaranteed to not exceed 1
        push_config_semaphore:post()
      end
    end, "clustering", "push_config")

    ngx.timer.at(0, push_config_timer, push_config_semaphore, conf.db_update_frequency)
  end
end


function _M.register_server_on_message(typ, cb)
  if not server_on_message_callbacks[typ] then
    server_on_message_callbacks[typ] = { cb }
  else
    table.insert(server_on_message_callbacks[typ], cb)
  end
end

return _M
