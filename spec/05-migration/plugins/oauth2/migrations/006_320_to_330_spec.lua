
-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local uh = require "spec/upgrade_helpers"

describe("database migration", function ()
  if uh.database_type() == "postgres" then
    uh.all_phases("has created the expected triggers", function ()
      assert.database_has_trigger("oauth2_authorization_codes_ttl_trigger")
      assert.database_has_trigger("oauth2_tokens_ttl_trigger")
    end)
  end
end)
