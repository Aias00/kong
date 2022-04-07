-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local ee_helpers = require "spec-ee.helpers"
local helpers    = require "spec.helpers"
local singletons  = require "kong.singletons"
local pl_path    = require "pl.path"
local pl_file    = require "pl.file"


local PORTAL_SESSION_CONF = "{ \"secret\": \"super-secret\", \"cookie_secure\": false }"


local function configure_portal(db, workspace_name)
  local workspace = db.workspaces:select_by_name(workspace_name)

  db.workspaces:update({
    id = workspace.id
  },
  {
    config = {
      portal = true,
    }
  })
end


local function create_portal_index()
  local prefix = singletons.configuration and singletons.configuration.prefix or 'servroot/'
  local portal_dir = 'portal'
  local portal_path = prefix .. portal_dir
  local views_path = portal_path .. '/views'
  local index_filename = views_path .. "/index.etlua"
  local index_str = "<% for key, value in pairs(configs) do %>  <meta name=\"KONG:<%= key %>\" content=\"<%= value %>\" /><% end %>"

  if not pl_path.exists(portal_path) then
    pl_path.mkdir(portal_path)
  end

  if not pl_path.exists(views_path) then
    pl_path.mkdir(views_path)
  end

  pl_file.write(index_filename, index_str)
end


local function close_clients(clients)
  for idx, client in ipairs(clients) do
    client:close()
  end
end


local function client_request(params)
  local client = assert(helpers.admin_client())
  local res = assert(client:send(params))
  res.body = res.body_reader()

  close_clients({ client })

  return res
end


local function gui_client_request(params)
  local portal_gui_client = assert(ee_helpers.portal_gui_client())
  local res = assert(portal_gui_client:send(params))
  res.body = res.body_reader()

  close_clients({ portal_gui_client })
  return res
end


local function create_workspace_files(workspace_name)

  client_request({
    method = "POST",
    path = "/" .. workspace_name .. "/files",
    body = {
      name = "unauthenticated/index",
      auth = false,
      type = "page",
      contents = [[
        <h1>index page</h1>
      ]],
    },
    headers = {["Content-Type"] = "application/json"},
  })

  client_request({
    method = "POST",
    path = "/" .. workspace_name .. "/files",
    body = {
      name = "unauthenticated/login",
      auth = false,
      type = "page",
      contents = [[
        <h1>login page<h2>
      ]]
    },
    headers = {["Content-Type"] = "application/json"},
  })

  client_request({
    method = "POST",
    path = "/" .. workspace_name .. "/files",
    body = {
      name = "unauthenticated/404",
      auth = false,
      type = "page",
      contents = [[
        <h1>404 page<h2>
      ]]
    },
    headers = {["Content-Type"] = "application/json"},
  })
end


