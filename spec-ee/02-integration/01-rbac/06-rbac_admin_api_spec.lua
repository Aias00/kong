-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local helpers    = require "spec.helpers"
local cjson      = require "cjson"
local ee_helpers   = require "spec-ee.helpers"
local kong_vitals = require "kong.vitals"

for _, strategy in helpers.each_strategy() do
  describe("Admin API - RBAC #" .. strategy, function()
    local ADMIN_TOKEN = "i-am-the-admin-token"
    local admin
    local db

    local function admin_request(method, path, body, excpected_status)
      local res = assert(admin:send {
        method = method,
        path = path,
        headers = {
          ["Content-Type"] = "application/json",
          ["Kong-Admin-Token"] = ADMIN_TOKEN,
        },
        body = body
      })
      local json = cjson.decode(assert.res_status(excpected_status or 200, res))
      return json, json.host
    end

    lazy_setup(function()
      _, db = helpers.get_db_utils(strategy)

      if _G.kong then
        _G.kong.cache = helpers.get_cache(db)
        _G.kong.vitals = kong_vitals.new({
          db = db,
          ttl_seconds = 3600,
          ttl_minutes = 24 * 60,
          ttl_days = 30,
        })
      else
        _G.kong = {
          cache = helpers.get_cache(db),
          vitals = kong_vitals.new({
            db = db,
            ttl_seconds = 3600,
            ttl_minutes = 24 * 60,
            ttl_days = 30,
          })
        }
      end

      assert(helpers.start_kong({
        database  = strategy,
        enforce_rbac = "on",
      }))

      ee_helpers.register_rbac_resources(db)

      local admin = db.rbac_users:insert({
        name = "admin",
        user_token = ADMIN_TOKEN,
      })

      local superadmin = db.rbac_roles:select_by_name("superadmin")
      superadmin = superadmin or db.rbac_roles:select_by_name("super-admin")
      db.rbac_user_roles:insert({
        user = admin,
        role = superadmin,
      })
    end)

    lazy_teardown(function()
      helpers.stop_kong()
    end)

    before_each(function()
      admin = assert(helpers.admin_client())
    end)

    after_each(function()
      if admin then admin:close() end
    end)

    it("upsert is inserted and updated using PUT", function()
      local _, host = admin_request("PUT",
                                    "/services/upsert-route",
                                    { host = "upsert-host" })
      assert.same("upsert-host", host)

      _, host = admin_request("PUT",
                              "/services/upsert-route",
                              { host = "updated-host-after-upsert" })
      assert.same("updated-host-after-upsert", host)
    end)

    it("update is updated after adding using PUT", function()
      local _, host = admin_request("POST",
                                    "/services",
                                    {
                                      name = "added-route",
                                      host = "upsert-host"
                                    }, 201)
      assert.same("upsert-host", host)

      _, host = admin_request("PUT",
                              "/services/added-route",
                              {
                                host = "updated-host-after-added"
                              })
      assert.same("updated-host-after-added", host)
    end)
  end)
end
