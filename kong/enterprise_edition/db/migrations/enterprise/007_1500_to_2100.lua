-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local operations = require "kong.enterprise_edition.db.migrations.operations.1500_to_2100"
local log          = require "kong.cmd.utils.log"


-- We do not read this information from the schemas because these change over time.
-- This information represents the data in the schemas as of Kong 1.5.0.0,
-- topologically sorted.
local ee_core_entities = {
  {
    name = "rbac_users",
    primary_key = "id",
    -- do not convert "user_token" because it is unique_across_ws
    uniques = {"name"},
    fks = {},
  }, {
    name = "rbac_roles",
    primary_key = "id",
    uniques = {"name"},
    fks = {},
  }, {
    name = "files",
    primary_key = "id",
    uniques = {"path"},
    fks = {},
  }, {
    name = "developers",
    primary_key = "id",
    uniques = {"email", "custom_id"},
    fks = {{name = "consumer", reference = "consumers"}, {name = "rbac_user", reference = "rbac_users"}},
  }, {
    name = "document_objects",
    primary_key = "id",
    uniques = {"path"},
    fks = {{name = "service", reference = "services"}},
  }, {
    name = "applications",
    primary_key = "id",
    uniques = {},
    fks = {{name = "consumer", reference = "consumers"}, {name = "developer", reference = "developers"}},
  }, {
    name = "application_instances",
    primary_key = "id",
    uniques = {"composite_id"},
    fks = {{name = "application", reference = "applications"}, {name = "service", reference = "services"}},
  }, {
    name = "consumer_groups",
    primary_key = "id",
    uniques = {"name"},
    fks = {},
  }, {
    name = "consumer_group_plugins",
    primary_key = "id",
    uniques = {"name"},
    fks = {{name="consumer_group", reference = "consumer_groups", on_delete = "cascade"}},
  }
}


local ce_core_entities = {
  {
    name = "upstreams",
    primary_key = "id",
    uniques = {"name"},
    fks = {},
  }, {
    name = "targets",
    primary_key = "id",
    uniques = {},
    fks = {{name = "upstream", reference = "upstreams", on_delete = "cascade"}},
  }, {
    name = "consumers",
    primary_key = "id",
    uniques = {"username", "custom_id"},
    fks = {},
  }, {
    name = "certificates",
    primary_key = "id",
    uniques = {},
    fks = {},
  }, {
    name = "snis",
    primary_key = "id",
    -- do not convert "name" because it is unique_across_ws
    uniques = {},
    fks = {{name = "certificate", reference = "certificates"}},
  }, {
    name = "services",
    primary_key = "id",
    uniques = {"name"},
    fks = {{name = "client_certificate", reference = "certificates"}},
  }, {
    name = "routes",
    primary_key = "id",
    uniques = {"name"},
    fks = {{name = "service", reference = "services"}},
  }, {
    name = "plugins",
    primary_key = "id",
    uniques = {},
    fks = {{name = "route", reference = "routes", on_delete = "cascade"}, {name = "service", reference = "services", on_delete = "cascade"}, {name = "consumer", reference = "consumers", on_delete = "cascade"}},
  }
}


--------------------------------------------------------------------------------
-- High-level description of the migrations to execute on 'up'
-- @param ops table: table of functions which execute the low-level operations
-- for the database (each function returns a string).
-- @return SQL or CQL
local function ws_migration_up(ops)
  return ops:ws_adjust_fields(ee_core_entities)
end


--------------------------------------------------------------------------------
-- High-level description of the migrations to execute on 'teardown'
-- @param ops table: table of functions which execute the low-level operations
-- for the database (each function receives a connector).
-- @return a function that receives a connector
local function ws_migration_teardown(ops)
  return function(connector)
    ops:drop_run_on(connector)
    log.debug("run_on dropped")

    if ops:has_workspace_entities(connector)[1] then
      ops:ws_adjust_data(connector, ce_core_entities)
      log.debug("adjusted core data")
      ops:ws_adjust_data(connector, ee_core_entities)
      log.debug("adjusted EE data")
      ops:ws_clean_kong_admin_rbac_user(connector)
      log.debug("cleaned ADMIN RBAC data")
      ops:ws_set_default_ws_for_admin_entities(connector)
      log.debug("set default_ws_for_admin_entities")
    end
  end
end


--------------------------------------------------------------------------------


return {
  postgres = {
    up = [[
      DO $$
      BEGIN
        ALTER TABLE IF EXISTS ONLY "applications" ADD "custom_id" TEXT UNIQUE;
      EXCEPTION WHEN duplicate_column THEN
        -- Do nothing, accept existing state
      END;
      $$;
    ]] .. ws_migration_up(operations.postgres.up),

    teardown = ws_migration_teardown(operations.postgres.teardown),
  },

  cassandra = {
    up = [[
      ALTER TABLE applications ADD custom_id text;
      CREATE INDEX IF NOT EXISTS applications_custom_id_idx ON applications(custom_id);
    ]] .. ws_migration_up(operations.cassandra.up),

    teardown = ws_migration_teardown(operations.cassandra.teardown),
  }
}
