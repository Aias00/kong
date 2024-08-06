-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

--
-- imports
--

local openai_mock = require("spec.helpers.ai.openai_mock")

local known_text_embeddings = require("spec.helpers.ai.embeddings_mock").known_text_embeddings

--
-- test setup
--

-- initialize kong.global (so logging works, e.t.c.)
local kong_global = require "kong.global"
_G.kong = kong_global.new()
kong_global.init_pdk(kong, nil)

--
-- tests
--

describe("[openai]", function()
  describe("embeddings:", function()
    it("can generate embeddings", function()
      openai_mock.setup(finally)
      local embeddings, err = require("kong.ai.embeddings").new({
        provider = "openai",
        name = "text-embedding-3-small",
        auth = { token = "fake" },
      }, 4)
      assert.is_nil(err)

      for prompt, embedding in pairs(known_text_embeddings) do
        local found_embedding, err = embeddings:generate(prompt, 128)
        assert.is_nil(err)
        assert.are.same(embedding, found_embedding)
      end
    end)
  end)
end)
