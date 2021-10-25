-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local helpers = require "spec.helpers"
local cjson   = require "cjson"
local pl_file = require "pl.file"
local meta    = require "kong.meta"


local server_header = meta._SERVER_TOKENS
local strategies = helpers.all_strategies ~= nil and helpers.all_strategies or helpers.each_strategy

for _, strategy in strategies() do
  describe("forward-proxy access (#" .. strategy .. ")", function()
    local client, bp, db
    local db_strategy = strategy ~= "off" and strategy or nil

    setup(function()
      bp, db = helpers.get_db_utils(db_strategy, nil, {"forward-proxy"})

      local service = db.services:insert {
        name = "service-1",
        host = "example.com",
        protocol = "http",
        port = 80,
      }

      local route1 = db.routes:insert {
        hosts = { "service-1.com" },
        service   = service,
      }

      bp.plugins:insert {
        route = { id = route1.id },
        name   = "forward-proxy",
        config = {
          proxy_host = helpers.mock_upstream_host,
          proxy_port = helpers.mock_upstream_port,
        },
      }

      local service2 = db.services:insert {
        name = "service-2",
        host = "dne.com",
        protocol = "http",
        port = 80,
      }

      local route2 = db.routes:insert {
        hosts = { "service-2.com" },
        service   = service2,
      }

      bp.plugins:insert {
        route = { id = route2.id },
        name   = "forward-proxy",
        config = {
          proxy_host = helpers.mock_upstream_host,
          proxy_port = helpers.mock_upstream_port -1,
        },
      }

      local service3 = db.services:insert {
        name = "service-3",
        host = "example.com",
        protocol = "http",
        port = 8090,
      }

      local route3 = db.routes:insert {
        hosts = { "service-3.com" },
        service   = service3,
      }

      bp.plugins:insert {
        route = { id = route3.id },
        name   = "forward-proxy",
        config = {
          proxy_host = helpers.mock_upstream_host,
          proxy_port = helpers.mock_upstream_port,
        },
      }

      assert(helpers.start_kong({
        database = db_strategy,
        plugins = "forward-proxy",
        nginx_conf     = "spec/fixtures/custom_nginx.template",
      }))

      client = helpers.proxy_client()
    end)

    teardown(function()
      if client then
        client:close()
      end

      helpers.stop_kong(nil, true)
    end)

    before_each(function()
      client = helpers.proxy_client()
    end)

    after_each(function()
      if client then
        client:close()
      end
    end)

    it("redirects a request", function()
      local res = assert(client:send {
        method  = "GET",
        path    = "/get",
        headers = {
          host = "service-1.com",
        },
      })

      assert.res_status(200, res)
    end)

    it("writes an absolute request URI to the proxy", function()
      local res = assert(client:send {
        method  = "GET",
        path    = "/get",
        headers = {
          host = "service-1.com",
        },
      })

      local body = assert.res_status(200, res)
      local json = cjson.decode(body)

      assert.same("GET http://example.com/get HTTP/1.1",
        json.vars.request, nil, true)
    end)

    it("includes non-standard port in to the proxy", function()
      local res = assert(client:send {
        method  = "GET",
        path    = "/get",
        headers = {
          host = "service-3.com",
        },
      })

      local body = assert.res_status(200, res)
      local json = cjson.decode(body)

      assert.same("GET http://example.com:8090/get HTTP/1.1",
        json.vars.request, nil, true)
    end)

    it("sends the lua-resty-http UA by default", function()
      local res = assert(client:send {
        method  = "GET",
        path    = "/get",
        headers = {
          host = "service-1.com",
        },
      })

      local body = assert.res_status(200, res)
      local json = cjson.decode(body)

      assert.matches("lua-resty-http", json.headers["user-agent"], nil, true)
    end)

    it("forwards query params and request body data", function()
      local res = assert(client:send {
        method  = "POST",
        path    = "/post?baz=bat",
        headers = {
          host = "service-1.com",
          ["Content-Type"] = "application/json",
        },
        body = {
          foo = "bar"
        },
      })

      local body = assert.res_status(200, res)
      local json = cjson.decode(body)

      assert.same(json.uri_args, { baz = "bat" })
      assert.same(json.post_data.params, { foo = "bar" })
    end)

    it("forwards query params and request body data (chunked transfer)", function()
      local res = assert(client:send {
        method  = "POST",
        path    = "/post?baz=bat",
        headers = {
          host = "service-1.com",
          ["Content-Type"] = "text/plain",
          ["Transfer-Encoding"] = "chunked",
        },
        body = "4\r\nKong\r\n0\r\n\r\n",
      })

      local body = assert.res_status(200, res)
      local json = cjson.decode(body)

      assert.same(json.uri_args, { baz = "bat" })
      assert.same(json.post_data.text, "Kong")
    end)

    it("errors on connection failure", function()
      local res = assert(client:send {
        method  = "GET",
        path    = "/get",
        headers = {
          host = "service-2.com",
        },
      })

      assert.res_status(500, res)

      local err_log = pl_file.read(helpers.test_conf.nginx_err_logs)
      assert.matches("failed to connect to proxy: ", err_log, nil, true)
    end)

    describe("forwards X-Forwarded-* headers upstream", function()
      describe("non-trusted client", function()
        lazy_setup(function()
          if client then
            client:close()
          end
          helpers.stop_kong(nil, true, true)

          assert(helpers.start_kong({
            database = db_strategy,
            plugins = "forward-proxy",
            nginx_conf = "spec/fixtures/custom_nginx.template",
            trusted_ips = "",
          }))

          client = helpers.proxy_client()
        end)

        lazy_teardown(function()
          if client then
            client:close()
          end
          helpers.stop_kong(nil, true, true)

          assert(helpers.start_kong({
            database = db_strategy,
            plugins = "forward-proxy",
            nginx_conf     = "spec/fixtures/custom_nginx.template",
          }))

          client = helpers.proxy_client()
        end)

        it("no client X-Forwarded-* headers", function()
          local res = assert(client:send {
            method  = "GET",
            path    = "/request",
            headers = {
              host = "service-1.com",
            },
          })

          local body = assert.res_status(200, res)
          local json = cjson.decode(body)
          assert.equal("service-1.com", json.headers["x-forwarded-host"])
          assert.equal("9000", json.headers["x-forwarded-port"])
          assert.equal("http", json.headers["x-forwarded-proto"])
          assert.equal("127.0.0.1", json.headers["x-forwarded-for"])
          assert.equal("127.0.0.1", json.headers["x-real-ip"])
        end)

        it("with client X-Forwarded-* headers", function()
          local res = assert(client:send {
            method  = "GET",
            path    = "/request",
            headers = {
              host = "service-1.com",
              ["X-Real-IP"] = "10.0.0.1",
              ["X-Forwarded-For"] = "10.0.0.1",
              ["X-Forwarded-Host"] = "example.com",
              ["X-Forwarded-Proto"] = "https",
              ["X-Forwarded-Port"] = "443",
            },
          })

          local body = assert.res_status(200, res)
          local json = cjson.decode(body)
          assert.equal("service-1.com", json.headers["x-forwarded-host"])
          assert.equal("9000", json.headers["x-forwarded-port"])
          assert.equal("http", json.headers["x-forwarded-proto"])
          assert.equal("10.0.0.1, 127.0.0.1", json.headers["x-forwarded-for"])
          assert.equal("127.0.0.1", json.headers["x-real-ip"])
        end)
      end)

      describe("trusted client", function()
        lazy_setup(function()
          if client then
            client:close()
          end
          helpers.stop_kong(nil, true, true)

          assert(helpers.start_kong({
            database = db_strategy,
            plugins = "forward-proxy",
            nginx_conf = "spec/fixtures/custom_nginx.template",
            trusted_ips = "127.0.0.1,::1",
          }))

          client = helpers.proxy_client()
        end)

        lazy_teardown(function()
          if client then
            client:close()
          end
          helpers.stop_kong(nil, true, true)

          assert(helpers.start_kong({
            database = db_strategy,
            plugins = "forward-proxy",
            nginx_conf     = "spec/fixtures/custom_nginx.template",
          }))

          client = helpers.proxy_client()
        end)

        it("no client X-Forwarded-* headers", function()
          local res = assert(client:send {
            method  = "GET",
            path    = "/request",
            headers = {
              host = "service-1.com",
            },
          })

          local body = assert.res_status(200, res)
          local json = cjson.decode(body)
          assert.equal("service-1.com", json.headers["x-forwarded-host"])
          assert.equal("9000", json.headers["x-forwarded-port"])
          assert.equal("http", json.headers["x-forwarded-proto"])
          assert.equal("127.0.0.1", json.headers["x-forwarded-for"])
          assert.equal("127.0.0.1", json.headers["x-real-ip"])
        end)

        it("with client X-Forwarded-* headers", function()
          local res = assert(client:send {
            method  = "GET",
            path    = "/request",
            headers = {
              host = "service-1.com",
              ["X-Real-IP"] = "10.0.0.1",
              ["X-Forwarded-For"] = "10.0.0.1",
              ["X-Forwarded-Host"] = "example.com",
              ["X-Forwarded-Proto"] = "https",
              ["X-Forwarded-Port"] = "443",
            },
          })

          local body = assert.res_status(200, res)
          local json = cjson.decode(body)
          assert.equal("example.com", json.headers["x-forwarded-host"])
          assert.equal("443", json.headers["x-forwarded-port"])
          assert.equal("https", json.headers["x-forwarded-proto"])
          assert.equal("10.0.0.1, 127.0.0.1", json.headers["x-forwarded-for"])
          assert.equal("10.0.0.1", json.headers["x-real-ip"])
        end)
      end)
    end)

    describe("displays Kong core headers:", function()
      for _, s in ipairs({ "Proxy", "Upstream" }) do
        local name = string.format("X-Kong-%s-Latency", s)

        it(name, function()
          local res = assert(client:send {
            method  = "GET",
            path    = "/get",
            headers = {
              host = "service-1.com",
            },
          })

          assert.res_status(200, res)
          assert.matches("^%d+$", res.headers[name])
        end)
      end
    end)

    it("returns server tokens with Via header", function()
      local res = assert(client:send {
        method  = "GET",
        path    = "/get",
        headers = {
          host = "service-1.com",
        },
      })

      assert.equal(server_header, res.headers["Via"])
    end)

  end)
end
