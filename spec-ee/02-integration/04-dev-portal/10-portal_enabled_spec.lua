-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local helpers      = require "spec.helpers"
local enums       = require "kong.enterprise_edition.dao.enums"
local clear_license_env = require("spec-ee.helpers").clear_license_env
local get_portal_and_vitals_key = require("spec-ee.helpers").get_portal_and_vitals_key

local tostring = tostring

local function configure_portal(db, ws_on)
  db.workspaces:upsert_by_name("default", {
    name = "default",
    config = {
      portal = ws_on,
      portal_auth = "basic-auth"
    },
  })
end

local function get_expected_status(success, conf_on, ws_on)
  if not conf_on or not ws_on then
    return 404
  end

  return success
end


local function close_clients(clients)
  for idx, client in ipairs(clients) do
    client:close()
  end
end


local function client_request(params)
  local client = assert(helpers.admin_client())
  local res = assert(client:send(params))
  res.body = res:read_body()

  close_clients({ client })
  return res
end


local configs = {
  {true, false}, -- portal on in conf, off in ws
  {false, true}, -- portal off in conf, on in ws
  {false, false}, -- portal off in both
  {true, true} -- portal on in both
}


for _, strategy in helpers.each_strategy() do
  for _, conf in ipairs(configs) do
    local conf_on = conf[1]
    local ws_on = conf[2]

    describe("Portal Enabled [#" .. strategy .. "] conf = " .. tostring(conf_on) .. " ws = " .. tostring(ws_on), function()
      local _, db, _ = helpers.get_db_utils(strategy)

      local developer, file
      local reset_license_data

      lazy_setup(function()
        reset_license_data = clear_license_env()

        assert(helpers.start_kong({
          database = strategy,
          license_path = "spec-ee/fixtures/mock_license.json",
          portal = conf_on,
          portal_and_vitals_key = get_portal_and_vitals_key(),
          portal_is_legacy = true,
          portal_auth = "basic-auth",
          portal_session_conf = "{ \"secret\": \"super-secret\", \"cookie_secure\": false }",
        }))

        configure_portal(db, ws_on)
        developer = assert(db.developers:insert {
          email = "gruce@konghq.com",
          password = "kong",
          meta = "{\"full_name\":\"I Like Turtles\"}",
          status = enums.CONSUMERS.STATUS.APPROVED,
        })

        file = assert(db.legacy_files:insert {
          name = "file",
          contents = "cool",
          type = "page"
        })


      end)

      lazy_teardown(function()
        helpers.stop_kong()
        assert(db:truncate())
        reset_license_data()
      end)

      describe("Developers Admin API respects portal enabled configs", function()
        it("/developers", function()
          local res = assert(client_request {
            method = "GET",
            path = "/default/developers"
          })

          local expected_status = get_expected_status(200, conf_on, ws_on)
          assert.res_status(expected_status, res)

          local res = assert(client_request({
            method = "POST",
            path = "/default/developers",
            body = {
              email = "friend@konghq.com",
              password = "wow",
              meta = "{\"full_name\":\"WOW\"}",
            },
            headers = {["Content-Type"] = "application/json"},
          }))

          local expected_status = get_expected_status(200, conf_on, ws_on)
          assert.res_status(expected_status, res)
        end)

        it("/developers/:developers ", function()
          local res = assert(client_request {
            method = "GET",
            path = "/default/developers/" .. developer.id,
          })

          local expected_status = get_expected_status(200, conf_on, ws_on)
          assert.res_status(expected_status, res)
        end)
      end)

      describe("Files Admin API", function()
        it("/files", function()
          local res = assert(client_request {
            method = "GET",
            path = "/default/files"
          })

          local expected_status = get_expected_status(200, conf_on, ws_on)
          assert.res_status(expected_status, res)

          local res = assert(client_request({
            method = "POST",
            path = "/default/files",
            body = {
              name = "fileeeeee",
              contents = "rad",
              type = "page"
            },
            headers = {["Content-Type"] = "application/json"},
          }))

          local expected_status = get_expected_status(201, conf_on, ws_on)
          assert.res_status(expected_status, res)
        end)

        it("/files/:files", function()
          local res = assert(client_request {
            method = "GET",
            path = "/default/files/" .. file.id,
          })

          local expected_status = get_expected_status(200, conf_on, ws_on)
          assert.res_status(expected_status, res)

          local res = assert(client_request({
            method = "PATCH",
            path = "/default/files/" .. file.id,
            body = {
              name = "new_name",
              contents = "new content",
              type = "page"
            },
            headers = {["Content-Type"] = "application/json"},
          }))

          local expected_status = get_expected_status(200, conf_on, ws_on)
          assert.res_status(expected_status, res)
        end)
      end)
    end)

    describe("With SSL config", function()
      local _, db, _ = helpers.get_db_utils(strategy)
      local reset_license_data

      lazy_setup(function()
        reset_license_data = clear_license_env()

        assert(helpers.start_kong({
          database = strategy,
          license_path = "spec-ee/fixtures/mock_license.json",
          portal = conf_on,
          portal_and_vitals_key = get_portal_and_vitals_key(),
          ssl_cipher_suite = "modern"
        }))

        configure_portal(db, ws_on)
      end)

      lazy_teardown(function()
        helpers.stop_kong()
        assert(db:truncate())
        reset_license_data()
      end)

      it("load config properly when ssl_cipher_suite is set to modern", function()
        local res = assert(client_request {
          method = "GET",
          path = "/default/developers"
        })

        local expected_status = get_expected_status(200, conf_on, ws_on)
        assert.res_status(expected_status, res)
      end)
    end)
  end
end
