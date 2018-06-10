local helpers = require "spec.helpers"


local function create_big_data(size)
  return {
    mock_json = {
      big_field = string.rep("*", size),
    },
  }
end


for _, strategy in helpers.each_strategy() do
  describe("Plugin: response-transformer with feature_flag response_transformation_limit_body_size on", function()
    local proxy_client

    setup(function()
      local bp, _, dao = helpers.get_db_utils(strategy)

      helpers.with_current_ws(nil, function()
      local route = bp.routes:insert({
        hosts   = { "response.com" },
        methods = { "POST" },
      })

      bp.plugins:insert {
        route_id = route.id,
        name     = "response-transformer",
        config   = {
          add    = {
            json = {"p1:v1"},
          }
        },
      }
      end, dao)

      assert(helpers.start_kong({
        database   = strategy,
        nginx_conf = "spec/fixtures/custom_nginx.template",
        feature_conf_path = "spec/fixtures/ee/feature_response_transformer_limit_body.conf",
      }))
    end)

    teardown(function()
      helpers.stop_kong()
    end)

    before_each(function()
      proxy_client = helpers.proxy_client()
    end)

    after_each(function()
      if proxy_client then proxy_client:close() end
    end)

    it("transforms body when body size doesn't exceed limit", function()
      local res = assert(proxy_client:send {
        method  = "POST",
        path    = "/post",
        body    = create_big_data(1),
        headers = {
          host             = "response.com",
          ["content-type"] = "application/json",
        }
      })
      assert.response(res).has.status(200)
      local json = assert.response(res).has.jsonbody()
      assert.equal("v1", json.p1)
    end)

    it("doesn't transform body when body size exceeds limit", function()
      local body = create_big_data(1024 * 1024)
      local res = assert(proxy_client:send {
        method  = "POST",
        path    = "/post",
        body    = body,
        headers = {
          host             = "response.com",
          ["content-type"] = "application/json",
        }
      })
      assert.response(res).has.status(200)
      local json = assert.response(res).has.jsonbody()
      assert.are.same(body, json.post_data.params)
      assert.is_nil(json.p1)
    end)
  end)

  describe("Plugin: response-transformer with feature_flag response_transformation_limit_body_size on, no content-length in response", function()
    local proxy_client

    setup(function()
      local bp = helpers.get_db_utils(strategy)

      local route = bp.routes:insert({
        hosts   = { "response.com" },
        methods = { "GET" },
      })

      bp.plugins:insert {
        route_id = route.id,
        name     = "response-transformer",
        config   = {
          add    = {
            json = {"p1:v1"},
          }
        },
      }

      assert(helpers.start_kong({
        database   = strategy,
        nginx_conf = "spec/fixtures/custom_nginx.template",
        feature_conf_path = "spec/fixtures/ee/feature_response_transformer_limit_body_chunked.conf",
      }))
    end)

    teardown(function()
      helpers.stop_kong()
    end)

    before_each(function()
      proxy_client = helpers.proxy_client()
    end)

    after_each(function()
      if proxy_client then proxy_client:close() end
    end)

    it("doesn't transform body when body size exceeds limit and content-length is not set", function()
      local res = assert(proxy_client:send {
        method  = "GET",
        path    = "/stream/1",
        headers = {
          host             = "response.com",
          ["content-type"] = "application/json",
        }
      })
      assert.response(res).has.status(200)
      local json = assert.response(res).has.jsonbody()
      assert.is_nil(json.p1)
    end)
  end)
end
