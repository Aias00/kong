local helpers = require "spec.helpers"
local utils = require "kong.tools.utils"
local DB = require "kong.db"


for _, strategy in helpers.each_strategy() do

  local function init_db()
    local conf = utils.deep_copy(helpers.test_conf)
    conf.cassandra_timeout = 60000 -- default used in the `migrations` cmd as well
    local db = assert(DB.new(conf, strategy))
    assert(db:init_connector())
    assert(db:connect())
    finally(function()
      db.connector:close()
    end)
    assert(db.plugins:load_plugin_schemas(helpers.test_conf.loaded_plugins))
    return db
  end

  describe("default workspace after migrations [#" .. strategy .. "]", function()
    it("is contains the correct defaults", function()
      local db = init_db()

      assert(db:schema_reset())
      helpers.bootstrap_database(db)

      local workspaces = {}
      for ws in db.workspaces:each(nil, { nulls = false }) do
        table.insert(workspaces, ws)
      end
      local default_ws = workspaces[1]
      assert.equal(1, #workspaces)
      assert.equal("default", default_ws.name)
      assert.same({
        color = ngx.null,
        thumbnail = ngx.null,
      }, default_ws.meta)
      assert.is_not_nil(default_ws.created_at)
      assert.equal(false , default_ws.config.portal)
    end)
  end)
end
