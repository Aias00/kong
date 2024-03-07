-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local helpers = require "spec.helpers"

local PLUGIN_NAME = "oas-validation"

local fixtures = {
  http_mock = {
    validation_plugin = [[
      server {
          server_name petstore.test;
          listen 12345;

          location ~ "/user/foo/report.pdf" {
            return 200;
          }

          location ~ "/user/test.pdf" {
            return 200;
          }

          location ~ "/v1/user/foo/report.pdf" {
            return 200;
          }

          location ~ "/v1/user/test.pdf" {
            return 200;
          }

          location / {
             return 301;
          }
        }
    ]]
  }
}

for _, strategy in helpers.each_strategy() do
  describe(PLUGIN_NAME .. ": (access) [#" .. strategy .. "]", function()
    local client

    lazy_setup(function()
      local bp, db = helpers.get_db_utils(strategy, {
        "routes",
        "services",
      }, { PLUGIN_NAME })

      local service1 = assert(bp.services:insert {
        protocol = "http",
        port = 12345,
        host = "127.0.0.1",
      })

      local route1 = assert(db.routes:insert({
        hosts = { "petstore1.test" },
        paths = { "/" },
        service = service1,
      }))
      assert(db.plugins:insert {
        name = PLUGIN_NAME,
        route = { id = route1.id },
        config = {
          api_spec = assert(io.open(helpers.get_fixtures_path() .. "/resources/path-match-oas.yaml"):read("*a")),
          validate_response_body = true,
          validate_request_header_params = true,
          validate_request_query_params = true,
          validate_request_uri_params = true,
          header_parameter_check = true,
          query_parameter_check = true,
          verbose_response = true
        },
      })

      local route2 = assert(db.routes:insert({
        hosts = { "petstore2.test" },
        service = service1,
      }))
      assert(db.plugins:insert {
        name = PLUGIN_NAME,
        route = { id = route2.id },
        config = {
          api_spec = assert(io.open(helpers.get_fixtures_path() .. "/resources/path-match-oas.yaml"):read("*a")),
          validate_response_body = true,
          validate_request_header_params = true,
          validate_request_query_params = true,
          validate_request_uri_params = true,
          header_parameter_check = true,
          query_parameter_check = true,
          verbose_response = true,
          include_base_path = true,
        },
      })

      assert(helpers.start_kong({
        database = strategy,
        nginx_conf = "spec/fixtures/custom_nginx.template",
        plugins = "bundled," .. PLUGIN_NAME,
      }, nil, nil, fixtures))
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

    describe("request-body-oas", function()
      it("/user/{username}/report.{format} - should match", function()
        local res = assert(client:send {
          method = "GET",
          path = "/user/foo/report.pdf",
          headers = {
            host = "petstore1.test",
          },
        })
        assert.response(res).has.status(200)
      end)

      it("/user/{username}.pdf - should match", function()
        local res = assert(client:send {
          method = "GET",
          path = "/user/test.pdf",
          headers = {
            host = "petstore1.test",
          },
        })
        assert.response(res).has.status(200)
      end)

      describe("include_base_path = true", function()
        it("/user/{username}/report.{format} - should match", function()
          local res = assert(client:send {
            method = "GET",
            path = "/v1/user/foo/report.pdf",
            headers = {
              host = "petstore2.test",
            },
          })
          assert.response(res).has.status(200)
        end)

        it("/user/{username}.pdf - should match", function()
          local res = assert(client:send {
            method = "GET",
            path = "/v1/user/test.pdf",
            headers = {
              host = "petstore2.test",
            },
          })
          assert.response(res).has.status(200)
        end)
      end)
    end)

    it("encoded path parameter", function()
      local res = assert(client:send {
        method = "GET",
        path = "/user/你好?",
        headers = {
          host = "petstore1.test",
        },
      })
      assert.response(res).has.status(301)
      local res = assert(client:send {
        method = "GET",
        path = "/user/%E4%BD%A0%E5%A5%BD",
        headers = {
          host = "petstore1.test",
        },
      })
      assert.response(res).has.status(301)

      local res = assert(client:send {
        method = "GET",
        path = "/user/%E4%BD%A0%E5%A5%BD/report.世界",
        headers = {
          host = "petstore1.test",
        },
      })

      assert.response(res).has.status(301)
      local res = assert(client:send {
        method = "GET",
        path = "/user/%E4%BD%A0%E5%A5%BD/report.%E4%B8%96%E7%95%8C",
        headers = {
          host = "petstore1.test",
        },
      })
      assert.response(res).has.status(301)
    end)

    it("escape regex characters", function()
      local res = assert(client:send {
        method = "GET",
        path = "/escape/a|.-+*b",
        headers = {
          host = "petstore1.test",
        },
      })
      assert.response(res).has.status(301)
    end)
  end)
end
