-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]


local uh = require "spec/upgrade_helpers"


describe("database migration", function()
  if uh.database_type() == "postgres" then
    uh.all_phases("does not have ttls table", function()
      assert.not_database_has_relation("ttls")
    end)
  end

  do -- wasm
    uh.old_after_up("has created the expected new columns", function()
      assert.table_has_column("filter_chains", "id", "uuid")
      assert.table_has_column("filter_chains", "name", "text")
      assert.table_has_column("filter_chains", "enabled", "boolean")

      assert.table_has_column("filter_chains", "cache_key", "text")
      assert.table_has_column("filter_chains", "filters", "ARRAY")
      assert.table_has_column("filter_chains", "tags", "ARRAY")
      assert.table_has_column("filter_chains", "created_at", "timestamp with time zone")
      assert.table_has_column("filter_chains", "updated_at", "timestamp with time zone")

      assert.table_has_column("filter_chains", "route_id", "uuid")
      assert.table_has_column("filter_chains", "service_id", "uuid")
      assert.table_has_column("filter_chains", "ws_id", "uuid")
    end)

    if uh.database_type() == "postgres" then
      uh.all_phases("has created the expected triggers", function ()
        assert.database_has_trigger("filter_chains_sync_tags_trigger")
      end)
    end
  end
end)
