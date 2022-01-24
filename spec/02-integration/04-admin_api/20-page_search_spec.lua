-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local helpers = require "spec.helpers"
local cjson = require "cjson"
local fmt = string.format

for _, strategy in helpers.each_strategy({"postgres"}) do

local strategy = "postgres"

describe("Admin API - search", function()

  describe("/entities search with DB: #" .. strategy, function()
    local client, bp, db

    local test_entity_count = 100

    lazy_setup(function()
      bp, db = helpers.get_db_utils(strategy, {
        "routes",
        "services",
      })

      for i = 1, test_entity_count do
        local route = {
          name = fmt("route%s", i),
          hosts = { fmt("example-%s.com", i) },
          paths = { fmt("/%s", i) },
        }
        local _, err, err_t = bp.routes:insert(route)
        assert.is_nil(err)
        assert.is_nil(err_t)

        local service = {
          name = fmt("service%s", i),
          enabled = true,
          protocol = "http",
          host = fmt("example-%s.com", i),
          path = fmt("/%s", i),
        }
        local _, err, err_t = bp.services:insert(service)
        assert.is_nil(err)
        assert.is_nil(err_t)
      end

      assert(helpers.start_kong {
        database = strategy,
      })
      client = assert(helpers.admin_client(10000))
    end)

    lazy_teardown(function()
      if client then client:close() end
      helpers.stop_kong()
    end)

    it("known field only", function()
      local err
      _, err = db.services:page(nil, nil, { search_fields = { wat = "wat" } })
      assert.same(err, "[postgres] invalid option (search_fields: cannot search on unindexed field 'wat')")
      _, err = db.services:page(nil, nil, { search_fields = { ["name;drop/**/table/**/services;/**/--/**/-"] = "1" } })
      assert.same(err, "[postgres] invalid option (search_fields: cannot search on unindexed field 'name;drop/**/table/**/services;/**/--/**/-')")
    end)

    it("common field", function()
      local res
      res = assert(client:send {
        method = "GET",
        path = "/services?name=100"
      })
      local body = assert.res_status(200, res)
      local json = cjson.decode(body)
      assert.same('service100', json.data[1].name)

      res = assert(client:send {
        method = "GET",
        path = "/routes?name=100"
      })
      local body = assert.res_status(200, res)
      local json = cjson.decode(body)
      assert.same('route100', json.data[1].name)

      res = assert(client:send {
        method = "GET",
        path = "/routes?hosts=100"
      })
      local body = assert.res_status(200, res)
      local json = cjson.decode(body)
      assert.same('route100', json.data[1].name)

      res = assert(client:send {
        method = "GET",
        path = "/services?size=100&enabled=true"
      })
      local body = assert.res_status(200, res)
      local json = cjson.decode(body)
      assert.same(100, #json.data)
    end)

    it("array field", function()
      local res
      res = assert(client:send {
        method = "GET",
        path = "/routes?protocols=http"
      })
      local body = assert.res_status(200, res)
      local json = cjson.decode(body)
      assert.same(100, #json.data)

      res = assert(client:send {
        method = "GET",
        path = "/routes?protocols=https"
      })
      local body = assert.res_status(200, res)
      local json = cjson.decode(body)
      assert.same(100, #json.data)

      res = assert(client:send {
        method = "GET",
        path = "/routes?protocols=http,https"
      })
      local body = assert.res_status(200, res)
      local json = cjson.decode(body)
      assert.same(100, #json.data)

      res = assert(client:send {
        method = "GET",
        path = "/routes?protocols=http,https,grpc"
      })
      local body = assert.res_status(200, res)
      local json = cjson.decode(body)
      assert.same(0, #json.data)
    end)

    it("fuzzy field", function()
      local res
      res = assert(client:send {
        method = "GET",
        path = "/routes?hosts=100"
      })
      local body = assert.res_status(200, res)
      local json = cjson.decode(body)
      assert.same("route100", json.data[1].name)
    end)
  end)

end)

end -- for _, strategy in helpers.each_strategy({"postgres"}) do
