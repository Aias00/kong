local helpers = require "spec.helpers"
local cjson = require "cjson"
local enums = require "kong.enterprise_edition.dao.enums"
local utils = require "kong.tools.utils"
local proxy_prefix = require("kong.enterprise_edition.proxies").proxy_prefix


local function insert_files(dao)
  helpers.with_current_ws(nil, function()
  for i = 1, 10 do
    assert(dao.portal_files:insert {
      name = "file-" .. i,
      contents = "i-" .. i,
      type = "partial",
      auth = i % 2 == 0 and true or false
    })
  end
  end, dao)
end

local rbac_mode = {"on", "endpoint", "off"}

-- TODO: Cassandra
for _, strategy in helpers.each_strategy('postgres') do
  for idx, rbac in ipairs(rbac_mode) do
    describe("Developer Portal - Portal API (RBAC = " .. rbac .. ")", function()
      local bp
      local db
      local dao
      local client
      local consumer_approved

      setup(function()
        bp, db, dao = helpers.get_db_utils(strategy)
      end)

      teardown(function()
        helpers.stop_kong()
      end)

      -- this block is only run once, not for each rbac state
      if idx == 1 then
        describe("vitals", function ()
          local proxy_client

          before_each(function()
            helpers.stop_kong()
            helpers.register_consumer_relations(dao)

            assert(helpers.start_kong({
              database   = strategy,
              portal     = true,
              vitals     = true,
            }))

            client = assert(helpers.admin_client())
            proxy_client = assert(helpers.proxy_client())
          end)

          after_each(function()
            if client then
              client:close()
            end

            if proxy_client then
              proxy_client:close()
            end
          end)

          it("does not track internal proxies", function()
            local service_id = "00000000-0000-0000-0000-000000000001"

            local res = assert(client:send {
              method = "GET",
              path = "/vitals/status_codes/by_service",
              query = {
                interval   = "minutes",
                service_id = service_id,
              }
            })

            res = assert.res_status(404, res)
            local json = cjson.decode(res)

            assert.same("Not found", json.message)
          end)

          it("does not report metrics for internal proxies", function()
            local service_id = "00000000-0000-0000-0000-000000000001"

            local pres = assert(proxy_client:send {
              method = "GET",
              path = "/" .. proxy_prefix .. "/portal/files"
            })

            assert.res_status(200, pres)

            ngx.sleep(11) -- flush interval for vitals is at 10 seconds so wait
                          -- 11 to ensure we get metrics for the bucket this
                          -- request would live in.

            local res = assert(client:send {
              method = "GET",
              path = "/vitals/cluster",
              query = {
                interval   = "seconds",
                service_id = service_id,
              }
            })

            res = assert.res_status(200, res)

            local json = cjson.decode(res)
            for k,v in pairs(json.stats.cluster) do
              assert.equal(0, v[7]) -- ensure that each `requests_proxy_total` is
                                    -- equal to 0, this means that there were no
                                    -- proxy requests during this timeframe
            end
          end)
        end)
      end

      describe("/_kong/portal/files without auth", function()
        before_each(function()
          dao:truncate_tables()

          helpers.stop_kong()
          helpers.register_consumer_relations(dao)

          assert(helpers.start_kong({
            database   = strategy,
            portal     = true,
            rbac = rbac,
          }))

          client = assert(helpers.proxy_client())
        end)

        after_each(function()
          if client then
            client:close()
          end
        end)

        describe("GET", function()
          before_each(function()
            insert_files(dao)
          end)

          teardown(function()
            db:truncate()
          end)

          it("retrieves files", function()
            local res = assert(client:send {
              method = "GET",
              path = "/" .. proxy_prefix .. "/portal/files",
            })

            local body = assert.res_status(200, res)
            local json = cjson.decode(body)

            assert.equal(10, json.total)
            assert.equal(10, #json.data)
          end)

          it("retrieves only unauthenticated files", function()
            local res = assert(client:send {
              method = "GET",
              path = "/" .. proxy_prefix .. "/portal/files/unauthenticated",
            })

            local body = assert.res_status(200, res)
            local json = cjson.decode(body)

            assert.equal(5, json.total)
            assert.equal(5, #json.data)
            for key, value in ipairs(json.data) do
              assert.equal(false, value.auth)
            end
          end)
        end)
      end)

      describe("/_kong/portal/files with auth", function()
        setup(function()
          helpers.stop_kong()
          assert(db:truncate())
          helpers.register_consumer_relations(dao)

          insert_files(dao)

          assert(helpers.start_kong({
            database   = strategy,
            portal     = true,
            portal_auth = "basic-auth",
            rbac = rbac,
            portal_auth_config = "{ \"hide_credentials\": true }"
          }))

          local consumer_pending = bp.consumers:insert {
            username = "dale",
            type = enums.CONSUMERS.TYPE.DEVELOPER,
            status = enums.CONSUMERS.STATUS.PENDING
          }

          consumer_approved = bp.consumers:insert {
            username = "hawk",
            type = enums.CONSUMERS.TYPE.DEVELOPER,
            status = enums.CONSUMERS.STATUS.APPROVED
          }

          assert(dao.basicauth_credentials:insert {
            username    = "dale",
            password    = "kong",
            consumer_id = consumer_pending.id
          })

          assert(dao.basicauth_credentials:insert {
            username    = "hawk",
            password    = "kong",
            consumer_id = consumer_approved.id
          })
        end)

        before_each(function()
          client = assert(helpers.proxy_client())
        end)

        after_each(function()
          if client then
            client:close()
          end
        end)

        describe("GET", function()
          it("returns 401 when unauthenticated", function()
            local res = assert(client:send {
              method = "GET",
              path = "/" .. proxy_prefix .. "/portal/files",
            })

            assert.res_status(401, res)
          end)

          it("returns 401 when consumer is not approved", function()
            local res = assert(client:send {
              method = "GET",
              path = "/" .. proxy_prefix .. "/portal/files",
              headers = {
                ["Authorization"] = "Basic " .. ngx.encode_base64("dale:kong"),
              }
            })

            local body = assert.res_status(401, res)
            local json = cjson.decode(body)
            assert.same({ status = 1, label = "PENDING" }, json)
          end)

          it("retrieves files with an approved consumer", function()
            local res = assert(client:send {
              method = "GET",
              path = "/" .. proxy_prefix .. "/portal/files",
              headers = {
                ["Authorization"] = "Basic " .. ngx.encode_base64("hawk:kong"),
              }
            })

            local body = assert.res_status(200, res)
            local json = cjson.decode(body)

            assert.equal(10, json.total)
            assert.equal(10, #json.data)
          end)
        end)

        describe("POST, PATCH, PUT", function ()
          it("does not allow forbidden methods", function()
            local consumer_auth_header = "Basic " .. ngx.encode_base64("hawk:kong")

            local res_put = assert(client:send {
              method = "PUT",
              path = "/" .. proxy_prefix .. "/portal/files",
              headers = {
                ["Authorization"] = consumer_auth_header,
              }
            })

            assert.res_status(405, res_put)

            local res_patch = assert(client:send {
              method = "PATCH",
              path = "/" .. proxy_prefix .. "/portal/files",
              headers = {
                ["Authorization"] = consumer_auth_header,
              }
            })

            assert.res_status(405, res_patch)

            local res_post = assert(client:send {
              method = "POST",
              path = "/" .. proxy_prefix .. "/portal/files",
              headers = {
                ["Authorization"] = consumer_auth_header,
              }
            })

            assert.res_status(405, res_post)
          end)
        end)
      end)


      describe("/_kong/portal/register ", function()
        before_each(function()
          client = assert(helpers.proxy_client())
        end)

        after_each(function()
          if client then
            client:close()
          end
        end)

        describe("POST", function()
          it("registers a developer and set status to pending", function()
            local res = assert(client:send {
              method = "POST",
              path = "/" .. proxy_prefix .. "/portal/register",
              body = {
                email = "gruce@konghq.com",
                password = "kong"
              },
              headers = {["Content-Type"] = "application/json"}
            })

            local body = assert.res_status(201, res)
            local resp_body_json = cjson.decode(body)
            local credential = resp_body_json.credential
            local consumer = resp_body_json.consumer

            assert.equal("gruce@konghq.com", credential.username)
            assert.is_true(utils.is_valid_uuid(credential.id))
            assert.is_true(utils.is_valid_uuid(consumer.id))

            assert.equal(enums.CONSUMERS.TYPE.DEVELOPER, consumer.type)
            assert.equal(enums.CONSUMERS.STATUS.PENDING, consumer.status)

            assert.equal(consumer.id, credential.consumer_id)
          end)
        end)
      end)

      describe("/_kong/portal/developer", function()
        local developer

        setup(function()
          helpers.stop_kong()
          assert(db:truncate())
          helpers.register_consumer_relations(dao)

          assert(helpers.start_kong({
            database   = strategy,
            portal     = true,
            rbac       = rbac,
            portal_auth = "basic-auth",
            portal_auth_config = "{ \"hide_credentials\": true }",
            portal_auto_approve = "on",
          }))

          client = assert(helpers.proxy_client())

          local res = assert(client:send {
            method = "POST",
            path = "/" .. proxy_prefix .. "/portal/register",
            body = {
              email = "gruce@konghq.com",
              password = "kong",
              meta = "{\"full_name\":\"I Like Turtles\"}"
            },
            headers = {["Content-Type"] = "application/json"}
          })

          local body = assert.res_status(201, res)
          local resp_body_json = cjson.decode(body)
          developer = resp_body_json.consumer

          client:close()
        end)

        before_each(function()
          client = assert(helpers.proxy_client())
        end)

        after_each(function()
          if client then
            client:close()
          end
        end)

        describe("GET", function()
          it("returns the authenticated developer", function()
            local res = assert(client:send {
              method = "GET",
              path = "/" .. proxy_prefix .. "/portal/developer",
              headers = {
                ["Content-Type"] = "application/json",
                ["Authorization"] = "Basic " .. ngx.encode_base64("gruce@konghq.com:kong"),
              }
            })

            local body = assert.res_status(200, res)
            local resp_body_json = cjson.decode(body)
            local res_developer = resp_body_json

            assert.same(res_developer, developer)
          end)
        end)
      end)

      describe("/_kong/portal/developer/password", function()

        setup(function()
          helpers.stop_kong()
          assert(db:truncate())
          helpers.register_consumer_relations(dao)

          assert(helpers.start_kong({
            database   = strategy,
            portal     = true,
            rbac       = rbac,
            portal_auth = "basic-auth",
            portal_auth_config = "{ \"hide_credentials\": true }",
            portal_auto_approve = "on",
          }))

          client = assert(helpers.proxy_client())

          local res = assert(client:send {
            method = "POST",
            path = "/" .. proxy_prefix .. "/portal/register",
            body = {
              email = "gruce@konghq.com",
              password = "kong",
              meta = "{\"full_name\":\"I Like Turtles\"}"
            },
            headers = {["Content-Type"] = "application/json"}
          })

          assert.res_status(201, res)

          client:close()
        end)

        before_each(function()
          client = assert(helpers.proxy_client())
        end)

        after_each(function()
          if client then
            client:close()
          end
        end)

        describe("PATCH", function()
          it("returns 400 if patched with no password", function()
            local res = assert(client:send {
              method = "PATCH",
              body = {},
              path = "/" .. proxy_prefix .. "/portal/developer/password",
              headers = {
                ["Content-Type"] = "application/json",
                ["Authorization"] = "Basic " .. ngx.encode_base64("gruce@konghq.com:kong"),
              }
            })

            local body = assert.res_status(400, res)
            local resp_body_json = cjson.decode(body)
            local message = resp_body_json.message

            assert.equal("Password is required", message)
          end)

          it("updates the password", function()
            local res = assert(client:send {
              method = "PATCH",
              body = {
                password = "hunter1",
              },
              path = "/" .. proxy_prefix .. "/portal/developer/password",
              headers = {
                ["Content-Type"] = "application/json",
                ["Authorization"] = "Basic " .. ngx.encode_base64("gruce@konghq.com:kong"),
              }
            })

            assert.res_status(204, res)

            -- old password fails
            local res = assert(client:send {
              method = "GET",
              path = "/" .. proxy_prefix .. "/portal/developer",
              headers = {
                ["Content-Type"] = "application/json",
                ["Authorization"] = "Basic " .. ngx.encode_base64("gruce@konghq.com:kong"),
              }
            })

            assert.res_status(403, res)

            -- new password auths
            local res = assert(client:send {
              method = "GET",
              path = "/" .. proxy_prefix .. "/portal/developer",
              headers = {
                ["Content-Type"] = "application/json",
                ["Authorization"] = "Basic " .. ngx.encode_base64("gruce@konghq.com:hunter1"),
              }
            })

            assert.res_status(200, res)
          end)
        end)
      end)

      describe("/_kong/portal/developer/email", function()
        local developer2

        setup(function()
          helpers.stop_kong()
          assert(db:truncate())
          helpers.register_consumer_relations(dao)

          assert(helpers.start_kong({
            database   = strategy,
            portal     = true,
            rbac       = rbac,
            portal_auth = "basic-auth",
            portal_auth_config = "{ \"hide_credentials\": true }",
            portal_auto_approve = "on",
          }))

          client = assert(helpers.proxy_client())

          local res = assert(client:send {
            method = "POST",
            path = "/" .. proxy_prefix .. "/portal/register",
            body = {
              email = "gruce@konghq.com",
              password = "kong",
              meta = "{\"full_name\":\"I Like Turtles\"}"
            },
            headers = {["Content-Type"] = "application/json"}
          })

          assert.res_status(201, res)

          local res = assert(client:send {
            method = "POST",
            path = "/" .. proxy_prefix .. "/portal/register",
            body = {
              email = "fancypants@konghq.com",
              password = "mowmow",
              meta = "{\"full_name\":\"Old Gregg\"}"
            },
            headers = {["Content-Type"] = "application/json"}
          })

          local body = assert.res_status(201, res)
          local resp_body_json = cjson.decode(body)
          developer2 = resp_body_json.consumer

          client:close()
        end)

        before_each(function()
          client = assert(helpers.proxy_client())
        end)

        after_each(function()
          if client then
            client:close()
          end
        end)

        describe("PATCH", function()
          it("returns 400 if patched with an invalid email", function()
            local res = assert(client:send {
              method = "PATCH",
              body = {
                email = "emailol.com",
              },
              path = "/" .. proxy_prefix .. "/portal/developer/email",
              headers = {
                ["Content-Type"] = "application/json",
                ["Authorization"] = "Basic " .. ngx.encode_base64("gruce@konghq.com:kong"),
              }
            })

            local body = assert.res_status(400, res)
            local resp_body_json = cjson.decode(body)
            local message = resp_body_json.message

            assert.equal("Invalid email", message)
          end)

          it("returns 409 if patched with an email that already exists", function()
            local res = assert(client:send {
              method = "PATCH",
              body = {
                email = developer2.email,
              },
              path = "/" .. proxy_prefix .. "/portal/developer/email",
              headers = {
                ["Content-Type"] = "application/json",
                ["Authorization"] = "Basic " .. ngx.encode_base64("gruce@konghq.com:kong"),
              }
            })

            local body = assert.res_status(409, res)
            local resp_body_json = cjson.decode(body)
            local message = resp_body_json.username

            assert.equal("already exists with value 'fancypants@konghq.com'", message)
          end)

          it("updates both email and username from passed email", function()
            local res = assert(client:send {
              method = "PATCH",
              body = {
                email = "new_email@whodis.com",
              },
              path = "/" .. proxy_prefix .. "/portal/developer/email",
              headers = {
                ["Content-Type"] = "application/json",
                ["Authorization"] = "Basic " .. ngx.encode_base64("gruce@konghq.com:kong"),
              }
            })

            assert.res_status(204, res)

            -- old email fails
            local res = assert(client:send {
              method = "GET",
              path = "/" .. proxy_prefix .. "/portal/developer",
              headers = {
                ["Content-Type"] = "application/json",
                ["Authorization"] = "Basic " .. ngx.encode_base64("gruce@konghq.com:kong"),
              }
            })

            assert.res_status(403, res)


            -- new email succeeds
            local res = assert(client:send {
              method = "GET",
              path = "/" .. proxy_prefix .. "/portal/developer",
              headers = {
                ["Content-Type"] = "application/json",
                ["Authorization"] = "Basic " .. ngx.encode_base64("new_email@whodis.com:kong"),
              }
            })

            local body = assert.res_status(200, res)
            local resp_body_json = cjson.decode(body)
            assert.equal("new_email@whodis.com", resp_body_json.email)
            assert.equal("new_email@whodis.com", resp_body_json.username)
          end)
        end)
      end)

      describe("/_kong/portal/developer/meta", function()

        setup(function()
          helpers.stop_kong()
          assert(db:truncate())
          helpers.register_consumer_relations(dao)

          assert(helpers.start_kong({
            database   = strategy,
            portal     = true,
            rbac       = rbac,
            portal_auth = "basic-auth",
            portal_auth_config = "{ \"hide_credentials\": true }",
            portal_auto_approve = "on",
          }))

          client = assert(helpers.proxy_client())

          local res = assert(client:send {
            method = "POST",
            path = "/" .. proxy_prefix .. "/portal/register",
            body = {
              email = "gruce@konghq.com",
              password = "kong",
              meta = "{\"full_name\":\"I Like Turtles\"}"
            },
            headers = {["Content-Type"] = "application/json"}
          })

          assert.res_status(201, res)
          client:close()
        end)

        before_each(function()
          client = assert(helpers.proxy_client())
        end)

        after_each(function()
          if client then
            client:close()
          end
        end)

        describe("PATCH", function()
          it("updates the meta", function()
            local new_meta = "{\"full_name\":\"KONG!!!\"}"

            local res = assert(client:send {
              method = "PATCH",
              body = {
                meta = new_meta
              },
              path = "/" .. proxy_prefix .. "/portal/developer/meta",
              headers = {
                ["Content-Type"] = "application/json",
                ["Authorization"] = "Basic " .. ngx.encode_base64("gruce@konghq.com:kong"),
              }
            })

            assert.res_status(204, res)

            local res = assert(client:send {
              method = "GET",
              path = "/" .. proxy_prefix .. "/portal/developer",
              headers = {
                ["Content-Type"] = "application/json",
                ["Authorization"] = "Basic " .. ngx.encode_base64("gruce@konghq.com:kong"),
              }
            })

            local body = assert.res_status(200, res)
            local resp_body_json = cjson.decode(body)
            local meta = resp_body_json.meta

            assert.equal(meta, new_meta)
          end)

          it("ignores keys that are not in the current meta", function()
            local res = assert(client:send {
              method = "GET",
              path = "/" .. proxy_prefix .. "/portal/developer",
              headers = {
                ["Content-Type"] = "application/json",
                ["Authorization"] = "Basic " .. ngx.encode_base64("gruce@konghq.com:kong"),
              }
            })

            local body = assert.res_status(200, res)
            local resp_body_json = cjson.decode(body)
            local current_meta = resp_body_json.meta

            local new_meta = "{\"new_key\":\"not in current meta\"}"

            local res = assert(client:send {
              method = "PATCH",
              body = {
                meta = new_meta
              },
              path = "/" .. proxy_prefix .. "/portal/developer/meta",
              headers = {
                ["Content-Type"] = "application/json",
                ["Authorization"] = "Basic " .. ngx.encode_base64("gruce@konghq.com:kong"),
              }
            })

            assert.res_status(204, res)

            local res = assert(client:send {
              method = "GET",
              path = "/" .. proxy_prefix .. "/portal/developer",
              headers = {
                ["Content-Type"] = "application/json",
                ["Authorization"] = "Basic " .. ngx.encode_base64("gruce@konghq.com:kong"),
              }
            })

            local body = assert.res_status(200, res)
            local resp_body_json = cjson.decode(body)
            local new_meta = resp_body_json.meta

            assert.equal(new_meta, current_meta)
          end)
        end)
      end)

      describe("/_kong/portal/credentials ", function()
        local credential

        setup(function()
          helpers.stop_kong()
          assert(db:truncate())
          helpers.register_consumer_relations(dao)

          assert(helpers.start_kong({
            database   = strategy,
            portal     = true,
            rbac       = rbac,
            portal_auth = "basic-auth",
            portal_auth_config = "{ \"hide_credentials\": true }",
            portal_auto_approve = "on",
          }))

          consumer_approved = bp.consumers:insert {
            username = "hawk",
            type = enums.CONSUMERS.TYPE.DEVELOPER,
            status = enums.CONSUMERS.STATUS.APPROVED,
          }

          assert(dao.basicauth_credentials:insert {
            username    = "hawk",
            password    = "kong",
            consumer_id = consumer_approved.id,
          })
        end)

        before_each(function()
          client = assert(helpers.proxy_client())
        end)

        after_each(function()
          if client then
            client:close()
          end
        end)

        describe("POST", function()
          it("adds a credential to a developer - basic-auth", function()
            local res = assert(client:send {
              method = "POST",
              path = "/" .. proxy_prefix .. "/portal/credentials",
              body = {
                username = "kong",
                password = "hunter1"
              },
              headers = {
                ["Content-Type"] = "application/json",
                ["Authorization"] = "Basic " .. ngx.encode_base64("hawk:kong"),
              }
            })

            local body = assert.res_status(201, res)
            local resp_body_json = cjson.decode(body)

            credential = resp_body_json

            assert.equal("kong", credential.username)
            assert.are_not.equals("hunter1", credential.password)
            assert.is_true(utils.is_valid_uuid(credential.id))
          end)
        end)

        describe("PATCH", function()
          it("patches a credential - basic-auth", function()
            local res = assert(client:send {
              method = "PATCH",
              path = "/" .. proxy_prefix .. "/portal/credentials",
              body = {
                id = credential.id,
                username = "anotherone",
                password = "another-hunter1"
              },
              headers = {
                ["Content-Type"] = "application/json",
                ["Authorization"] = "Basic " .. ngx.encode_base64("hawk:kong"),
              }
            })

            local body = assert.res_status(200, res)
            local resp_body_json = cjson.decode(body)
            local credential_res = resp_body_json

            assert.equal("anotherone", credential_res.username)
            assert.are_not.equals(credential_res.username, credential.username)
            assert.are_not.equals("another-hunter1", credential_res.password)
            assert.is_true(utils.is_valid_uuid(credential_res.id))
          end)
        end)
      end)

      describe("/_kong/portal/credentials/:plugin ", function()
        local credential
        local credential_key_auth

        setup(function()
          helpers.stop_kong()
          assert(db:truncate())
          helpers.register_consumer_relations(dao)

          assert(helpers.start_kong({
            database   = strategy,
            portal     = true,
            rbac       = rbac,
            portal_auth = "basic-auth",
            portal_auth_config = "{ \"hide_credentials\": true }",
            portal_auto_approve = "on",
          }))

          consumer_approved = bp.consumers:insert {
            username = "hawk",
            type = enums.CONSUMERS.TYPE.DEVELOPER,
            status = enums.CONSUMERS.STATUS.APPROVED,
          }

          assert(dao.basicauth_credentials:insert {
            username    = "hawk",
            password    = "kong",
            consumer_id = consumer_approved.id,
          })
        end)

        before_each(function()
          client = assert(helpers.proxy_client())
        end)

        after_each(function()
          if client then
            client:close()
          end
        end)


        describe("POST", function()
          it("returns 404 if plugin is not one of the allowed auth plugins", function()
            local plugin = "awesome-custom-plugin"

            local res = assert(client:send {
              method = "POST",
              path = "/" .. proxy_prefix .. "/portal/credentials/" .. plugin,
              body = {
                username = "dude",
                password = "hunter1"
              },
              headers = {
                ["Content-Type"] = "application/json",
                ["Authorization"] = "Basic " .. ngx.encode_base64("hawk:kong"),
              }
            })

            assert.res_status(404, res)
          end)

          it("adds auth plugin credential - basic-auth", function()
            local plugin = "basic-auth"

            local res = assert(client:send {
              method = "POST",
              path = "/" .. proxy_prefix .. "/portal/credentials/" .. plugin,
              body = {
                username = "dude",
                password = "hunter1"
              },
              headers = {
                ["Content-Type"] = "application/json",
                ["Authorization"] = "Basic " .. ngx.encode_base64("hawk:kong"),
              }
            })

            local body = assert.res_status(201, res)
            local resp_body_json = cjson.decode(body)

            credential = resp_body_json

            assert.equal("dude", credential.username)
            assert.are_not.equals("hunter1", credential.password)
            assert.is_true(utils.is_valid_uuid(credential.id))
          end)

          it("adds auth plugin credential - key-auth", function()
            local plugin = "key-auth"

            local res = assert(client:send {
              method = "POST",
              path = "/" .. proxy_prefix .. "/portal/credentials/" .. plugin,
              body = {
                key = "letmein"
              },
              headers = {
                ["Content-Type"] = "application/json",
                ["Authorization"] = "Basic " .. ngx.encode_base64("hawk:kong"),
              }
            })

            local body = assert.res_status(201, res)
            local resp_body_json = cjson.decode(body)

            credential_key_auth = resp_body_json

            assert.equal("letmein", credential_key_auth.key)
            assert.is_true(utils.is_valid_uuid(credential_key_auth.id))
          end)
        end)

        describe("GET", function()
          it("returns 404 if plugin is not one of the allowed auth plugins", function()
            local plugin = "awesome-custom-plugin"
            local path = "/" .. proxy_prefix .. "/portal/credentials/"
                          .. plugin .. "/" .. credential.id

            local res = assert(client:send {
              method = "GET",
              path = path,
              headers = {
                ["Content-Type"] = "application/json",
                ["Authorization"] = "Basic " .. ngx.encode_base64("hawk:kong"),
              }
            })

            assert.res_status(404, res)
          end)

          it("retrieves a credential - basic-auth", function()
            local plugin = "basic-auth"
            local path = "/" .. proxy_prefix .. "/portal/credentials/"
                          .. plugin .. "/" .. credential.id

            local res = assert(client:send {
              method = "GET",
              path = path,
              headers = {
                ["Content-Type"] = "application/json",
                ["Authorization"] = "Basic " .. ngx.encode_base64("hawk:kong"),
              }
            })

            local body = assert.res_status(200, res)
            local resp_body_json = cjson.decode(body)
            local credential_res = resp_body_json

            assert.equal(credential.username, credential_res.username)
            assert.equal(credential.id, credential_res.id)
          end)
        end)

        describe("PATCH", function()
          it("returns 404 if plugin is not one of the allowed auth plugins", function()
            local plugin = "awesome-custom-plugin"
            local path = "/" .. proxy_prefix .. "/portal/credentials/"
                          .. plugin .. "/" .. credential.id

            local res = assert(client:send {
              method = "PATCH",
              path = path,
              body = {
                id = credential.id,
                username = "dudett",
                password = "a-new-password"
              },
              headers = {
                ["Content-Type"] = "application/json",
                ["Authorization"] = "Basic " .. ngx.encode_base64("hawk:kong"),
              }
            })

            assert.res_status(404, res)
          end)

          it("/_kong/portal/credentials/:plugin/ - basic-auth", function()
            local plugin = "basic-auth"
            local path = "/" .. proxy_prefix .. "/portal/credentials/"
                          .. plugin .. "/" .. credential.id

            local res = assert(client:send {
              method = "PATCH",
              path = path,
              body = {
                id = credential.id,
                username = "dudett",
                password = "a-new-password"
              },
              headers = {
                ["Content-Type"] = "application/json",
                ["Authorization"] = "Basic " .. ngx.encode_base64("hawk:kong"),
              }
            })

            local body = assert.res_status(200, res)
            local resp_body_json = cjson.decode(body)
            local credential_res = resp_body_json

            assert.equal("dudett", credential_res.username)
            assert.are_not.equals("a-new-password", credential_res.password)
            assert.is_true(utils.is_valid_uuid(credential_res.id))

            assert.are_not.equals(credential_res.username, credential.username)
          end)

          it("/_kong/portal/portal/credentials/:plugin/:credential_id - basic-auth", function()
            local plugin = "basic-auth"
            local path = "/" .. proxy_prefix .. "/portal/credentials/"
                          .. plugin .. "/" .. credential.id

            local res = assert(client:send {
              method = "PATCH",
              path = path,
              body = {
                username = "duderino",
                password = "a-new-new-password"
              },
              headers = {
                ["Content-Type"] = "application/json",
                ["Authorization"] = "Basic " .. ngx.encode_base64("hawk:kong"),
              }
            })

            local body = assert.res_status(200, res)
            local resp_body_json = cjson.decode(body)
            local credential_res = resp_body_json

            assert.equal("duderino", credential_res.username)
            assert.are_not.equals("a-new-new-password", credential_res.password)
            assert.is_true(utils.is_valid_uuid(credential_res.id))

            assert.are_not.equals(credential_res.username, credential.username)
          end)
        end)

        describe("DELETE", function()
          it("deletes a credential", function()
            local plugin = "key-auth"
            local path = "/" .. proxy_prefix .. "/portal/credentials/"
                          .. plugin .. "/" .. credential_key_auth.id

            local res = assert(client:send {
              method = "DELETE",
              path = path,
              headers = {
                ["Content-Type"] = "application/json",
                ["Authorization"] = "Basic " .. ngx.encode_base64("hawk:kong"),
              }
            })

            assert.res_status(204, res)

            local res = assert(client:send {
              method = "GET",
              path = path,
              headers = {
                ["Content-Type"] = "application/json",
                ["Authorization"] = "Basic " .. ngx.encode_base64("hawk:kong"),
              }
            })

            assert.res_status(404, res)
          end)
        end)

        describe("GET", function()
          it("retrieves the kong config tailored for the dev portal", function()
            local res = assert(client:send {
              method = "GET",
              path = "/" .. proxy_prefix .. "/portal/config",
              headers = {
                ["Content-Type"] = "application/json",
                ["Authorization"] = "Basic " .. ngx.encode_base64("hawk:kong"),
              }
            })

            local body = assert.res_status(200, res)
            local resp_body_json = cjson.decode(body)

            local config = resp_body_json

            assert.same({ "cors", "basic-auth" }, config.plugins.enabled_in_cluster)
          end)
        end)
      end)

      describe("Vitals off ", function()
        setup(function()
          helpers.stop_kong()
          assert(db:truncate())
          helpers.register_consumer_relations(dao)

          assert(helpers.start_kong({
            database   = strategy,
            portal     = true,
            vitals     = false,
            portal_auth = "basic-auth",
            rbac = rbac,
            portal_auth_config = "{ \"hide_credentials\": true }",
          }))

          consumer_approved = bp.consumers:insert {
            username = "hawk",
            type = enums.CONSUMERS.TYPE.DEVELOPER,
            status = enums.CONSUMERS.STATUS.APPROVED,
          }

          assert(dao.basicauth_credentials:insert {
            username    = "hawk",
            password    = "kong",
            consumer_id = consumer_approved.id,
          })
        end)

        before_each(function()
          client = assert(helpers.proxy_client())
        end)

        after_each(function()
          if client then
            client:close()
          end
        end)

        describe("/_kong/portal/vitals/status_codes/by_consumer", function()
          describe("GET", function()

            it("returns 404 when vitals if off", function()
              local res = assert(client:send {
                method = "GET",
                path = "/" .. proxy_prefix .. "/portal/vitals/status_codes/by_consumer",
                headers = {
                  ["Authorization"] = "Basic " .. ngx.encode_base64("hawk:kong"),
                },
              })

              assert.res_status(404, res)
            end)
          end)
        end)

        describe("/_kong/portal/vitals/status_codes/by_consumer_and_route", function()
          describe("GET", function()

            it("returns 404 when vitals if off", function()
              local res = assert(client:send {
                method = "GET",
                path = "/" .. proxy_prefix .. "/portal/vitals/status_codes/by_consumer_and_route",
                headers = {
                  ["Authorization"] = "Basic " .. ngx.encode_base64("hawk:kong"),
                },
              })

              assert.res_status(404, res)
            end)
          end)
        end)

        describe("/_kong/portal/vitals/consumers/cluster", function()
          describe("GET", function()

            it("returns 404 when vitals if off", function()
              local res = assert(client:send {
                method = "GET",
                path = "/" .. proxy_prefix .. "/portal/vitals/consumers/cluster",
                headers = {
                  ["Authorization"] = "Basic " .. ngx.encode_base64("hawk:kong"),
                },
              })

              assert.res_status(404, res)
            end)
          end)
        end)

        describe("/_kong/portal/vitals/consumers/nodes", function()
          describe("GET", function()

            it("returns 404 when vitals if off", function()
              local res = assert(client:send {
                method = "GET",
                path = "/" .. proxy_prefix .. "/portal/vitals/consumers/nodes",
                headers = {
                  ["Authorization"] = "Basic " .. ngx.encode_base64("hawk:kong"),
                },
              })

              assert.res_status(404, res)
            end)
          end)
        end)
      end)

      describe("Vitals on", function()
        setup(function()
          helpers.stop_kong()
          assert(db:truncate())
          helpers.register_consumer_relations(dao)

          assert(helpers.start_kong({
            database   = strategy,
            portal     = true,
            vitals     = true,
            portal_auth = "basic-auth",
            rbac = rbac,
            portal_auth_config = "{ \"hide_credentials\": true }",
          }))

          local consumer_pending = bp.consumers:insert {
            username = "dale",
            type = enums.CONSUMERS.TYPE.DEVELOPER,
            status = enums.CONSUMERS.STATUS.PENDING,
          }

          consumer_approved = bp.consumers:insert {
            username = "hawk",
            type = enums.CONSUMERS.TYPE.DEVELOPER,
            status = enums.CONSUMERS.STATUS.APPROVED,
          }

          assert(dao.basicauth_credentials:insert {
            username    = "dale",
            password    = "kong",
            consumer_id = consumer_pending.id,
          })

          assert(dao.basicauth_credentials:insert {
            username    = "hawk",
            password    = "kong",
            consumer_id = consumer_approved.id,
          })

        end)

        before_each(function()
          client = assert(helpers.proxy_client())
        end)

        after_each(function()
          if client then
            client:close()
          end
        end)

        describe("/_kong/portal/vitals/status_codes/by_consumer", function()
          describe("GET", function()
            it("returns 401 when unauthenticated", function()
              local res = assert(client:send {
                method = "GET",
                path = "/" .. proxy_prefix .. "/portal/vitals/status_codes/by_consumer",
              })

              assert.res_status(401, res)
            end)

            it("returns 401 when consumer is not approved", function()
              local res = assert(client:send {
                method = "GET",
                path = "/" .. proxy_prefix .. "/portal/vitals/status_codes/by_consumer",
                headers = {
                  ["Authorization"] = "Basic " .. ngx.encode_base64("dale:kong"),
                },
              })

              local body = assert.res_status(401, res)
              local json = cjson.decode(body)

              assert.same({ status = 1, label = "PENDING" }, json)
            end)

            it("returns 400 when requested with invalid interval query param", function()
              local res = assert(client:send {
                method = "GET",
                path = "/" .. proxy_prefix .. "/portal/vitals/status_codes/by_consumer",
                query = {
                  interval = "derp",
                },
                headers = {
                  ["Authorization"] = "Basic " .. ngx.encode_base64("hawk:kong"),
                },
              })

              local body = assert.res_status(400, res)
              local json = cjson.decode(body)

              assert.same({
                message = "Invalid query params: interval must be 'minutes' or 'seconds'",
              }, json)
            end)

            it("returns seconds data", function()
              local res = assert(client:send {
                method = "GET",
                path = "/" .. proxy_prefix .. "/portal/vitals/status_codes/by_consumer",
                query = {
                  interval = "seconds",
                },
                headers = {
                  ["Authorization"] = "Basic " .. ngx.encode_base64("hawk:kong"),
                },
              })

              local body = assert.res_status(200, res)
              local json = cjson.decode(body)

              assert.same({
                meta = {
                  entity_id   = consumer_approved.id,
                  entity_type = "consumer",
                  interval    = "seconds",
                  level       = "cluster",
                  stat_labels = { "status_codes_per_consumer_total" },
                },
                stats = {},
              }, json)
            end)

            it("returns minutes data", function()
              local res = assert(client:send {
                method = "GET",
                path = "/" .. proxy_prefix .. "/portal/vitals/status_codes/by_consumer",
                query = {
                  interval = "minutes",
                },
                headers = {
                  ["Authorization"] = "Basic " .. ngx.encode_base64("hawk:kong"),
                },
              })

              local body = assert.res_status(200, res)
              local json = cjson.decode(body)

              assert.same({
                meta = {
                  entity_id   = consumer_approved.id,
                  entity_type = "consumer",
                  interval    = "minutes",
                  level       = "cluster",
                  stat_labels = { "status_codes_per_consumer_total" },
                },
                stats = {},
              }, json)
            end)
          end)
        end)

        describe("/_kong/portal/vitals/status_codes/by_consumer_and_route", function()
          describe("GET", function()
            it("returns 401 when unauthenticated", function()
              local res = assert(client:send {
                method = "GET",
                path = "/" .. proxy_prefix .. "/portal/vitals/status_codes/by_consumer_and_route",
              })

              assert.res_status(401, res)
            end)

            it("returns 401 when consumer is not approved", function()
              local res = assert(client:send {
                method = "GET",
                path = "/" .. proxy_prefix .. "/portal/vitals/status_codes/by_consumer_and_route",
                headers = {
                  ["Authorization"] = "Basic " .. ngx.encode_base64("dale:kong"),
                },
              })

              local body = assert.res_status(401, res)
              local json = cjson.decode(body)

              assert.same({ status = 1, label = "PENDING" }, json)
            end)

            it("returns 400 when requested with invalid interval query param", function()
              local res = assert(client:send {
                method = "GET",
                path = "/" .. proxy_prefix .. "/portal/vitals/status_codes/by_consumer_and_route",
                query = {
                  interval = "derp",
                },
                headers = {
                  ["Authorization"] = "Basic " .. ngx.encode_base64("hawk:kong"),
                },
              })

              local body = assert.res_status(400, res)
              local json = cjson.decode(body)

              assert.same({
                message = "Invalid query params: interval must be 'minutes' or 'seconds'",
              }, json)
            end)

            it("returns seconds data", function()
              local res = assert(client:send {
                method = "GET",
                path = "/" .. proxy_prefix .. "/portal/vitals/status_codes/by_consumer_and_route",
                query = {
                  interval = "seconds",
                },
                headers = {
                  ["Authorization"] = "Basic " .. ngx.encode_base64("hawk:kong"),
                },
              })

              local body = assert.res_status(200, res)
              local json = cjson.decode(body)

              assert.same({
                meta = {
                  entity_id   = consumer_approved.id,
                  entity_type = "consumer_route",
                  interval    = "seconds",
                  level       = "cluster",
                  stat_labels = { "status_codes_per_consumer_route_total" },
                },
                stats = {},
              }, json)
            end)

            it("returns minutes data", function()
              local res = assert(client:send {
                method = "GET",
                path = "/" .. proxy_prefix .. "/portal/vitals/status_codes/by_consumer_and_route",
                query = {
                  interval = "minutes",
                },
                headers = {
                  ["Authorization"] = "Basic " .. ngx.encode_base64("hawk:kong"),
                },
              })

              local body = assert.res_status(200, res)
              local json = cjson.decode(body)

              assert.same({
                meta = {
                  entity_id   = consumer_approved.id,
                  entity_type = "consumer_route",
                  interval    = "minutes",
                  level       = "cluster",
                  stat_labels = { "status_codes_per_consumer_route_total" },
                },
                stats = {},
              }, json)
            end)
          end)
        end)

        describe("/_kong/portal/vitals/consumers/cluster", function()
          describe("GET", function()
            it("returns 401 when unauthenticated", function()
              local res = assert(client:send {
                method = "GET",
                path = "/" .. proxy_prefix .. "/portal/vitals/consumers/cluster",
              })

              assert.res_status(401, res)
            end)

            it("returns 401 when consumer is not approved", function()
              local res = assert(client:send {
                method = "GET",
                path = "/" .. proxy_prefix .. "/portal/vitals/consumers/cluster",
                headers = {
                  ["Authorization"] = "Basic " .. ngx.encode_base64("dale:kong"),
                },
              })

              local body = assert.res_status(401, res)
              local json = cjson.decode(body)
              assert.same({ status = 1, label = "PENDING" }, json)
            end)

            it("returns 400 when requested with invalid interval query param", function()
              local res = assert(client:send {
                method = "GET",
                path = "/" .. proxy_prefix .. "/portal/vitals/consumers/cluster",
                query = {
                  interval = "derp",
                },
                headers = {
                  ["Authorization"] = "Basic " .. ngx.encode_base64("hawk:kong"),
                },
              })

              local body = assert.res_status(400, res)
              local json = cjson.decode(body)

              assert.same({
                message = "Invalid query params: interval must be 'minutes' or 'seconds'",
              }, json)
            end)

            it("returns seconds data", function()
              local res = assert(client:send {
                method = "GET",
                path = "/" .. proxy_prefix .. "/portal/vitals/consumers/cluster",
                query = {
                  interval = "seconds",
                },
                headers = {
                  ["Authorization"] = "Basic " .. ngx.encode_base64("hawk:kong"),
                },
              })

              local body = assert.res_status(200, res)
              local json = cjson.decode(body)

              assert.same({
                meta = {
                  interval    = "seconds",
                  level       = "cluster",
                },
                stats = {},
              }, json)
            end)

            it("returns minutes data", function()
              local res = assert(client:send {
                method = "GET",
                path = "/" .. proxy_prefix .. "/portal/vitals/consumers/cluster",
                query = {
                  interval = "minutes",
                },
                headers = {
                  ["Authorization"] = "Basic " .. ngx.encode_base64("hawk:kong"),
                },
              })

              local body = assert.res_status(200, res)
              local json = cjson.decode(body)

              assert.same({
                meta = {
                  interval    = "minutes",
                  level       = "cluster",
                },
                stats = {},
              }, json)

            end)
          end)
        end)

      end)
    end)
  end
end

pending("portal dao_helpers", function()
  local dao

  setup(function()
    dao = select(3, helpers.get_db_utils("cassandra"))

    local cassandra = require "kong.dao.db.cassandra"
    local dao_cassandra = cassandra.new(helpers.test_conf)

    -- raw cassandra insert without dao so "type" is nil
    for i = 1, 10 do
      local query = string.format([[INSERT INTO %s.consumers
                                                (id, custom_id)
                                                VALUES(%s, '%s')]],
                                  helpers.test_conf.cassandra_keyspace,
                                  utils.uuid(),
                                  "cassy-" .. i)
      dao_cassandra:query(query)
    end

    local rows = dao.consumers:find_all()

    assert.equals(10, #rows)
    for _, row in ipairs(rows) do
      assert.is_nil(row.type)
    end

  end)

  teardown(function()
    helpers.stop_kong()
  end)

  it("updates consumers with nil type to default proxy type", function()
    local portal = require "kong.portal.dao_helpers"
    portal.update_consumers(dao, enums.CONSUMERS.TYPE.PROXY)

    local rows = dao.consumers:find_all()
    for _, row in ipairs(rows) do
      assert.equals(enums.CONSUMERS.TYPE.PROXY, row.type)
    end
    assert.equals(10, #rows)
  end)
end)
