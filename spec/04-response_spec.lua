-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local helpers = require "spec.helpers"

for _, strategy in helpers.each_strategy() do
  describe("jq-filter (" .. strategy .. ") response", function()
    local client

    lazy_setup(function()
      local bp = helpers.get_db_utils(strategy, {
        "routes",
        "services", "plugins",
      }, { "jq-filter" })

      do
        local routes = {}
        for i = 1, 11 do
          table.insert(routes,
                       bp.routes:insert({
                         hosts = { "test" .. i .. ".example.com" }
                       }))
        end

        local function add_plugin(route, config)
          bp.plugins:insert({
            route = { id = route.id },
            name = "jq-filter",
            config = config,
          })
        end

        add_plugin(routes[1], {
          filters = {
            {
              context = "response",
              target = "body",
              program = ".uri_args",
            },
          },
        })

        -- program matching nothing
        add_plugin(routes[2], {
          filters = {
            {
              context = "response",
              target = "body",
              program = ".foo.bar",
            },
          },
        })

        add_plugin(routes[3], {
          filters = {
            {
              context = "response",
              target = "body",
              program = ".uri_args.foo",
              jq_options = {
                raw_output = true,
              },
            },
          },
        })

        add_plugin(routes[4], {
          filters = {
            {
              context = "response",
              target = "body",
              program = ".uri_args.foo",
              jq_options = {
                join_output = true,
              },
            },
          },
        })

        add_plugin(routes[5], {
          filters = {
            {
              context = "response",
              target = "body",
              program = ".uri_args.foo",
              jq_options = {
                ascii_output = true,
              }
            },
          },
        })

        add_plugin(routes[6], {
          filters = {
            {
              context = "response",
              target = "body",
              program = ".uri_args",
              jq_options = {
                sort_keys = true,
              }
            },
          },
        })

        add_plugin(routes[7], {
          filters = {
            {
              context = "response",
              target = "body",
              program = ".uri_args",
              jq_options = {
                compact_output = false,
              }
            },
          },
        })

        add_plugin(routes[8], {
          filters = {
            {
              context = "response",
              target = "body",
              program = ".uri_args",
              if_media_type = {
                "text/plain",
              },
            },
          },
        })

        add_plugin(routes[9], {
          filters = {
            {
              context = "response",
              target = "headers",
              program = [[.uri_args | { "X-Foo": .foo, "X-Bar": .bar }]],
            },
          },
        })

        add_plugin(routes[10], {
          filters = {
            {
              context = "response",
              target = "headers",
              program = [[.uri_args | { "X-Foo": .foo }]],
            },
            {
              context = "response",
              target = "headers",
              program = [[.uri_args | { "X-Bar": .bar }]],
            },
            {
              context = "response",
              target = "body",
              program = ".uri_args",
            },
          },
        })

        add_plugin(routes[11], {
          filters = {
            {
              context = "response",
              target = "body",
              program = ".uri_args",
              if_status_code = {
                201,
              }
            },
          },
        })
      end

      assert(helpers.start_kong({
        database = strategy,
        nginx_conf = "spec/fixtures/custom_nginx.template",
        plugins = "jq-filter"
      }))
    end)

    lazy_teardown(function()
      helpers.stop_kong()
    end)

    before_each(function()
      client = helpers.proxy_client()
    end)

    after_each(function()
      if client then
        client:close()
      end
    end)

    describe("body", function()
      it("filters with default options", function()
        local r = assert(client:send {
          method  = "GET",
          path    = "/request?foo=bar",
          headers = {
            ["Host"] = "test1.example.com",
          },
        })
        local json = assert.response(r).has.jsonbody()
        assert.same({ foo = "bar" }, json)
      end)

      it("returns null when filter is out of range", function()
        local r = assert(client:send {
          method  = "GET",
          path    = "/request",
          headers = {
            ["Host"] = "test2.example.com",
          },
        })
        local json = assert.response(r).has.jsonbody()
        assert.same(ngx.null, json)
      end)

      it("filters with raw_output", function()
        local r = assert(client:send {
          method  = "GET",
          path    = "/request?foo=bar",
          headers = {
            ["Host"] = "test3.example.com",
          },
        })
        assert.same("bar\n", r:read_body())
      end)

      it("filters with join_output", function()
        local r = assert(client:send {
          method  = "GET",
          path    = "/request?foo=bar",
          headers = {
            ["Host"] = "test4.example.com",
          },
        })
        assert.same("bar", r:read_body())
      end)

      it("filters with ascii_output", function()
        local r = assert(client:send {
          method  = "GET",
          path    = "/request?foo=bar%C3%A9",
          headers = {
            ["Host"] = "test5.example.com",
          },
        })
        assert.same("\"bar\\u00e9\"\n", r:read_body())
      end)

      it("filters with sorted keys", function()
        local r = assert(client:send {
          method  = "GET",
          path    = "/request?foo=bar&bar=foo",
          headers = {
            ["Host"] = "test6.example.com",
          },
        })
        assert.same("{\"bar\":\"foo\",\"foo\":\"bar\"}\n", r:read_body())
      end)

      it("filters with pretty output", function()
        local r = assert(client:send {
          method  = "GET",
          path    = "/request?foo=bar",
          headers = {
            ["Host"] = "test7.example.com",
          },
        })
        assert.same([[{
  "foo": "bar"
}
]], r:read_body())
      end)

      it("does not filter with different media type", function()
        local r = assert(client:send {
          method  = "GET",
          path    = "/request?foo=bar",
          headers = {
            ["Host"] = "test8.example.com",
          },
        })

        local json = assert.response(r).has.jsonbody()
        -- json is unfiltered, entire response object
        assert.same("bar", json.uri_args.foo)
      end)

      it("does not filter with non 200 status", function()
        local r = assert(client:send {
          method  = "GET",
          path    = "/request?foo=bar",
          headers = {
            ["Host"] = "test11.example.com",
          },
        })

        local json = assert.response(r).has.jsonbody()
        -- json is unfiltered, entire response object
        assert.same("bar", json.uri_args.foo)
      end)
    end)

    describe("headers", function()
      it("filters with default options", function()
        local r = assert(client:send {
          method  = "GET",
          path    = "/request?foo=bar&bar=foo",
          headers = {
            ["Host"] = "test9.example.com",
          },
        })

        local foo = assert.response(r).has.header("X-Foo")
        assert.equals(foo, "bar")

        local bar = assert.response(r).has_header("X-Bar")
        assert.equals(bar, "foo")
      end)

      it("multiple filters", function()
        local r = assert(client:send {
          method  = "GET",
          path    = "/request?foo=bar&bar=foo",
          headers = {
            ["Host"] = "test10.example.com",
          },
        })
        local foo = assert.response(r).has.header("X-Foo")
        assert.equals(foo, "bar")

        local bar = assert.response(r).has_header("X-Bar")
        assert.equals(bar, "foo")

        local json = assert.response(r).has.jsonbody()
        assert.same({
          foo = "bar",
          bar = "foo"
        }, json)
      end)
    end)
  end)
end
