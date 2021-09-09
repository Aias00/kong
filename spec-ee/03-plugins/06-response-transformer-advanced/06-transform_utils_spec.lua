-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local transform_utils = require "kong.plugins.response-transformer-advanced.transform_utils"

describe("Plugin: response-transformer-advanced (utils)", function()
  describe(".skip_transform", function()
    local skip_transform = transform_utils.skip_transform

    it("doesn't skip any response code if allow is nil or empty", function()
      assert.falsy(skip_transform(200, nil))
      assert.falsy(skip_transform(200, {}))
      assert.falsy(skip_transform(400, nil))
      assert.falsy(skip_transform(400, {}))
      assert.falsy(skip_transform(500, nil))
      assert.falsy(skip_transform(500, {}))
    end)

    it("doesn't skip allowed codes", function()
      assert.falsy(skip_transform(200, {"200"}))
      assert.falsy(skip_transform(400, {"400"}))
      assert.falsy(skip_transform(500, {"500"}))
    end)

    it("skips non-allowed single status code and status code ranges", function()
      assert.truthy(skip_transform(200, {"400"}))
      assert.truthy(skip_transform(200, {"400", "300-400"}))
    end)

    it("skips non-allowed status code ranges", function()
      assert.truthy(skip_transform(200, {"201-300"}))
      assert.truthy(skip_transform(300, {"201-299", "301-399"}))
    end)

    it("skips non-allowed response status codes", function()
      assert.truthy(skip_transform(200, {"400"}))
      assert.truthy(skip_transform(417, {"400"}))
      assert.truthy(skip_transform(400, {"500"}))
    end)

    it("doesn't skip allowed status code ranges", function()
      assert.falsy(skip_transform(201, {"201-300"}))
      assert.falsy(skip_transform(301, {"201-299", "301-399"}))
    end)
  end)
end)
