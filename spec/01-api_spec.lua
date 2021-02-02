-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local cjson   = require "cjson"
local helpers = require "spec.helpers"
local utils = require "kong.tools.utils"


for _, strategy in helpers.each_strategy() do
  describe("Plugin: key-auth-enc (API) [#" .. strategy .. "]", function()
    local consumer
    local admin_client
    local bp
    local db
    local route1
    local route2

    lazy_setup(function()
      bp, db = helpers.get_db_utils(strategy, {
        "routes",
        "services",
        "plugins",
        "consumers",
        "keyauth_enc_credentials"},
        {"key-auth-enc"})

      route1 = bp.routes:insert {
        hosts = { "keyauth1.test" },
      }

      route2 = bp.routes:insert {
        hosts = { "keyauth2.test" },
      }

      consumer = bp.consumers:insert({
        username = "bob"
      }, { nulls = true })

      assert(helpers.start_kong({
        database = strategy,
        plugins = "key-auth-enc",
        nginx_conf = "spec/fixtures/custom_nginx.template",
      }))
    end)

    before_each(function ()
      admin_client = helpers.admin_client()
    end)

    lazy_teardown(function()
      if admin_client then
        admin_client:close()
      end

      helpers.stop_kong()
    end)

    describe("/consumers/:consumer/key-auth-enc", function()
      describe("POST", function()
        after_each(function()
          db:truncate("keyauth_enc_credentials")
        end)
        it("creates a key-auth-enc credential with key", function()
          local res = assert(admin_client:send {
            method  = "POST",
            path    = "/consumers/bob/key-auth-enc",
            body    = {
              key   = "1234"
            },
            headers = {
              ["Content-Type"] = "application/json"
            }
          })
          local body = assert.res_status(201, res)
          local json = cjson.decode(body)
          assert.equal(consumer.id, json.consumer.id)
          assert.equal("1234", json.key)
        end)
        it("creates a key-auth-enc auto-generating a unique key", function()
          local res = assert(admin_client:send {
            method  = "POST",
            path    = "/consumers/bob/key-auth-enc",
            body    = {},
            headers = {
              ["Content-Type"] = "application/json"
            }
          })
          local body = assert.res_status(201, res)
          local json = cjson.decode(body)
          assert.equal(consumer.id, json.consumer.id)
          assert.is_string(json.key)

          local first_key = json.key
          db:truncate("keyauth_enc_credentials")

          local res = assert(admin_client:send {
            method  = "POST",
            path    = "/consumers/bob/key-auth-enc",
            body    = {},
            headers = {
              ["Content-Type"] = "application/json"
            }
          })
          local body = assert.res_status(201, res)
          local json = cjson.decode(body)
          assert.equal(consumer.id, json.consumer.id)
          assert.is_string(json.key)

          assert.not_equal(first_key, json.key)
        end)
      end)

      describe("GET", function()
        lazy_setup(function()
          for i = 1, 3 do
            assert(bp.keyauth_enc_credentials:insert {
              consumer = { id = consumer.id }
            })
          end
        end)
        lazy_teardown(function()
          db:truncate("keyauth_enc_credentials")
        end)
        it("retrieves the first page", function()
          local res = assert(admin_client:send {
            method  = "GET",
            path    = "/consumers/bob/key-auth-enc"
          })
          local body = assert.res_status(200, res)
          local json = cjson.decode(body)
          assert.is_table(json.data)
          assert.equal(3, #json.data)
        end)
      end)
    end)

    describe("/consumers/:consumer/key-auth-enc/:id", function()
      local credential
      before_each(function()
        db:truncate("keyauth_enc_credentials")
        credential = bp.keyauth_enc_credentials:insert {
          consumer = { id = consumer.id },
        }
      end)
      describe("GET", function()
        it("retrieves key-auth-enc credential by id", function()
          local res = assert(admin_client:send {
            method  = "GET",
            path    = "/consumers/bob/key-auth-enc/" .. credential.id
          })
          local body = assert.res_status(200, res)
          local json = cjson.decode(body)
          assert.equal(credential.id, json.id)
        end)
        it("retrieves key-auth-enc credential by key", function()
          local res = assert(admin_client:send {
            method  = "GET",
            path    = "/consumers/bob/key-auth-enc/" .. credential.key
          })
          local body = assert.res_status(200, res)
          local json = cjson.decode(body)
          assert.equal(credential.id, json.id)
        end)
        it("retrieves credential by id only if the credential belongs to the specified consumer", function()
          assert(bp.consumers:insert {
            username = "alice"
          })

          local res = assert(admin_client:send {
            method  = "GET",
            path    = "/consumers/bob/key-auth-enc/" .. credential.id
          })
          assert.res_status(200, res)

          res = assert(admin_client:send {
            method = "GET",
            path   = "/consumers/alice/key-auth-enc/" .. credential.id
          })
          assert.res_status(404, res)
        end)
      end)

      describe("PUT", function()
        after_each(function()
          db:truncate("keyauth_enc_credentials")
        end)
        it("creates a key-auth-enc credential with key", function()
          local res = assert(admin_client:send {
            method  = "PUT",
            path    = "/consumers/bob/key-auth-enc/1234",
            body    = {},
            headers = {
              ["Content-Type"] = "application/json"
            }
          })
          local body = assert.res_status(200, res)
          local json = cjson.decode(body)
          assert.equal(consumer.id, json.consumer.id)
          assert.equal("1234", json.key)
        end)
        it("creates a key-auth-enc credential auto-generating the key", function()
          local res = assert(admin_client:send {
            method  = "PUT",
            path    = "/consumers/bob/key-auth-enc/c16bbff7-5d0d-4a28-8127-1ee581898f11",
            body    = {},
            headers = {
              ["Content-Type"] = "application/json"
            }
          })
          local body = assert.res_status(200, res)
          local json = cjson.decode(body)
          assert.equal(consumer.id, json.consumer.id)
          assert.is_string(json.key)
        end)
      end)

      describe("PATCH", function()
        it("updates a credential by id", function()
          local res = assert(admin_client:send {
            method  = "PATCH",
            path    = "/consumers/bob/key-auth-enc/" .. credential.id,
            body    = { key = "4321" },
            headers = {
              ["Content-Type"] = "application/json"
            }
          })
          local body = assert.res_status(200, res)
          local json = cjson.decode(body)
          assert.equal("4321", json.key)
        end)
        it("updates a credential by key", function()
          local res = assert(admin_client:send {
            method  = "PATCH",
            path    = "/consumers/bob/key-auth-enc/" .. credential.key,
            body    = { key = "4321UPD" },
            headers = {
              ["Content-Type"] = "application/json"
            }
          })
          local body = assert.res_status(200, res)
          local json = cjson.decode(body)
          assert.equal("4321UPD", json.key)
        end)
        describe("errors", function()
          it("handles invalid input", function()
            local res = assert(admin_client:send {
              method  = "PATCH",
              path    = "/consumers/bob/key-auth-enc/" .. credential.id,
              body    = { key = 123 },
              headers = {
                ["Content-Type"] = "application/json"
              }
            })
            local body = assert.res_status(400, res)
            local json = cjson.decode(body)
            assert.same({ key = "expected a string" }, json.fields)
          end)
        end)
      end)

      describe("DELETE", function()
        it("deletes a credential", function()
          local res = assert(admin_client:send {
            method  = "DELETE",
            path    = "/consumers/bob/key-auth-enc/" .. credential.id,
          })
          assert.res_status(204, res)
        end)
        describe("errors", function()
          it("returns 400 on invalid input", function()
            local res = assert(admin_client:send {
              method  = "DELETE",
              path    = "/consumers/bob/key-auth-enc/blah"
            })
            assert.res_status(404, res)
          end)
          it("returns 404 if not found", function()
            local res = assert(admin_client:send {
              method  = "DELETE",
              path    = "/consumers/bob/key-auth-enc/00000000-0000-0000-0000-000000000000"
            })
            assert.res_status(404, res)
          end)
        end)
      end)
    end)
    describe("/plugins for route", function()
      it("fails with invalid key_names", function()
        local key_name = "hello\\world"
        local res = assert(admin_client:send {
          method  = "POST",
          path    = "/plugins",
          body    = {
            name  = "key-auth-enc",
            route = { id = route1.id },
            config     = {
              key_names = {key_name},
            },
          },
          headers = {
            ["Content-Type"] = "application/json"
          }
        })
        assert.response(res).has.status(400)
        local body = assert.response(res).has.jsonbody()
        assert.equal("bad header name 'hello\\world', allowed characters are A-Z, a-z, 0-9, '_', and '-'",
                     body.fields.config.key_names[1])
      end)
      it("succeeds with valid key_names", function()
        local key_name = "hello-world"
        local res = assert(admin_client:send {
          method  = "POST",
          path    = "/plugins",
          body    = {
            route = { id = route2.id },
            name       = "key-auth-enc",
            config     = {
              key_names = {key_name},
            },
          },
          headers = {
            ["Content-Type"] = "application/json"
          }
        })
        assert.response(res).has.status(201)
        local body = assert.response(res).has.jsonbody()
        assert.equal(key_name, body.config.key_names[1])
      end)
    end)
    describe("/key-auths-enc", function()
      local consumer2

      describe("GET", function()
        lazy_setup(function()
          db:truncate("keyauth_enc_credentials")
          db:truncate("consumers")
          consumer = bp.consumers:insert({
            username = "bob"
          }, { nulls = true })
          for i = 1, 3 do
            bp.keyauth_enc_credentials:insert {
              consumer = { id = consumer.id },
            }
          end

          consumer2 = bp.consumers:insert {
            username = "bob-the-buidler",
          }

          for i = 1, 3 do
            bp.keyauth_enc_credentials:insert {
              consumer = { id = consumer2.id },
            }
          end
        end)

        it("retrieves all the key-auths-enc with trailing slash", function()
          local res = assert(admin_client:send {
            method = "GET",
            path = "/key-auths-enc/",
          })
          local body = assert.res_status(200, res)
          local json = cjson.decode(body)
          assert.is_table(json.data)
          assert.equal(6, #json.data)
        end)
        it("retrieves all the key-auths-enc without trailing slash", function()
          local res = assert(admin_client:send {
            method = "GET",
            path = "/key-auths-enc",
          })
          local body = assert.res_status(200, res)
          local json = cjson.decode(body)
          assert.is_table(json.data)
          assert.equal(6, #json.data)
        end)
        it("paginates through the key-auths-enc", function()
          local res = assert(admin_client:send {
            method = "GET",
            path = "/key-auths-enc?size=3",
          })
          local body = assert.res_status(200, res)
          local json_1 = cjson.decode(body)
          assert.is_table(json_1.data)
          assert.equal(3, #json_1.data)

          res = assert(admin_client:send {
            method = "GET",
            path = "/key-auths-enc",
            query = {
              size = 3,
              offset = json_1.offset,
            }
          })
          body = assert.res_status(200, res)
          local json_2 = cjson.decode(body)
          assert.is_table(json_2.data)
          assert.equal(3, #json_2.data)

          assert.not_same(json_1.data, json_2.data)
          -- Disabled: on Cassandra, the last page still returns a
          -- next_page token, and thus, an offset proprty in the
          -- response of the Admin API.
          --assert.is_nil(json_2.offset) -- last page
        end)
      end)

      describe("POST", function()
        lazy_setup(function()
          db:truncate("keyauth_enc_credentials")
        end)

        it("does not create key-auth-enc credential when missing consumer", function()
          local res = assert(admin_client:send {
            method = "POST",
            path = "/key-auths-enc",
            body = {
              key = "1234",
            },
            headers = {
              ["Content-Type"] = "application/json"
            }
          })
          local body = assert.res_status(400, res)
          local json = cjson.decode(body)
          assert.same("schema violation (consumer: required field missing)", json.message)
        end)

        it("creates key-auth-enc credential", function()
          local res = assert(admin_client:send {
            method = "POST",
            path = "/key-auths-enc",
            body = {
              key = "1234",
              consumer = {
                id = consumer.id
              }
            },
            headers = {
              ["Content-Type"] = "application/json"
            }
          })
          local body = assert.res_status(201, res)
          local json = cjson.decode(body)
          assert.equal("1234", json.key)
        end)
      end)
    end)

    describe("/key-auths-enc/:credential_key_or_id", function()
      describe("PUT", function()
        lazy_setup(function()
          db:truncate("keyauth_enc_credentials")
        end)

        it("does not create key-auth-enc credential when missing consumer", function()
          local res = assert(admin_client:send {
            method = "PUT",
            path = "/key-auths-enc/1234",
            body = { },
            headers = {
              ["Content-Type"] = "application/json"
            }
          })
          local body = assert.res_status(400, res)
          local json = cjson.decode(body)
          assert.same("schema violation (consumer: required field missing)", json.message)
        end)

        it("creates key-auth-enc credential", function()
          local res = assert(admin_client:send {
            method = "PUT",
            path = "/key-auths-enc/1234",
            body = {
              consumer = {
                id = consumer.id
              }
            },
            headers = {
              ["Content-Type"] = "application/json"
            }
          })
          local body = assert.res_status(200, res)
          local json = cjson.decode(body)
          assert.equal("1234", json.key)
        end)
      end)
    end)

    describe("/key-auths-enc/:credential_key_or_id/consumer", function()
      describe("GET", function()
        local credential

        lazy_setup(function()
          db:truncate("keyauth_enc_credentials")
          credential = bp.keyauth_enc_credentials:insert {
            consumer = { id = consumer.id },
          }
        end)

        it("retrieve Consumer from a credential's id", function()
          local res = assert(admin_client:send {
            method = "GET",
            path = "/key-auths-enc/" .. credential.id .. "/consumer"
          })
          local body = assert.res_status(200, res)
          local json = cjson.decode(body)
          assert.same(consumer, json)
        end)
        it("retrieve a Consumer from a credential's key", function()
          local res = assert(admin_client:send {
            method = "GET",
            path = "/key-auths-enc/" .. credential.key .. "/consumer"
          })
          local body = assert.res_status(200, res)
          local json = cjson.decode(body)
          assert.same(consumer, json)
        end)
        it("returns 404 for a random non-existing id", function()
          local res = assert(admin_client:send {
            method = "GET",
            path = "/key-auths-enc/" .. utils.uuid()  .. "/consumer"
          })
          assert.res_status(404, res)
        end)
        it("returns 404 for a random non-existing key", function()
          local res = assert(admin_client:send {
            method = "GET",
            path = "/key-auths-enc/" .. utils.random_string()  .. "/consumer"
          })
          assert.res_status(404, res)
        end)
      end)
    end)
  end)
end