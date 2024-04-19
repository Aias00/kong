-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local helpers = require "spec.helpers"
local clear_license_env = require("spec-ee.helpers").clear_license_env

local function client_send(req)
  local client = helpers.http_client("127.0.0.1", 10001, 20000)
  local res = assert(client:send(req))
  local status, body = res.status, res:read_body()
  client:close()
  return status, body
end

for _, strategy in helpers.each_strategy() do
  describe("DP privileged agent publish event hooks during init_worker, strategy#" .. strategy, function()
    local db
    local valid_license

    lazy_setup(function()
      clear_license_env()

      local f = assert(io.open("spec-ee/fixtures/mock_license.json"))
      valid_license = f:read("*a")
      f:close()

      helpers.test_conf.lua_package_path = helpers.test_conf.lua_package_path .. ";./spec-ee/fixtures/custom_plugins/?.lua"

      local bp
      bp, db = helpers.get_db_utils(strategy, {
        "routes",
        "services",
        "plugins",
        "clustering_data_planes",
        "event_hooks"
      }, {"event-hooks-tester"})

      local service = assert(bp.services:insert {
        name = "mock-service",
        host = helpers.mock_upstream_host,
        port = helpers.mock_upstream_port,
      })

      local route = assert(bp.routes:insert {
        protocols = { "http" },
        hosts = { "test" },
        service = service,
      })

      assert(bp.plugins:insert {
        name = "event-hooks-tester",
        route = { id = route.id },
        config = {
        },
      })

      local fixtures = {
        http_mock = {
          webhook_site = [[
            server {
              listen 10001;
              location /webhook {
                content_by_lua_block {
                  local webhook_hit_counter = ngx.shared.webhook_hit_counter
                  ngx.req.read_body()
                  local body_data = ngx.req.get_body_data()
                  local cjson_decode = require("cjson").decode
                  local body = cjson_decode(body_data)
                  if body.operation == "create" then
                    ngx.status = 200
                  elseif body.operation == "delete" then
                    ngx.status = 204
                  else
                    local new_val, err = webhook_hit_counter:incr("hits", 1, 0)
                    if not new_val then
                      ngx.log(ngx.ERR, "failed to increment webhook hit counter: ", err)
                    end
                    ngx.status = 200
                  end
                }
              }
              location /hits {
                content_by_lua_block {
                  local webhook_hit_counter = ngx.shared.webhook_hit_counter
                  local hits = webhook_hit_counter:get("hits")
                  ngx.status = 200
                  if not hits then
                    ngx.say(0)
                  else
                    ngx.say(hits)
                  end
                }
              }
            }
          ]]
        },
      }

      assert(helpers.start_kong({
        role = "control_plane",
        cluster_cert = "spec/fixtures/kong_clustering.crt",
        cluster_cert_key = "spec/fixtures/kong_clustering.key",
        lua_ssl_trusted_certificate = "spec/fixtures/kong_clustering.crt",
        database = strategy,
        db_update_frequency = 0.1,
        cluster_listen = "127.0.0.1:9005",
        nginx_conf = "spec/fixtures/custom_nginx.template",
        plugins = "bundled," .. "event-hooks-tester",
        log_level = "info",
      }))

      assert(helpers.start_kong({
        role = "data_plane",
        database = "off",
        prefix = "servroot2",
        cluster_cert = "spec/fixtures/kong_clustering.crt",
        cluster_cert_key = "spec/fixtures/kong_clustering.key",
        lua_ssl_trusted_certificate = "spec/fixtures/kong_clustering.crt",
        cluster_control_plane = "127.0.0.1:9005",
        proxy_listen = "0.0.0.0:9002",
        nginx_conf = "spec/fixtures/custom_nginx.template",
        plugins = "bundled," .. "event-hooks-tester",
        log_level = "info",
        nginx_http_lua_shared_dict = "webhook_hit_counter 1m",
        nginx_worker_processes = 4,
      }, nil, nil, fixtures))
    end)

    lazy_teardown(function()
      helpers.stop_kong("servroot2")
      helpers.stop_kong("servroot")
    end)

    local admin_client, proxy_client
    before_each(function()
      admin_client = helpers.admin_client()
      proxy_client = helpers.proxy_client(nil, 9002)
    end)

    after_each(function()
      if admin_client then
        admin_client:close()
      end
      if proxy_client then
        proxy_client:close()
      end
    end)

    it("trigger event and webhook receive message", function()
      db:truncate("licenses")

      local res = admin_client:post("/event-hooks", {
        body = {
            source = "foo",
            event = "bar",
            handler = "webhook",
            config = {
              url = "http://127.0.0.1:10001/webhook",
            }
          },
          headers = { ["Content-Type"] = "application/json" },
        })
        assert.res_status(201, res)

        -- wait for DP receive the event-hooks create event
        ngx.sleep(1)

        local res = assert(admin_client:send {
          method = "POST",
          path = "/licenses",
          headers = {
            ["Content-Type"] = "application/json",
          },
          body = { payload = valid_license },
        })
        assert.res_status(201, res)

        ngx.sleep(1)

        -- make a request to trigger the event
        local res = assert(proxy_client:send {
          method = "GET",
          path = "/get",
          headers = {
            host = "test",
          }
        })

        assert.res_status(200, res)

        ngx.sleep(1)

        helpers.wait_until(function()
          local status, body = client_send({
            method = "GET",
            path = "/hits",
          })
          assert.equal(200, status)
          local hits = tonumber(body)
          return assert(hits == 1, "hits: " .. hits)
        end, 10)
    end)

    it("emit fail", function()
      local event_hooks    = require "kong.enterprise_edition.event_hooks"
      local ok, err = event_hooks.emit("dog", "cat", {
        msg = "msg"
      }, true)

      assert.is_nil(ok)
      assert.equal("source 'dog' is not registered", err)

      local event_hooks    = require "kong.enterprise_edition.event_hooks"
      local ok, err = event_hooks.emit("dog", "cat", {
        msg = "msg"
      })

      assert.is_nil(ok)
      assert.equal("source 'dog' is not registered", err)
    end)
  end)
end