for _, strategy in helpers.each_strategy() do

  describe("router #" .. strategy, function ()
    describe("portal_gui_use_subdomains = off", function()
      local db

      setup(function()
        _, db, _ = helpers.get_db_utils(strategy)
        assert(helpers.start_kong({
          database    = strategy,
          portal      = true,
          portal_is_legacy = true,
          portal_auth = "basic-auth",
          portal_auto_approve = true,
          portal_session_conf = PORTAL_SESSION_CONF,
        }))
        create_portal_index()

        configure_portal(db, "default")

        local res = client_request({
          method = "POST",
          path = "/workspaces",
          body = {
            name = "team_gruce",
            config = {
              portal_auth = "key-auth",
              portal = true,
            },
          },
          headers = {["Content-Type"] = "application/json"},
        })
        assert.equals(201, res.status)

        create_workspace_files("default")
      end)

      teardown(function()
        db:truncate()
        helpers.stop_kong()
      end)

      it("correctly identifies default workspace", function()
        local res = gui_client_request({
          method = "GET",
          path = "/",
        })

        assert.equals(res.status, 200)
        assert.not_nil(string.match(res.body, '<meta name="KONG:WORKSPACE" content="default" />'))

        res = gui_client_request({
          method = "GET",
          path = "/test",
        })
        assert.equals(res.status, 200)
        assert.not_nil(string.match(res.body, '<meta name="KONG:WORKSPACE" content="default" />'))

        res = gui_client_request({
          method = "GET",
          path = "/nested/test",
        })
        assert.equals(res.status, 200)
        assert.not_nil(string.match(res.body, '<meta name="KONG:WORKSPACE" content="default" />'))
      end)

      it("correctly identifies custom workspace", function()
        local res = gui_client_request({
          method = "GET",
          path = "/"
        })
        assert.equals(res.status, 200)
        assert.not_nil(string.match(res.body, '<meta name="KONG:WORKSPACE" content="default" />'))

        res = gui_client_request({
          method = "GET",
          path = "/team_gruce"
        })
        assert.equals(res.status, 200)
        assert.not_nil(string.match(res.body, '<meta name="KONG:WORKSPACE" content="team_gruce" />'))

        res = gui_client_request({
          method = "GET",
          path = "/team_gruce/endpoint"
        })
        assert.equals(res.status, 200)
        assert.not_nil(string.match(res.body, '<meta name="KONG:WORKSPACE" content="team_gruce" />'))

        res = gui_client_request({
          method = "GET",
          path = "/team_gruce/endpoint/another_endpoint"
        })
        assert.equals(res.status, 200)
        assert.not_nil(string.match(res.body, '<meta name="KONG:WORKSPACE" content="team_gruce" />'))

        res = gui_client_request({
          method = "GET",
          path = "/team_gruce/default"
        })
        assert.equals(res.status, 200)
        assert.not_nil(string.match(res.body, '<meta name="KONG:WORKSPACE" content="team_gruce" />'))
      end)

      it("correctly overrides default (conf.default) config when workspace config present", function()
        local res = gui_client_request({
          method = "GET",
          path = "/default"
        })
        assert.equals(res.status, 200)
        assert.not_nil(string.match(res.body, '<meta name="KONG:PORTAL_AUTH" content="basic%-auth" />'))

        res = gui_client_request({
          method = "GET",
          path = "/team_gruce"
        })
        assert.equals(res.status, 200)
        assert.not_nil(string.match(res.body, '<meta name="KONG:PORTAL_AUTH" content="key%-auth" />'))
      end)
    end)

    describe("portal_gui_use_subdomains = on", function()
      local db
      local portal_gui_host, portal_gui_protocol

      setup(function()
        _, db, _ = helpers.get_db_utils(strategy)
        portal_gui_host = 'cat.hotdog.com'
        portal_gui_protocol = 'http'

        assert(helpers.start_kong({
          database    = strategy,
          portal      = true,
          portal_auth = "basic-auth",
          portal_auto_approve = true,
          portal_is_legacy = true,
          portal_gui_use_subdomains = true,
          portal_session_conf = PORTAL_SESSION_CONF,
          portal_gui_host = portal_gui_host,
          portal_gui_protocol = portal_gui_protocol,
        }))

        create_portal_index()
        configure_portal(db, "default")

        local res = client_request({
          method = "POST",
          path = "/workspaces",
          body = {
            name = "team_gruce",
            config = {
              portal_auth = "key-auth",
              portal = true,
            },
          },
          headers = {["Content-Type"] = "application/json"},
        })
        assert.equals(201, res.status)

        create_workspace_files("default")
      end)

      teardown(function()
        db:truncate()
        helpers.stop_kong()
      end)

      it("correctly identifies default workspace", function()
        local res = gui_client_request({
          method = "GET",
          path = "/",
          headers = {
            ['Origin'] = portal_gui_protocol .. '://default.' .. portal_gui_host,
            ['Host'] = 'default.' .. portal_gui_host,
          },
        })
        assert.equals(200, res.status)
        assert.not_nil(string.match(res.body, '<meta name="KONG:WORKSPACE" content="default" />'))

        res = gui_client_request({
          method = "GET",
          path = "/hello",
          headers = {
            ['Origin'] = portal_gui_protocol .. '://default.' .. portal_gui_host,
            ['Host'] = 'default.' .. portal_gui_host,
          },
        })
        assert.equals(200, res.status)
        assert.not_nil(string.match(res.body, '<meta name="KONG:WORKSPACE" content="default" />'))
      end)

      it("correctly identifies custom workspace", function()
        local res = gui_client_request({
          method = "GET",
          path = "/",
          headers = {
            ['Origin'] = portal_gui_protocol .. '://team_gruce.' .. portal_gui_host,
            ['Host'] = 'team_gruce.' .. portal_gui_host,
          },
        })
        assert.equals(200, res.status)
        assert.not_nil(string.match(res.body, '<meta name="KONG:WORKSPACE" content="team_gruce" />'))

        res = gui_client_request({
          method = "GET",
          path = "/hotdog",
          headers = {
            ['Origin'] = portal_gui_protocol .. '://team_gruce.' .. portal_gui_host,
            ['Host'] = 'team_gruce.' .. portal_gui_host,
          },
        })
        assert.equals(200, res.status)
        assert.not_nil(string.match(res.body, '<meta name="KONG:WORKSPACE" content="team_gruce" />'))
      end)

      it("returns 500 if subdomain not included", function()
        local res = gui_client_request({
          method = "GET",
          path = "/",
          headers = {
            ['Origin'] = portal_gui_protocol .. '://' .. portal_gui_host,
            ['Host'] = portal_gui_host,
          },
        })
        assert.equals(500, res.status)
        assert.not_nil(string.match(res.body, '{"message":"An unexpected error occurred"}'))
      end)

      it("returns 500 if subdomain is not a recognized workspace", function()
        local res = gui_client_request({
          method = "GET",
          path = "/",
          headers = {
            ['Origin'] = portal_gui_protocol .. '://wrong_workspace.' .. portal_gui_host,
            ['Host'] = 'wrong_workspace.' .. portal_gui_host,
          },
        })
        assert.equals(500, res.status)
      end)

      it("returns 404 if subdomain does not match workspace", function()
        local res = gui_client_request({
          method = "GET",
          path = "/",
          headers = {
            ['Origin'] = portal_gui_protocol .. '://wrong_workspace,' .. portal_gui_host,
            ['Host'] = 'wrong_workspace,' .. portal_gui_host,
          },
        })
        assert.equals(404, res.status)
      end)

      it("returns 404 if workspace name is non-conformant", function()
        local res = gui_client_request({
          method = "GET",
          path = "/",
          headers = {
            ['Origin'] = portal_gui_protocol .. '://&&&,' .. portal_gui_host,
            ['Host'] = '&&&,' .. portal_gui_host,
          },
        })
        assert.equals(404, res.status)
      end)
    end)
  end)
end












































