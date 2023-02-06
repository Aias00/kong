-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local cjson    = require "cjson"
local helpers  = require "spec.helpers"

local MEM_CACHE_SIZE = "15m"

describe("Admin API #off", function()
  local client

  lazy_setup(function()
    assert(helpers.start_kong({
      database = "off",
      mem_cache_size = MEM_CACHE_SIZE,
      stream_listen = "127.0.0.1:9011",
      nginx_conf = "spec/fixtures/custom_nginx.template",
    }))
  end)

  lazy_teardown(function()
    helpers.stop_kong(nil, true)
  end)

  before_each(function()
    client = assert(helpers.admin_client())
  end)

  after_each(function()
    if client then
      client:close()
    end
  end)

  it("hides workspace related fields from /config response", function()
    local res = assert(client:send {
      method = "POST",
      path = "/config",
      body = {
        config = [[
            _format_version: "1.1"
            services:
            - name: my-service
              id: 0855b320-0dd2-547d-891d-601e9b38647f
              url: https://example.com
              plugins:
              - name: file-log
                id: 0611a5a9-de73-5a2d-a4e6-6a38ad4c3cb2
                config:
                  path: /tmp/file.log
              - name: key-auth
                id: 661199ff-aa1c-5498-982c-d57a4bd6e48b
              routes:
              - name: my-route
                id: 481a9539-f49c-51b6-b2e2-fe99ee68866c
                paths:
                - /
            consumers:
            - username: my-user
              id: 4b1b701d-de2b-5588-9aa2-3b97061d9f52
              keyauth_credentials:
              - key: my-key
                id: 487ab43c-b2c9-51ec-8da5-367586ea2b61
            ]],
      },
      headers = {
        ["Content-Type"] = "application/json"
      }
    })

    local body = assert.response(res).has.status(201)
    local entities = cjson.decode(body)

    assert.is_not_nil(entities.workspaces)
    assert.is_not_nil(entities.consumers["4b1b701d-de2b-5588-9aa2-3b97061d9f52"].ws_id)
    assert.is_not_nil(entities.keyauth_credentials["487ab43c-b2c9-51ec-8da5-367586ea2b61"].ws_id)
    assert.is_not_nil(entities.plugins["0611a5a9-de73-5a2d-a4e6-6a38ad4c3cb2"].ws_id)
    assert.is_not_nil(entities.plugins["661199ff-aa1c-5498-982c-d57a4bd6e48b"].ws_id)
    assert.is_not_nil(entities.routes["481a9539-f49c-51b6-b2e2-fe99ee68866c"].ws_id)
    assert.is_not_nil(entities.services["0855b320-0dd2-547d-891d-601e9b38647f"].ws_id)
  end)
end)

describe("Loading license entity takes precedence over the vault", function()
  local f = assert(io.open("spec-ee/fixtures/mock_license.json"))
  local d = f:read("*a")
  f:close()

  local client

  local function start_kong()
    return function()
      helpers.unsetenv("KONG_LICENSE_DATA")
      helpers.unsetenv("KONG_TEST_LICENSE_DATA")
      assert(helpers.start_kong({
        database = "off",
        mem_cache_size = MEM_CACHE_SIZE,
        vaults = "bundled",
      }))
      client = helpers.admin_client()
    end
  end

  local function stop_kong()
    if client then
      client:close()
    end
    helpers.stop_kong()
  end

  describe("/", function()
    setup(start_kong())
    teardown(stop_kong)

    it("can load restricted vaults with license", function()
      local res = assert(client:send {
        method = "POST",
        path = "/config",
        body = {
          config = string.format([[
            _format_version: '3.0'
            licenses:
            - updated_at: 1668152723
              id: c2f25974-d669-46e3-b7a7-36991735a018
              created_at: 1668152723
              payload: '%s'
            vaults:
            - name: aws
              updated_at: 1668152730
              config:
                region:
              description:
              tags:
              prefix: my-vault
              id: 0aba66ff-5baa-40b7-bc23-806790b5d8d6
              created_at: 1668152730
          ]], d)
        },
        headers = {
          ["Content-Type"] = "application/json"
        }
      })

      assert.response(res).has.status(201)
    end)
  end)
end)
