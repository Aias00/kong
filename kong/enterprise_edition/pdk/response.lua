-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local phase_checker = require "kong.pdk.private.phases"

local check_phase = phase_checker.check
local PHASES = phase_checker.phases

local function new(self, module, major_version)
  local _response = module.new(self, major_version)

  local hooks = {}
  local response = {
    register_hook = function(method, hook_method, ctx)
      check_phase(PHASES.init_worker)
      local hook = { method = hook_method, ctx = ctx }
      if hooks[method] then
        table.insert(hooks[method], hook)
      else
        hooks[method] = { hook }
      end
    end,
  }

  local mt = {
    __index = function(self, k)
      if hooks[k] then
        return function(...)
          local arg = { ... }
          for _, hook in ipairs(hooks[k]) do
            if hook.ctx then
              arg = { hook.method(hook.ctx, unpack(arg)) }
            else
              arg = { hook.method(unpack(arg)) }
            end
          end
          return _response[k](unpack(arg))
        end
      else
        return _response[k]
      end
    end,
    __newindex = function(self, k, v)
      _response[k] = v
    end,
  }

  setmetatable(response, mt)
  return response
end

return {
  new = new,
}
