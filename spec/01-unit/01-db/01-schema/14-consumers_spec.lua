-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local enums = require "kong.enterprise_edition.dao.enums"
local consumers = require "kong.db.schema.entities.consumers"
local Entity       = require "kong.db.schema.entity"

local Consumers = assert(Entity.new(consumers))

describe("consumers schema", function()
  describe("username attribute", function()
    -- acceptance
    it("accepts valid names", function()
      local valid_names = {
        "example",
        "EXAMPLE",
        "exa.mp.le",
        "3x4mp13",
        "3x4-mp-13",
        "3x4_mp_13",
        "~3x4~mp~13",
        "~3..x4~.M-p~1__3_",
        "孔",
        "Конг",
        "🦍",
      }

      for i = 1, #valid_names do
        local ok, err = Consumers:validate({
          username = valid_names[i],
          type = enums.CONSUMERS.TYPE.PROXY,
        })
        assert.is_nil(err)
        assert.is_true(ok)
      end
    end)
  end)
end)
