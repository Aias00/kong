-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]


local ewma = require "kong.plugins.ai-proxy-advanced.balancer.ewma"
local llm_state = require "kong.llm.state"

local algo = {}
algo.__index = algo

function algo:afterHostUpdate()
  return ewma.afterHostUpdate(self)
end


function algo:afterBalance(conf, target)
  local data_point
  if conf.latency_strategy == "tpot" then
    data_point = llm_state.get_metrics("tpot_latency")
  elseif conf.latency_strategy == "e2e" then
    data_point = llm_state.get_metrics("e2e_latency")
  else
    error("unknown token strategy: " .. conf.tokens_count_strategy)
  end

  -- get the tokens coun as datapoint
  return ewma.afterBalance(self, target, data_point)
end


function algo:getPeer(...)
  return ewma.getPeer(self, ...)
end

function algo:cleanup()
  return ewma.cleanup(self)
end

function algo.new(targets)
  return setmetatable(ewma.new(targets), algo)
end

return algo
