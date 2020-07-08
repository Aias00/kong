local helpers    = require "spec.helpers"
local cjson      = require "cjson"
local enums      = require "kong.enterprise_edition.dao.enums"
local utils      = require "kong.tools.utils"
local ee_jwt     = require "kong.enterprise_edition.jwt"
local ee_helpers = require "spec-ee.helpers"
local scope = require "kong.enterprise_edition.workspaces.scope"
local admins_helpers = require "kong.enterprise_edition.admins_helpers"
local secrets = require "kong.enterprise_edition.consumer_reset_secret_helpers"
local ee_utils = require "kong.enterprise_edition.utils"
local escape = require("socket.url").escape

local post = ee_helpers.post
local get_admin_cookie = ee_helpers.get_admin_cookie_basic_auth


for _, strategy in helpers.each_strategy() do
  describe("Admin API - Admins #" .. strategy, function()

    local function init_db()
      local conf = utils.deep_copy(helpers.test_conf)
      conf.cassandra_timeout = 60000 -- default used in the `migrations` cmd as well

      local db = assert(kong.db.new(conf, strategy))
      assert(db:init_connector())
      assert(db:connect())
      finally(function()
        db.connector:close()
      end)
      assert(db.plugins:load_plugin_schemas(helpers.test_conf.loaded_plugins))
      db:truncate()
      return db
    end

    lazy_teardown(function()
      helpers.stop_kong()

      helpers.unsetenv("KONG_PASSWORD")
      assert.equal(nil, os.getenv("KONG_PASSWORD"))
    end)

    it("regression test for role filtering (EBB-336)", function()
      local db = init_db()

      helpers.setenv("KONG_PASSWORD", "handyshake")
      assert.equal("handyshake", os.getenv("KONG_PASSWORD"))

      assert(db:schema_reset())

      helpers.bootstrap_database(db)

      assert(helpers.start_kong({
        database = strategy,
        admin_gui_auth="basic-auth",
        enforce_rbac="on",
        admin_gui_session_conf=[[{"cookie_name":"kong_manager","storage":"kong","secret":"ohyea!","cookie_secure":false,"cookie_lifetime":86400,"cookie_renew":86400}]],
        portal_is_legacy="false",
        --admin_gui_url = "http://manager.konghq.com",
      }))

      local headers = {
        ["Kong-Admin-Token"] = "handyshake",
        ["Content-Type"]     = "application/json",
      }

      local client = assert(helpers.admin_client())
      finally(function()
        client:close()
      end)

      local res = assert(client:send {
        method = "POST",
        path  = "/workspaces",
        headers = headers,
        body  = {
          name = "ws1",
        },
      })
      assert.res_status(201, res)

      client = assert(helpers.admin_client())
      finally(function()
        client:close()
      end)

      res = assert(client:send {
        method = "POST",
        path  = "/ws1/rbac/roles",
        headers = headers,
        body  = {
          name = "ws1-read-only",
        },
      })
      assert.res_status(201, res)

      client = assert(helpers.admin_client())
      finally(function()
        client:close()
      end)

      res = assert(client:send {
        method = "POST",
        path  = "/ws1/rbac/roles/ws1-read-only/endpoints",
        headers = headers,
        body  = {
          workspace = "ws1",
          endpoint = "*",
          actions = "read",
        },
      })
      assert.res_status(201, res)

      client = assert(helpers.admin_client())
      finally(function()
        client:close()
      end)

      res = assert(client:send {
        method = "POST",
        path  = "/ws1/admins/kong_admin/roles",
        headers = headers,
        body  = {
          roles = "ws1-read-only",
        },
      })
      assert.res_status(201, res)

      client = assert(helpers.admin_client())
      finally(function()
        client:close()
      end)

      res = assert(client:send {
        method = "GET",
        path  = "/ws1/admins/kong_admin/roles",
        headers = headers,
      })
      res = assert.res_status(200, res)

      local json = cjson.decode(res)
      assert.same(1, #json.roles)
      assert.same("ws1-read-only", json.roles[1].name)
    end)
  end)

  describe("Admin API - Admins #" .. strategy, function()
    local client
    local db
    local bp
    local admin
    local another_ws
    local admins = {}

    local function setup(config)
      bp, db = helpers.get_db_utils(strategy, {
        "consumers",
        "rbac_users",
        "rbac_roles",
        "rbac_user_roles",
        "admins",
      })
      assert(helpers.start_kong(config))

      another_ws = assert(db.workspaces:insert({
        name = "another-one",
      }))

      ee_helpers.register_rbac_resources(db)

      scope.run_with_ws_scope({ another_ws }, function()
        ee_helpers.register_rbac_resources(db, "another-one")
      end)

      for i = 1, 3 do
        -- admins that are already approved
        admins[i] = assert(db.admins:insert {
          username = "admin-" .. i .. "@test.com",
          custom_id = "admin-" .. i,
          email = "admin-" .. i .. "@test.com",
          status = enums.CONSUMERS.STATUS.APPROVED,
        })
      end
      admins[4] = assert(db.admins:insert {
        username = "admin-4@test.com",
        custom_id = "admin-4",
        email = "admin-4@test.com",
        status = enums.CONSUMERS.STATUS.INVITED,
      })
      -- developers don't show up as admins
      assert(bp.consumers:insert {
        username = "developer-1",
        custom_id = "developer-1",
        type = enums.CONSUMERS.TYPE.DEVELOPER,
      })

      -- proxy users don't show up as admins
      assert(bp.consumers:insert {
        username = "consumer-1",
        custom_id = "consumer-1",
        type = enums.CONSUMERS.TYPE.PROXY,
      })

      admin = admins[1]
    end

    lazy_setup(function()
      setup({
        database = strategy,
        admin_gui_url = "http://manager.konghq.com",
        admin_gui_auth = "basic-auth",
        admin_gui_session_conf = "{ \"secret\": \"super-secret\" }",
        enforce_rbac = "on",
      })

    end)

    lazy_teardown(function()
      helpers.stop_kong()
    end)

    before_each(function()
      client = assert(helpers.admin_client())
    end)

    after_each(function()
      if client then client:close() end
      db:truncate("basicauth_credentials")
    end)

    describe("/kconfig.js", function()
      local gui_client

      before_each(function()
        gui_client = assert(ee_helpers.admin_gui_client())
      end)

      after_each(function()
        if gui_client then gui_client:close() end
      end)

      it("GET", function()
        local res = assert(gui_client:send {
          method = "GET",
          path = "/kconfig.js",
          headers = {
            ["Kong-Admin-Token"] = "letmein-default",
          },
        })

        assert.res_status(200, res)
      end)
    end)

    describe("/admins", function()
      describe("GET", function ()
        it("retrieves list of admins only", function()
          local res = assert(client:send {
            method = "GET",
            path = "/admins?type=2",
            headers = {
              ["Kong-Admin-Token"] = "letmein-default",
            },
          })

          res = assert.res_status(200, res)
          local json = cjson.decode(res)
          assert.equal(4, #json.data)
          assert(utils.is_array(json.data))
          assert.same(ngx.null, json.next)
        end)

      end)

      describe("POST", function ()
        it("creates an admin", function()
          local res = assert(client:send {
            method = "POST",
            path  = "/admins",
            headers = {
              ["Kong-Admin-Token"] = "letmein-default",
              ["Content-Type"]     = "application/json",
            },
            body  = {
              custom_id = "cooper",
              username  = "dale",
              email = "Twinpeaks@KongHQ.com",
              status = enums.CONSUMERS.STATUS.INVITED,
            },
          })
          res = assert.res_status(200, res)
          local json = cjson.decode(res)

          assert.equal("dale", json.admin.username)
          assert.equal("cooper", json.admin.custom_id)
          assert.equal("twinpeaks@konghq.com", json.admin.email)
          assert.equal(enums.CONSUMERS.STATUS.INVITED, json.admin.status)
          assert.is_true(json.admin.rbac_token_enabled)
          assert.is_nil(json.message)
        end)

        it("creates an admin - rbac_token disabled", function()
          local res = assert(client:send {
            method = "POST",
            path = "/admins",
            headers = {
              ["Kong-Admin-Token"] = "letmein-default",
              ["Content-Type"]     = "application/json",
            },
            body = {
              username = utils.uuid(),
              rbac_token_enabled = false,
            },
          })
          res = assert.res_status(200, res)
          local json = cjson.decode(res)

          assert.is_false(json.admin.rbac_token_enabled)
        end)

        it("creates an admin when email fails", function()
          helpers.stop_kong()
          setup({
            database = strategy,
            admin_gui_url = "http://manager.konghq.com",
            admin_gui_auth = "basic-auth",
            admin_gui_session_conf = "{ \"secret\": \"super-secret\" }",
            enforce_rbac = "on",
            smtp_mock = false,
          })

          client = assert(helpers.admin_client())

          local res = assert(client:send {
            method = "POST",
            path  = "/admins",
            headers = {
              ["Kong-Admin-Token"] = "letmein-default",
              ["Content-Type"]     = "application/json",
            },
            body  = {
              custom_id = "lynch",
              username  = "david",
              email = "d.lynch@konghq.com",
              status = enums.CONSUMERS.STATUS.INVITED,
            },
          })
          res = assert.res_status(200, res)
          local json = cjson.decode(res)

          assert.equal("User created, but failed to send invitation email", json.message)
        end)
      end)
    end)

    describe("/admins/:admin_id", function()
      describe("GET", function()
        it("retrieves by id", function()
          local res = assert(client:send {
            method = "GET",
            path = "/admins/" .. admins[1].id,
            headers = {
              ["Kong-Admin-Token"] = "letmein-default",
              ["Content-Type"]     = "application/json",
            },
          })

          local body = assert.res_status(200, res)
          local json = cjson.decode(body)

          assert.same(admins[1].id, json.id)
          assert.same(admins[1].username, json.username)
          assert.same(admins[1].email, json.email)
          assert.same(admins[1].status, json.status)
          assert.is_not_nil(json.rbac_token_enabled)
          assert.same(admins[1].rbac_token_enabled, json.rbac_token_enabled)

          -- validate the admin is API-friendly
          assert.is_nil(json.consumer)
          assert.is_nil(json.rbac_user)
        end)

        it("retrieves by username", function()
          local res = assert(client:send {
            method = "GET",
            path = "/admins/" .. escape("admin-2@test.com"),
            headers = {
              ["Kong-Admin-Token"] = "letmein-default",
              ["Content-Type"]     = "application/json",
            },
          })
          local body = assert.res_status(200, res)
          local json = cjson.decode(body)
          assert.same(admins[2].id, json.id)
        end)

        it("includes token for invited user", function()
          local res = assert(client:send {
            method = "GET",
            path = "/admins/" .. admins[4].id .. "?generate_register_url=true",
            headers = {
              ["Kong-Admin-Token"] = "letmein-default",
              ["Content-Type"]     = "application/json",
            },
          })
          local body = assert.res_status(200, res)
          local json = cjson.decode(body)
          assert.same(admins[4].id, json.id)
          assert.not_nil(json.token)
          assert.not_nil(json.register_url)

          -- validate the admin is API-friendly
          assert.is_nil(json.consumer)
          assert.is_nil(json.rbac_user)

          local jwt, err = ee_utils.validate_reset_jwt(json.token)
          assert.is_nil(err)

          -- validate the JWT
          for secret, err in db.consumer_reset_secrets:each_for_consumer({ id = jwt.claims.id }) do
            assert.is_nil(err)
            assert.same(enums.TOKENS.STATUS.PENDING, secret.status)
            assert.truthy(ee_jwt.verify_signature(jwt, secret.secret))
          end

          -- validate the registration URL
          local url = ngx.unescape_uri(json.register_url)

          assert.truthy(string.match(url:gsub("%-", ""), admins[4].username:gsub("%-", "")))
          assert.truthy(string.match(url:gsub("%-", ""), admins[4].email:gsub("%-", "")))
          assert.truthy(string.match(url:gsub("%-", ""), json.token:gsub("%-", "")))
        end)

        it("returns 404 if not found", function()
          local res = assert(client:send {
            method = "GET",
            path = "/admins/not-an-admin",
            headers = {
              ["Kong-Admin-Token"] = "letmein-default",
              ["Content-Type"]     = "application/json",
            },
          })
          assert.res_status(404, res)
        end)
      end)

      describe("PATCH", function()
        it("updates by id", function()
          return function()
            local res = assert(client:send {
              method = "PATCH",
              path = "/admins/" .. admin.id,
              body = {
                username = "alice",
                email = "ALICE@kongHQ.com",
                rbac_token_enabled = false,
              },
              headers = {
                ["Kong-Admin-Token"] = "letmein-default",
                ["Content-Type"]     = "application/json",
              },
            })

            local json = cjson.decode(assert.res_status(200, res))
            assert.equal("alice", json.username)
            assert.equal("alice@konghq.com", json.email)
            assert.is_false(json.rbac_token_enabled)
            assert.equal(admin.id, json.id)
          end
        end)

        it("updates by username", function()
          local new_name = admin.username .. utils.uuid()
          local res = assert(client:send {
            method = "PATCH",
            path = "/admins/" .. admin.username,
            body = {
              username = new_name
            },
            headers = {
              ["Kong-Admin-Token"] = "letmein-default",
              ["Content-Type"]     = "application/json",
            },
          })
          local body = assert.res_status(200, res)
          local json = cjson.decode(body)
          assert.equal(new_name, json.username)
          assert.equal(admin.id, json.id)

          -- name has changed: keep in sync with db
          admin.username = new_name
        end)

        it("fails gracefully on bad types", function()
          local res = assert(client:send {
            method = "PATCH",
            path = "/admins/" .. admin.id,
            body = {
              username = "alice",
              email = "ALICE@kongHQ.com",
              rbac_token_enabled = "false",
            },
            headers = {
              ["Kong-Admin-Token"] = "letmein-default",
              ["Content-Type"]     = "application/json",
            },
          })

          local json = cjson.decode(assert.res_status(400, res))
          local expected = {
            message = "schema violation (rbac_token_enabled: expected a boolean)"
          }
          assert.same(expected, json)
        end)

        it("returns 404 if not found", function()
          return function()
            local res = assert(client:send {
              method = "PATCH",
              path = "/admins/not-an-admin",
              body = {
               username = "alice"
              },
              headers = {
                ["Kong-Admin-Token"] = "letmein-default",
                ["Content-Type"]     = "application/json",
              },
            })
            assert.res_status(404, res)
          end
        end)
      end)

      describe("DELETE", function()
        it("deletes by id", function()
          local admin = assert(db.admins:insert({
            username = "deleteme" .. utils.uuid(),
            email = "deleteme@konghq.com",
            status = enums.CONSUMERS.STATUS.INVITED,
          }))

          local res = assert(client:send {
            method = "DELETE",
            path   = "/admins/" .. admin.id,
            headers = {
              ["Kong-Admin-Token"] = "letmein-default",
              ["Content-Type"]     = "application/json",
            },
          })
          local body = assert.res_status(204, res)
          assert.equal("", body)
        end)

        it("deletes by username", function()
          local admin = assert(db.admins:insert({
            username = "gruce-delete-me",
            email = "deleteme@konghq.com",
            status = enums.CONSUMERS.STATUS.INVITED,
          }))

          local res = assert(client:send {
            method = "DELETE",
            path   = "/admins/" .. admin.username,
            headers = {
              ["Kong-Admin-Token"] = "letmein-default",
              ["Content-Type"]     = "application/json",
            },
          })
          local body = assert.res_status(204, res)
          assert.equal("", body)
        end)

        it("returns 404 if not found", function()
          local res = assert(client:send {
            method = "DELETE",
            path   = "/admins/not-an-admin",
            headers = {
              ["Kong-Admin-Token"] = "letmein-default",
              ["Content-Type"]     = "application/json",
            },
          })
          assert.res_status(404, res)
        end)
      end)

      describe("/admins/:admin/workspaces", function()
        describe("GET", function()
          local headers = {
            ["Kong-Admin-Token"] = "letmein-default",
            ["Content-Type"]     = "application/json",
          }

          it("retrieves workspaces for an admin by id", function()
            assert.res_status(201, assert(client:send {
              method = "POST",
              path = "/another-one/admins/" .. admins[2].id .. "/roles",
              headers = headers,
              body = {
                roles = "read-only"
              }
            }))

            local res = client:send {
              method = "GET",
              path = "/another-one/admins/" .. admins[2].username .. "/workspaces",
              headers = headers,
            }

            local body = assert.res_status(200, res)
            local json = cjson.decode(body)

            assert.equal(2, #json)
            local names = { json[1].name, json[2].name }
            assert.contains("default", names)
            assert.contains(another_ws.name, names)
          end)

          it("retrieves workspaces for an admin by name", function()
            local res = assert(client:send {
              method = "GET",
              path = "/admins/" .. admins[1].username .. "/workspaces",
              headers = headers,
            })

            local body = assert.res_status(200, res)
            local json = cjson.decode(body)
            assert.equal(1, #json)
          end)

          it("retrieves workspaces for an admin outside default", function()
            local lesser_admin
            scope.run_with_ws_scope({another_ws}, function ()
              lesser_admin = ee_helpers.create_admin('outside_default@gmail.com',
                                                     nil, 0, bp, db)
            end)

            local res = assert(client:send {
              method = "GET",
              path = "/".. another_ws.name .. "/admins/" .. lesser_admin.username .. "/workspaces",
              headers = headers,
            })

            local body = assert.res_status(200, res)
            local json = cjson.decode(body)
            assert.equal(1, #json)
            assert.equal(another_ws.name, json[1].name)
          end)

          it("retrieves workspaces for an admin in multiple workspaces", function()
            local lesser_admin

            scope.run_with_ws_scope({another_ws}, function ()
              lesser_admin = ee_helpers.create_admin('outside_default2@gmail.com',
                                                     nil, 0, bp, db)
            end)

            post(client, "/admins/outside_default2@gmail.com/roles", {
              roles = "read-only"
            }, headers, 201)

            local res = assert(client:send {
              method = "GET",
              path = "/".. another_ws.name .. "/admins/" .. lesser_admin.username .. "/workspaces",
              headers = headers,
            })

            local body = assert.res_status(200, res)
            local json = cjson.decode(body)

            assert.equal(2, #json)
            assert.equal('*', json[1].name)
            assert.equal(another_ws.name, json[2].name)
          end)

          it("retrieves asterisk workspace for an admin with asterisk role", function()
            scope.run_with_ws_scope({kong.default_workspace}, function ()
              return ee_helpers.create_admin('the_admin@test.com', nil, 0, bp, db)
            end)

            post(client, "/admins/the_admin@test.com/roles", {
              roles = "read-only" -- has endpoint.workspace = '*'
            }, headers, 201)

            local res = assert(client:send {
              method = "GET",
              path = "/admins/the_admin@test.com/workspaces",
              headers = headers,
            })

            local body = assert.res_status(200, res)
            local json = cjson.decode(body)

            assert.equal(2, #json)
            assert.equal('*', json[1].name)
            assert.equal('default', json[2].name)
          end)

          it("returns 404 if admin not found", function()
            local res = assert(client:send {
              method = "GET",
              path = "/admins/" .. admin.rbac_user.id .. "/workspaces",
              headers = headers,
            })
            assert.res_status(404, res)
          end)

          it("returns 404 if admin is not in workspace", function()
            local res = assert(client:send {
              method = "GET",
              path = "/another-one/admins/" .. admins[1].id .. "/workspaces",
              headers = headers,
            })
            assert.res_status(404, res)
          end)
        end)
      end)
    end)
  end)

  describe("Admin API - Admins Register #" .. strategy, function()
    local client
    local db

    describe("/admins/register basic-auth", function()
      before_each(function()
        _, db = helpers.get_db_utils(strategy)
        assert(helpers.start_kong({
          database = strategy,
          admin_gui_url = "http://manager.konghq.com",
          admin_gui_auth = 'basic-auth',
          admin_gui_session_conf = "{ \"secret\": \"super-secret\" }",
          admin_gui_auth_password_complexity = "{\"kong-preset\": \"min_12\"}",
          enforce_rbac = "on",
        }))
        ee_helpers.register_rbac_resources(db)
        client = assert(helpers.admin_client())
      end)

      after_each(function()
        if client then client:close() end
        assert(helpers.stop_kong())
      end)

      describe("/admins/register", function()
        it("denies invalid emails", function()
          local res = assert(client:send {
            method = "POST",
            path = "/admins/register",
            headers = {
              ["Content-Type"] = "application/json",
            },
            body  = {
              username  = "dale",
              email = "not-valid.com",
              password = "new2!pas$Word",
            },
          })

          local body = assert.res_status(400, res)
          local json = cjson.decode(body)
          assert.truthy(string.match(json.message, "Invalid email"))
        end)

        it("denies invalid password", function()
          -- expect returns password required
          local json_no_pass = assert.res_status(400, assert(client:send {
            method = "POST",
            path = "/admins/register",
            headers = {
              ["Content-Type"] = "application/json",
            },
            body = {
              username  = "bob",
              email = "hong@konghq.com",
            },
          }))
          local res_no_pass = cjson.decode(json_no_pass)
          assert.same(res_no_pass.message, "password is required")

          -- expect returns too short
          local json_short_pass = assert.res_status(400, assert(client:send {
            method = "POST",
            path = "/admins/register",
            headers = {
              ["Content-Type"] = "application/json",
            },
            body = {
              username  = "bob",
              email = "hong@konghq.com",
              password = "pass"
            },
          }))
          local res_short_pass = cjson.decode(json_short_pass)
          assert.same(res_short_pass.message, "Invalid password: too short")
        end)

        it("successfully registers an invited admin", function()
          local res = assert(admins_helpers.create({
            username = "bob",
            email = "hong@konghq.com",
          }, {
            db = db,
            token_optional = false,
            token_expiry = 3600,
            remote_addr = "127.0.0.1",
            raw = true,
          }))

          local admin = res.body.admin

          local reset_secret
          for row, err in db.consumer_reset_secrets:each_for_consumer({id = admin.consumer.id }) do
            assert.is_nil(err)
            reset_secret = row
          end
          assert.equal(enums.TOKENS.STATUS.PENDING, reset_secret.status)

          local claims = {id = admin.consumer.id, exp = ngx.time() + 100000}
          local valid_jwt = ee_jwt.generate_JWT(claims, reset_secret.secret,
                                                "HS256")

          local res = assert(client:send {
            method = "POST",
            path = "/admins/register",
            headers = {
              ["Content-Type"] = "application/json"
            },
            body  = {
              username = "bob",
              email = "hong@konghq.com",
              token = valid_jwt,
              password = "new2!pas$Word",
            },
          })

          assert.res_status(201, res)

          reset_secret = db.consumer_reset_secrets:select({ id = reset_secret.id })

          assert.equal(enums.TOKENS.STATUS.CONSUMED, reset_secret.status)
        end)
      end)
    end)

    describe("/admins/register ldap-auth-advanced #ldap", function()
      before_each(function()
        _, db = helpers.get_db_utils(strategy)
        assert(helpers.start_kong({
          database = strategy,
          admin_gui_url = "http://manager.konghq.com",
          admin_gui_auth = 'ldap-auth-advanced',
          admin_gui_session_conf = "{ \"secret\": \"super-secret\" }",
          enforce_rbac = "on",
        }))
        ee_helpers.register_rbac_resources(db)
        client = assert(helpers.admin_client())
      end)

      after_each(function()
        if client then client:close() end
        assert(helpers.stop_kong())
      end)

      it("doesn't register an invited admin with ldap", function()
        local res = assert(admins_helpers.create({
          username = "bob",
          email = "hong@konghq.com",
        }, {
          db = db,
          token_optional = true,
          token_expiry = 3600,
          remote_addr = "127.0.0.1",
          raw = true,
        }))

        local admin = res.body.admin

        local reset_secret = db.consumer_reset_secrets:select({ id = admin.consumer.id })
        assert.equal(nil, reset_secret)

        local res = assert(client:send {
          method = "POST",
          path = "/admins/register",
          headers = {
            ["Content-Type"] = "application/json"
            -- no auth headers!
          },
          body  = {
            username = "bob",
            email = "hong@konghq.com",
            password = "clawz"
          },
        })

        assert.res_status(400, res)
      end)
    end)
  end)

  pending("Admin API - auto-approval #" .. strategy, function()
    local client
    local consumer
    local db

    before_each(function()
      _, db  = helpers.get_db_utils(strategy)
      assert(helpers.start_kong({
        database = strategy,
        admin_gui_url = "http://manager.konghq.com",
        admin_gui_auth = 'basic-auth',
        enforce_rbac = "on",
      }))
      ee_helpers.register_rbac_resources(db)
      client = assert(helpers.admin_client())
    end)

    after_each(function()
      if client then client:close() end
      assert(helpers.stop_kong())
    end)

    it("manages state transition for invited admins", function()
      -- create an admin who is pending
      local res = assert(client:send {
        method = "POST",
        path  = "/admins",
        headers = {
          ["Kong-Admin-Token"] = "letmein-default",
          ["Content-Type"] = "application/json",
        },
        body  = {
          custom_id = "gruce",
          username = "gruce@konghq.com",
          email = "gruce@konghq.com",
        },
      })
      res = assert.res_status(200, res)
      local json = cjson.decode(res)
      consumer = json.consumer

      -- he's invited
      assert.same(enums.CONSUMERS.STATUS.INVITED, consumer.status)

      -- add credentials for him
      assert(db.basicauth_credentials:insert {
        username    = "gruce@konghq.com",
        password    = "kong",
        consumer_id = consumer.id,
      })

      -- make an API call
      assert(client:send{
        method = "GET",
        path = "/",
        headers = {
          ["Kong-Admin-User"] = "gruce@konghq.com",
          ["Authorization"] = "Basic " .. ngx.encode_base64("gruce@konghq.com:kong")
        }
      })

      local updated_consumers = db.consumers:select({ id = consumer.id })
      assert.same(enums.CONSUMERS.STATUS.APPROVED, updated_consumers[1].status)
    end)
  end)

  describe("/admins/password_resets #" .. strategy, function()
    describe("with basic-auth", function()
      local client
      local db
      local admin
      local outside_admin
      local default_ws

      lazy_setup(function()
        _, db = helpers.get_db_utils(strategy)

        local config = {
          admin_invitation_expiry = 600,
        }

        if _G.kong then
          _G.kong.db = db
          _G.kong.configuration = config
        else
          _G.kong = {
            db = db,
            configuration = config,
          }
        end

        default_ws = assert(db.workspaces:select_by_name("default"))

        assert(helpers.start_kong({
          database = strategy,
          admin_gui_url = "http://manager.konghq.com",
          admin_gui_auth = "basic-auth",
          admin_gui_session_conf = "{ \"secret\": \"super-secret\" }",
          admin_gui_auth_password_complexity = "{\"kong-preset\": \"min_12\"}",
          enforce_rbac = "on",
        }))
        ee_helpers.register_rbac_resources(db)
        client = assert(helpers.admin_client())

        -- init outside_admin
        local another_ws = assert(db.workspaces:insert({
          name = "another-one",
        }))

        local res_outside = assert(admins_helpers.create({
          custom_id = "outsider1",
          username = "outsider1",
          email = "outsider1@konghq.com",
        }, {
          token_optional = false,
          remote_addr = "localhost",
          db = db,
          workspace = another_ws.name,
          raw = true,
        }))

        outside_admin = res_outside.body.admin

        -- init admin
        local res = assert(admins_helpers.create({
          custom_id = "gruce",
          username = "gruce",
          email = "gruce@konghq.com",
        }, {
          token_optional = false,
          remote_addr = "localhost",
          db = db,
          workspace = default_ws,
          raw = true,
        }))

        admin = res.body.admin

        -- add credentials
        assert(db.basicauth_credentials:insert {
          username    = "gruce",
          password    = "kong",
          consumer = admin.consumer,
        })

        assert(db.basicauth_credentials:insert {
          username    = "outsider1",
          password    = "outsider1pass",
          consumer = outside_admin.consumer,
        })
      end)

      lazy_teardown(function()
        if client then client:close() end
        assert(helpers.stop_kong())
      end)

      describe("POST", function()
        local function check_endpoint(admin)
          local res = assert(client:send {
            method = "POST",
            path  = "/admins/password_resets",
            headers = {
              ["Content-Type"] = "application/json",
            },
            body  = {
              email = admin.email,
            }
          })
          assert.res_status(200, res)
        end

        local function check_secrets(admin)
          local num_secrets = 0
          for _, err in db.consumer_reset_secrets:each_for_consumer({ id = admin.consumer.id }) do
            assert.is_nil(err)
            num_secrets = num_secrets + 1
          end

          -- one when he was invited, one when he forgot password
          assert.same(2, num_secrets)
        end

        it("creates a consumer_reset_secret", function()
          local admins = { admin, outside_admin }

          for _, _admin in ipairs(admins) do
            check_endpoint(_admin)
            check_secrets(_admin)
          end
        end)
      end)

      describe("PATCH", function()
        it("validates parameters", function()
          local res = assert(client:send {
            method = "PATCH",
            path  = "/admins/password_resets",
            headers = {
              ["Content-Type"] = "application/json",
            },
            body  = {
              email = "gruce@konghq.com",
            }
          })
          local body = assert.res_status(400, res)
          local json = cjson.decode(body)
          assert.same("password is required", json.message)

          local res = assert(client:send {
            method = "PATCH",
            path  = "/admins/password_resets",
            headers = {
              ["Content-Type"] = "application/json",
            },
            body  = {
              password = "password",
            }
          })
          local body = assert.res_status(400, res)
          local json = cjson.decode(body)
          assert.same("email is required", json.message)
        end)

        it("updates password", function()
          -- create admin
          local res = assert(admins_helpers.create({
            username = "kinman",
            email = "kinman@konghq.com",
          }, {
            db = db,
            token_optional = false,
            token_expiry = 3600,
            remote_addr = "127.0.0.1",
            raw = true,
          }))

          local admin = res.body.admin

          -- give admin a role so API request will succeed
          local role = assert(db.rbac_roles:select_by_name("read-only"))
          assert(db.rbac_user_roles:insert({
            user = admin.rbac_user,
            role = role,
          }))

          -- get JWT for setting password
          local token
          local claims = {
            id = admin.consumer.id,
            exp = ngx.time() + 100000,
          }
          for row, err in db.consumer_reset_secrets:each_for_consumer({ id = admin.consumer.id }) do
            assert.is_nil(err)
            token = ee_jwt.generate_JWT(claims, row.secret, "HS256")
          end

          -- set invalid password
          res = assert(client:send {
            method = "POST",
            path = "/admins/register",
            headers = {
              ["Content-Type"] = "application/json",
            },
            body  = {
              username  = "kinman",
              email = "kinman@konghq.com",
              password = "password",
              token = token,
            },
          })
          local body = assert.res_status(400, res)
          local json = cjson.decode(body)
          assert.truthy(string.match(json.message, "Invalid password"))

          -- set new password
          local new_password = "resetPassword123"
          res = assert(client:send {
            method = "POST",
            path = "/admins/register",
            headers = {
              ["Content-Type"] = "application/json",
            },
            body  = {
              username  = "kinman",
              email = "kinman@konghq.com",
              password = new_password,
              token = token,
            },
          })
          assert.res_status(201, res)

          -- use password
          res = assert(client:send {
            method = "GET",
            path = "/auth",
            headers = {
              ["Authorization"] = "Basic " ..
                                  ngx.encode_base64("kinman:" .. new_password),
              ["Kong-Admin-User"] = "kinman",
            }
          })
          assert.res_status(200, res)

          -- create a token for updating password
          local jwt, err = secrets.create(admin.consumer, "localhost", ngx.time() + 100000)
          assert.is_nil(err)
          assert.is_not_nil(jwt)

          -- update password
          new_password = "update-Password"
          res = assert(client:send {
            method = "PATCH",
            path  = "/admins/password_resets",
            headers = {
              ["Content-Type"] = "application/json",
            },
            body  = {
              email = "kinman@konghq.com",
              password = new_password,
              token = jwt,
            }
          })
          assert.res_status(200, res)

          -- use password
          res = assert(client:send {
            method = "GET",
            path = "/auth",
            headers = {
              ["Authorization"] = "Basic " ..
                                  ngx.encode_base64("kinman:" .. new_password),
              ["Kong-Admin-User"] = "kinman",
            }
          })

          assert.res_status(200, res)
        end)
      end)
    end)

    describe("with 3rd-party auth", function()
      local client
      local db

      before_each(function()
        _, db = helpers.get_db_utils(strategy)
        assert(helpers.start_kong({
          database = strategy,
          admin_gui_url = "http://manager.konghq.com",
          admin_gui_auth = "ldap-auth-advanced",
          admin_gui_session_conf = "{ \"secret\": \"super-secret\" }",
          enforce_rbac = "on",
        }))
        ee_helpers.register_rbac_resources(db)

        client = assert(helpers.admin_client())
      end)

      after_each(function()
        if client then client:close() end
        assert(helpers.stop_kong())
      end)

      describe("POST", function()
        it("returns 404", function()
          local res = assert(client:send {
            method = "POST",
            path = "/admins/password_resets",
            headers = {
              ["Content-Type"] = "application/json",
            },
            body = {
              email = "admin-1@test.com",
            }
          })

          local body = assert.res_status(404, res)
          local json = cjson.decode(body)
          assert.same("Not found", json.message)
        end)
      end)

      describe("PATCH", function()
        it("returns 404", function()
          local res = assert(client:send {
            method = "PATCH",
            path = "/admins/password_resets",
            headers = {
              ["Content-Type"] = "application/json",
            },
            body = {
              email = "admin-1@test.com",
              password = "new-password",
            }
          })

          local body = assert.res_status(404, res)
          local json = cjson.decode(body)
          assert.same("Not found", json.message)
        end)
      end)
    end)
  end)

  describe("/admins/self/password #" .. strategy, function()
    describe("with basic-auth", function()
      local client
      local db
      local admin
      local default_ws

      local password_reset = function (client, cookie, body)
        return client:send {
          method = "PATCH",
          path  = "/admins/self/password",
          headers = {
            ["Content-Type"] = "application/json",
            ["kong-admin-user"] = "gruce",
            cookie = cookie,
          },
          body = body,
        }
      end

      lazy_setup(function()
        _, db = helpers.get_db_utils(strategy)

        default_ws = assert(db.workspaces:select_by_name("default"))

        assert(helpers.start_kong({
          database = strategy,
          admin_gui_url = "http://manager.konghq.com",
          admin_gui_auth = "basic-auth",
          admin_gui_session_conf = "{ \"secret\": \"super-secret\" }",
          admin_gui_auth_password_complexity = "{\"kong-preset\": \"min_8\"}",
          enforce_rbac = "on",
        }))
        ee_helpers.register_rbac_resources(db)
        client = assert(helpers.admin_client())

        local res = assert(admins_helpers.create({
          custom_id = "gruce",
          username = "gruce",
          email = "gruce@konghq.com",
        }, {
          token_optional = false,
          remote_addr = "localhost",
          db = db,
          workspace = default_ws,
          raw = true,
        }))

        admin = res.body.admin

        -- add credentials
        assert(db.basicauth_credentials:insert {
          username    = "gruce",
          password    = "original_gangster",
          consumer = admin.consumer,
        })
      end)

      lazy_teardown(function()
        if client then client:close() end
        assert(helpers.stop_kong())
      end)

      describe("POST", function()
        it("400 - password complexity checks should be enabled", function()
          local cookie = get_admin_cookie(client, "gruce", "original_gangster")
          local res = assert(password_reset(client, cookie, {
            password = "1"
          }))

          local body = assert.res_status(400, res)
          local json = cjson.decode(body)

          assert.equal("Invalid password: too short", json.message)
        end)

        it("400 - old_password required", function()
          local cookie = get_admin_cookie(client, "gruce", "original_gangster")
          local res = assert(password_reset(client, cookie, {password = "new_hotness"}))

          assert.res_status(400, res)
        end)

        it("400 - old_password cannot be the same as new password", function()
          local cookie = get_admin_cookie(client, "gruce", "original_gangster")
          local res = assert(password_reset(client, cookie, {
            password = "New_hotness123",
            old_password = "New_hotness123"
          }))

          local body = assert.res_status(400, res)
          local json = cjson.decode(body)

          assert.equal("Passwords cannot be the same", json.message)
        end)

        it("400 - old_password must be correct", function()
          local cookie = get_admin_cookie(client, "gruce", "original_gangster")
          local res = assert(password_reset(client, cookie, {
            password = "New_hotness123",
            old_password = "i_Am_Not_Correct"
          }))
          local body = assert.res_status(400, res)
          local json = cjson.decode(body)

          assert.equal("Old password is invalid", json.message)
        end)

        it("password can be reset successfully", function()
          local old_password = "original_gangster"
          local new_password = "New_hotne33"

          local cookie = get_admin_cookie(client, "gruce", old_password)
          local res = assert(password_reset(client, cookie, {
            password = new_password,
            old_password = old_password,
          }))
          local body = assert.res_status(200, res)
          local json = cjson.decode(body)

          assert.equal("Password reset successfully", json.message)

          -- use the new password to obtain a cookie
          local cookie = get_admin_cookie(client, "gruce", new_password)
          assert.truthy(cookie)

          -- ensure old password doesn't work anymore
          local res = assert(client:send {
            method = "GET",
            path = "/auth",
            headers = {
              ["Authorization"] = "Basic " ..
                                  ngx.encode_base64("gruce" .. ":" .. old_password),
              ["Kong-Admin-User"] = "gruce",
            }
          })

          assert.res_status(401, res)
        end)
      end)
    end)
  end)

  describe("Admin API - /admins/:admin/roles #" .. strategy, function()
    local db, client
    local default_ws, another_ws
    local headers = {
      ["Kong-Admin-Token"] = "letmein-default",
      ["Content-Type"]     = "application/json",
    }

    lazy_setup(function()
      _, db = helpers.get_db_utils(strategy)
      db:truncate("rbac_users")
      db:truncate("rbac_user_roles")
      db:truncate("rbac_roles")
      db:truncate("rbac_role_entities")
      db:truncate("rbac_role_endpoints")
      db:truncate("consumers")
      db:truncate("admins")

      default_ws = assert(db.workspaces:select_by_name("default"))

      another_ws = assert(db.workspaces:insert({
        name = "another-one",
      }))

      scope.run_with_ws_scope({ another_ws }, function()
        ee_helpers.register_rbac_resources(db, "another-one")
      end)

      ee_helpers.register_rbac_resources(db)

      assert(helpers.start_kong({
        database = strategy,
        admin_gui_url = "http://manager.konghq.com",
        enforce_rbac = "on"
      }))
    end)

    before_each(function()
      if client then
        client:close()
      end

      client = assert(helpers.admin_client())
    end)

    lazy_teardown(function()
      if client then
        client:close()
      end

      helpers.stop_kong()

      db:truncate("rbac_users")
      db:truncate("rbac_user_roles")
      db:truncate("rbac_roles")
      db:truncate("rbac_role_entities")
      db:truncate("rbac_role_endpoints")
      db:truncate("consumers")
      db:truncate("admins")
    end)


    describe("POST", function()
      it("associates a role with an admin", function()
        assert(admins_helpers.create({
          username = "bob",
          email = "bob@konghq.com",
          status = enums.CONSUMERS.STATUS.APPROVED,
        }, {
          token_optional = true,
          db = db,
          workspace = default_ws
        }))

        local res = assert(client:send {
          path = "/admins/bob/roles",
          method = "POST",
          body = {
            roles = "read-only",
          },
          headers = headers,
        })
        local body = assert.res_status(201, res)
        local json = cjson.decode(body)

        -- bob has read-only now
        assert.same(1, #json.roles)
        assert.same("read-only", json.roles[1].name)
      end)

      it("associates multiple roles with a user", function()
        assert(admins_helpers.create({
          username = "jerry",
          email = "jerry@konghq.com",
          status = enums.CONSUMERS.STATUS.APPROVED,
        }, {
          token_optional = true,
          db = db,
          workspace = default_ws
        }))

        local res = assert(client:send {
          path = "/admins/jerry/roles",
          method = "POST",
          body = {
            roles = "read-only,admin",
          },
          headers = headers,
        })
        local body = assert.res_status(201, res)
        local json = cjson.decode(body)

        -- jerry now has read-only and admin
        assert.same(2, #json.roles)
      end)

      describe("errors", function()
        it("when the admin doesn't exist", function()
          local res = assert(client:send {
            path = "/admins/dne/roles",
            method = "POST",
            body = {
              roles = "read-only",
            },
            headers = headers,
          })

          local body = assert.res_status(404, res)
          local json = cjson.decode(body)
          assert.same("Not found", json.message)
        end)

        it("when the role doesn't exist", function()
          assert(admins_helpers.create({
            username = "bob",
            email = "bob@konghq.com",
            status = enums.CONSUMERS.STATUS.APPROVED,
          }, {
            token_optional = true,
            db = db,
            workspace = default_ws
          }))

          local res = assert(client:send {
            path = "/admins/bob/roles",
            method = "POST",
            body = {
              roles = "dne",
            },
            headers = headers,
          })

          local body = assert.res_status(400, res)
          local json = cjson.decode(body)

          assert.same("role not found with name 'dne'", json.message)
        end)

        it("when duplicate relationships are attempted", function()
          assert(admins_helpers.create({
            username = "bill",
            email = "bill@konghq.com",
            status = enums.CONSUMERS.STATUS.APPROVED,
          }, {
            token_optional = true,
            db = db,
            workspace = default_ws
          }))

          local res = assert(client:send {
            path = "/admins/bill/roles",
            method = "POST",
            body = {
              roles = "read-only",
            },
            headers = headers,
          })

          assert.res_status(201, res)

          res = assert(client:send {
            path = "/admins/bill/roles",
            method = "POST",
            body = {
              roles = "read-only",
            },
            headers = headers
          })

          assert.res_status(400, res)
        end)
      end)
    end)

    describe("GET", function()
      it("displays the non-default roles associated with the admin", function()
        assert(admins_helpers.create({
          username = "bobby",
          email = "bobby@konghq.com",
          status = enums.CONSUMERS.STATUS.APPROVED,
        }, {
          token_optional = true,
          db = db,
          workspace = default_ws,
        }))

        local res = assert(client:send {
          path = "/admins/bobby/roles",
          method = "POST",
          body = {
            roles = "read-only",
          },
          headers = headers,
        })
        assert.res_status(201, res)

        local res = assert(client:send {
          path = "/admins/bobby/roles",
          method = "GET",
          headers = headers,
        })
        local body = assert.res_status(200, res)
        local json = cjson.decode(body)

        -- bobby has read-only role
        assert.same(1, #json.roles)
        assert.same("read-only", json.roles[1].name)

        assert(admins_helpers.create({
          username = "jerry_s",
          email = "jerry_s@konghq.com",
          status = enums.CONSUMERS.STATUS.APPROVED,
        }, {
          token_optional = true,
          db = db,
          workspace = default_ws,
        }))

        local res = assert(client:send {
          path = "/admins/jerry_s/roles",
          method = "POST",
          body = {
            roles = "read-only,admin",
          },
          headers = headers,
        })
        assert.res_status(201, res)

        res = assert(client:send {
          path = "/admins/jerry_s/roles",
          method = "GET",
          headers = headers
        })

        local body = assert.res_status(200, res)
        local json = cjson.decode(body)

        -- jerry_s has admin and read-only
        assert.same(2, #json.roles)
        for _, role in ipairs(json.roles) do
          assert.is_true(role.name == "admin" or role.name == "read-only")
        end
      end)

      it("displays roles across workspaces", function()
        assert(admins_helpers.create({
          custom_id = "larry_outsider",
          username = "larry_outsider",
          email = "larry_outsider@konghq.com",
        }, {
          token_optional = false,
          remote_addr = "localhost",
          db = db,
          workspace = another_ws.name,
          raw = true,
        }))

        post(client, "/" .. another_ws.name .. "/rbac/roles", {
          name = another_ws.name .. "-read-only",
        }, headers, 201)
        post(client, "/admins/larry_outsider/roles", {
          roles = "read-only",
        }, headers, 201)
        post(client, "/" .. another_ws.name .. "/admins/larry_outsider/roles", {
          roles = another_ws.name .. "-read-only",
        }, headers, 201)

        post(client, "/" .. another_ws.name .. "/rbac/roles/".. another_ws.name .. "-read-only/endpoints", {
          workspace = another_ws.name,
          endpoint = "/consumers",
          actions = "read"
        }, headers, 201)

        local res = assert(client:send {
          path = "/admins/larry_outsider/roles",
          method = "GET",
          headers = headers,
        })
        local body = assert.res_status(200, res)
        local json = cjson.decode(body)

        -- has read-only role in default workspace
        assert.same(1, #json.roles)
        assert.same("read-only", json.roles[1].name)

        res = assert(client:send {
          path = "/" .. another_ws.name .. "/admins/larry_outsider/roles",
          method = "GET",
          headers = headers,
        })
        body = assert.res_status(200, res)
        json = cjson.decode(body)

        -- has workspace specific role only in other workspace
        assert.same(1, #json.roles)
        assert.same(another_ws.name .. "-read-only", json.roles[1].name)
      end)

      it("displays roles across workspaces including asterisk", function()
        post(client, "/"  .. another_ws.name .. "/rbac/roles", { name = another_ws.name .. "-read-only1", }, headers, 201)
        post(client, "/rbac/roles", { name = "role-with-everythang" }, headers, 201)
        post(client, "/"  .. another_ws.name .. "/rbac/roles/" .. another_ws.name .. "-read-only1/endpoints", {
          workspace = another_ws.name,
          endpoint = "*",
          actions = "read"
        }, headers, 201)
        post(client, "/rbac/roles/role-with-everythang/endpoints", {
          workspace = "*",
          endpoint = "*",
          actions = "read"
        }, headers, 201)

        assert(admins_helpers.create({
          custom_id = "htopper",
          username = "htopper",
          email = "htopper@konghq.com",
        }, {
          token_optional = false,
          remote_addr = "localhost",
          db = db,
          workspace = kong.default_workspace,
          raw = true,
        }))

        post(client, "/admins/htopper/roles", {
          roles = "role-with-everythang",
        }, headers, 201)

        post(client, "/" .. another_ws.name .. "/admins/htopper/roles", {
          roles = another_ws.name .. "-read-only1",
        }, headers, 201)

        local res = assert(client:send {
          path = "/default/admins/htopper/roles",
          method = "GET",
          headers = headers,
        })
        local body = assert.res_status(200, res)
        local json = cjson.decode(body)

        -- has read-only1 role in default workspace
        assert.same(1, #json.roles)
        assert.same("role-with-everythang", json.roles[1].name)

        res = assert(client:send {
          path = "/" .. another_ws.name .. "/admins/htopper/roles",
          method = "GET",
          headers = headers,
        })
        body = assert.res_status(200, res)
        json = cjson.decode(body)

        -- has workspace specific role only in other workspace
        assert.same(1, #json.roles)
        assert.same(another_ws.name .. "-read-only1", json.roles[1].name)
      end)
    end)

    describe("DELETE", function()
      it("removes a role associated with an admin", function()
        assert(admins_helpers.create({
          username = "bob-remove",
          email = "bob-remove@konghq.com",
          status = enums.CONSUMERS.STATUS.APPROVED,
        }, {
          token_optional = true,
          db = db,
          workspace = default_ws
        }))

        local res = assert(client:send {
          path = "/admins/bob-remove/roles",
          method = "POST",
          body = {
            roles = "read-only",
          },
          headers = headers,
        })
        assert.res_status(201, res)

        local res = assert(client:send {
          path = "/admins/bob-remove/roles",
          method = "DELETE",
          body = {
            roles = "read-only",
          },
          headers = headers,
        })
        assert.res_status(204, res)

        res = assert(client:send {
          path = "/admins/bob-remove/roles",
          method = "GET",
          headers = headers,
        })

        local body = assert.res_status(200, res)
        local json = cjson.decode(body)

        -- bob-remove didn't have any other public roles
        assert.same(0, #json.roles)
      end)

      it("removes only one role associated with a user", function()
        assert(admins_helpers.create({
          username = "jerry_removes",
          email = "jerry_removes@konghq.com",
          status = enums.CONSUMERS.STATUS.APPROVED,
        }, {
          token_optional = true,
          db = db,
          workspace = default_ws
        }))

        local res = assert(client:send {
          path = "/admins/jerry_removes/roles",
          method = "POST",
          body = {
            roles = "read-only,admin",
          },
          headers = headers,
        })
        assert.res_status(201, res)

        local res = assert(client:send {
          path = "/admins/jerry_removes/roles",
          method = "DELETE",
          body = {
            roles = "read-only",
          },
          headers = headers,
        })
        assert.res_status(204, res)

        res = assert(client:send {
          path = "/admins/jerry_removes/roles",
          method = "GET",
          headers = headers,
        })

        local body = assert.res_status(200, res)
        local json = cjson.decode(body)

        -- jerry_removes no longer has read-only
        assert.same(1, #json.roles)
        assert.same("admin", json.roles[1].name)
      end)

      describe("errors", function()
        it("when the user doesn't exist", function()
          local res = assert(client:send {
            path = "/admins/dne/roles",
            method = "DELETE",
            body = {
              roles = "read-only",
            },
            headers = headers
          })

          local body = assert.res_status(404, res)
          local json = cjson.decode(body)
          assert.same("Not found", json.message)
        end)

        it("when no roles are defined", function()
          assert(admins_helpers.create({
            username = "bob",
            email = "bob@konghq.com",
            status = enums.CONSUMERS.STATUS.APPROVED,
          }, {
            token_optional = true,
            db = db,
            workspace = default_ws
          }))

          local res = assert(client:send {
            path = "/admins/bob/roles",
            method = "DELETE",
            headers = headers
          })

          local body = assert.res_status(400, res)
          local json = cjson.decode(body)

          assert.same("must provide >= 1 role", json.message)
        end)
      end)
    end)
  end)

  describe("Admin API - Admins Token Reset #" .. strategy, function()
    local client
    local db
    local bp
    local another_ws
    local outside_admin
    local admin
    local admins = {}

    lazy_setup(function()
      bp, db = helpers.get_db_utils(strategy, {
        "consumers",
        "rbac_users",
        "rbac_roles",
        "rbac_user_roles",
        "admins",
      })
      local config = {
        database = strategy,
        admin_gui_url = "http://manager.konghq.com",
        admin_gui_session_conf = "{ \"secret\": \"super-secret\" }",
        admin_gui_auth = "basic-auth",
        enforce_rbac = "on",
      }
      assert(helpers.start_kong(config))

      another_ws = assert(bp.workspaces:insert({
        name = "another-one",
      }))

      ee_helpers.register_rbac_resources(db)

      local role = db.rbac_roles:select_by_name("super-admin")
      for i = 1, 3 do
        -- admins that are already approved
        admins[i] = assert(db.admins:insert {
          username = "admin-" .. i .. "@test.com",
          custom_id = "admin-" .. i,
          email = "admin-" .. i .. "@test.com",
          status = enums.CONSUMERS.STATUS.APPROVED,
        })

        assert(db.basicauth_credentials:insert {
          username    = admins[i].username,
          password    = "hunter" .. i,
          consumer = {
            id = admins[i].consumer.id,
          },
        })
        db.rbac_user_roles:insert({
          user = { id = admins[i].rbac_user.id },
          role = { id = role.id }
        })
      end
      admin = admins[1]

      local ws, err = db.workspaces:select_by_name(another_ws.name)
      assert.not_nil(ws)
      assert.is_nil(err)
      assert.same("another-one", ws.name)
      local role = db.rbac_roles:insert({ name = "another-one" })
      scope.run_with_ws_scope({ws}, function ()
        outside_admin, _ = kong.db.admins:insert({
          username = "outsider1",
          email = "outsider1@konghq.com",
          status = enums.CONSUMERS.STATUS.APPROVED,
        })

        assert.is_not_nil(role)
      end)

      scope.run_with_ws_scope({ws}, function ()
        assert(db.basicauth_credentials:insert {
          username    = outside_admin.username,
          password    = "outsider1pass",
          consumer = {
            id = outside_admin.consumer.id,
          },
        })

        assert.is_not_nil(role)
      end)

    end)

    lazy_teardown(function()
      helpers.stop_kong()
      db:truncate("consumers")
      db:truncate("rbac_user_roles")
      db:truncate("rbac_roles")
      db:truncate("rbac_users")
      db:truncate("admins")
      db:truncate("basicauth_credentials")
    end)

    before_each(function()
      client = assert(helpers.admin_client())
    end)

    after_each(function()
      if client then client:close() end
    end)

    describe("/admins/self/token", function()
      describe("PATCH", function ()
        it("updates an admin token successfully", function()
          local cookie = get_admin_cookie(client, admin.username, 'hunter1')
          local res = client:send {
            method = "PATCH",
            path = "/admins/self/token",
            headers = {
              ["Kong-Admin-User"] = admin.username,
              cookie = cookie,
            }
          }
          local rando = utils.random_string()
          local body = assert.res_status(200, res)
          local json = cjson.decode(body)

          assert.equal(#json.token, 32)
          assert.not_equal(json.token, rando)
        end)

        it("updates an admin token uniquely across requests", function()
          local cookie = get_admin_cookie(client, admin.username, 'hunter1')
          local patch_token = function()
            local res = client:send {
              method = "PATCH",
              path = "/admins/self/token",
              headers = {
                ["Kong-Admin-User"] = admin.username,
                cookie = cookie,
              }
            }
            local body = assert.res_status(200, res)
            local json = cjson.decode(body)
            return json.token
          end

          local seen = {}
          local hasDuplicates = false
          for i=1,10 do
            local t = patch_token()
            assert.equal(#t, 32)
            if not seen[t] then
              seen[t] = true
            else
              hasDuplicates = true
              break
            end
          end
          assert.is_false(hasDuplicates)
        end)

        it("allows read-only admins to update tokens", function()
          local cookie = get_admin_cookie(client, admin.username, 'hunter1')
          local res = assert(client:send {
            path = "/admins/" .. admins[3].username .. "/roles",
            method = "POST",
            body = {
              roles = "read-only",
            },
            headers = {
              ["Content-Type"] = "application/json",
              ["Kong-Admin-User"] = admin.username,
              cookie = cookie,
            },
          })
          assert.res_status(201, res)

          local res = assert(client:send {
            path = "/admins/" .. admins[3].username .. "/roles",
            method = "DELETE",
            body = {
              roles = "super-admin",
            },
            headers = {
              ["Content-Type"] = "application/json",
              ["cookie"] = cookie,
              ["Kong-Admin-User"] = admin.username,
            },
          })
          assert.res_status(204, res)

          res = assert(client:send {
            path = "/admins/" .. admins[3].username .. "/roles",
            method = "GET",
            headers = {
              ["Content-Type"] = "application/json",
              ["cookie"] = cookie,
              ["Kong-Admin-User"] = admin.username,
            },
          })

          local body = assert.res_status(200, res)
          local json = cjson.decode(body)

          assert.same(1, #json.roles)
          assert.same("read-only", json.roles[1].name)

          local cookie = get_admin_cookie(client, admins[3].username, 'hunter3')
          local res = client:send {
            method = "PATCH",
            path = "/admins/self/token",
            headers = {
              ["cookie"] = cookie,
              ["Kong-Admin-User"] = admins[3].username,
            }
          }

          local body = assert.res_status(200, res)
          local json = cjson.decode(body)

          assert.equal(#json.token, 32)
        end)

        it("fails when trying to set token explictly", function()
          local cookie = get_admin_cookie(client, admin.username, 'hunter1')
          local res = assert(client:send {
            path = "/admins/self/token",
            body = {
              token = "this-is-gonna-be-great"
            },
            method = "PATCH",
            headers = {
              ["Content-Type"] = "application/json",
              ["Kong-Admin-User"] = admin.username,
              cookie = cookie,
            },
          })

          res = assert.res_status(400, res)
          local json = cjson.decode(res)
          assert.equal("Tokens cannot be set explicitly. Remove token parameter to receive an auto-generated token.",
                       json.message)
        end)
      end)
    end)
  end)
end
