-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local _M = {}
local _MT = { __index = _M, }


local constants = require("kong.constants")
local events = require("kong.clustering.events")
local strategy = require("kong.clustering.services.sync.strategies.postgres")
local rpc = require("kong.clustering.services.sync.rpc")


local FIRST_SYNC_DELAY = 0.2  -- seconds
local EACH_SYNC_DELAY  = constants.CLUSTERING_PING_INTERVAL   -- 30 seconds


function _M.new(db, is_cp)
  local strategy = strategy.new(db)

  local self = {
    db = db,
    strategy = strategy,
    rpc = rpc.new(strategy),
    is_cp = is_cp,
  }

  -- only cp needs hooks
  if is_cp then
    self.hooks = require("kong.clustering.services.sync.hooks").new(strategy)
  end

  return setmetatable(self, _MT)
end


function _M:init(manager)
  if self.hooks then
    self.hooks:register_dao_hooks()
  end
  self.rpc:init(manager, self.is_cp)
end


function _M:init_worker()
  -- is CP, enable clustering broadcasts
  if self.is_cp then
    events.init()

    self.strategy:init_worker()
    return
  end

  -- is DP, sync only in worker 0
  if ngx.worker.id() ~= 0 then
    return
  end

  local worker_events = assert(kong.worker_events)

  -- if rpc is ready we will start to sync
  worker_events.register(function(capabilities_list)
    -- we only check once
    if self.inited then
      return
    end

    local has_sync_v2

    -- check cp's capabilities
    for _, v in ipairs(capabilities_list) do
      if v == "kong.sync.v2" then
        has_sync_v2 = true
        break
      end
    end

    -- cp does not support kong.sync.v2
    if not has_sync_v2 then
      ngx.log(ngx.WARN, "rpc sync is disabled in CP.")
      return
    end

    self.inited = true

    -- sync to CP ASAP
    assert(self.rpc:sync_once(FIRST_SYNC_DELAY))

    assert(self.rpc:sync_every(EACH_SYNC_DELAY))

  end, "clustering:jsonrpc", "connected")
end


return _M
