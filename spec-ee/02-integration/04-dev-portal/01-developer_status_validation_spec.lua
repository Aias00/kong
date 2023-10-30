-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local cjson = require "cjson"
local helpers = require "spec.helpers"
local http_mock = require "spec.helpers.http_mock"

local enums      = require "kong.enterprise_edition.dao.enums"

local MOCK_PORT = helpers.get_available_port()

local auth_types = {
  "basic-auth",
  "key-auth",
}


local function get_auth_header(auth_type, entity)
  local pk = entity.email or entity.username

  if auth_type == 'basic-auth' then
    return {
      ["Authorization"] = "Basic " .. ngx.encode_base64(pk .. ":password-" .. pk)
    }
  end

  if auth_type == 'key-auth' then
    return {
      ["Host"] = "route1.com",
      ["apikey"] = "key-" .. pk
    }
  end
end


for _, strategy in helpers.each_strategy() do
for _, auth_type in ipairs(auth_types) do

describe("Developer status validation for " .. auth_type .. " [#" .. strategy .. "]", function()
  local db, _, proxy_client, mock
  local proxy_consumer, approved_developer, pending_developer
  local rejected_developer, revoked_developer, invited_developer

  lazy_setup(function()
    mock = http_mock.new(MOCK_PORT)
    mock:start()
    _, db, _ = helpers.get_db_utils(strategy)

    kong.configuration = {
      portal_auth = auth_type,
    }
    local service1 = db.services:insert {
      host = "localhost",
      port = MOCK_PORT,
    }

    local route1 = db.routes:insert {
      methods = { "GET" },
      paths = { "/request" },
      service = { id = service1.id },
    }

    proxy_consumer = db.consumers:insert {
      username = "proxy_consumer",
      type     = enums.CONSUMERS.TYPE.PROXY,
    }

    if (auth_type == 'basic-auth') then
      assert(db.basicauth_credentials:insert {
        username    = "proxy_consumer",
        password    = "password-proxy_consumer",
        consumer = { id = proxy_consumer.id, },
      })

      assert(db.plugins:insert {
        name     = "basic-auth",
        route = { id = route1.id },
      })
    end

    if (auth_type == 'key-auth') then
      assert(db.keyauth_credentials:insert {
        key      = "key-proxy_consumer",
        consumer = { id = proxy_consumer.id, },
      })

      assert(db.plugins:insert {
        name     = "key-auth",
        route = { id = route1.id },
      })
    end

    approved_developer = db.developers:insert {
      email    = "approved_developer@konghq.com",
      status   = enums.CONSUMERS.STATUS.APPROVED,
      password = "password-approved_developer@konghq.com",
      key = "key-approved_developer@konghq.com",
      meta = '{"full_name":"Approved Name"}',
    }

    pending_developer = db.developers:insert {
      email    = "pending_developer@konghq.com",
      status   = enums.CONSUMERS.STATUS.PENDING,
      password = "password-pending_developer@konghq.com",
      key = "key-pending_developer@konghq.com",
      meta = '{"full_name":"Pending Name"}',
    }

    rejected_developer = db.developers:insert {
      email    = "rejected_developer@konghq.com",
      status   = enums.CONSUMERS.STATUS.REJECTED,
      password = "password-rejected_developer@konghq.com",
      key = "key-rejected_developer@konghq.com",
      meta = '{"full_name":"Rejected Name"}',
    }

    revoked_developer = db.developers:insert {
      email    = "revoked_developer@konghq.com",
      status   = enums.CONSUMERS.STATUS.REVOKED,
      password = "password-revoked_developer@konghq.com",
      key = "key-revoked_developer@konghq.com",
      meta = '{"full_name":"Revoked Name"}',
    }

    invited_developer = db.developers:insert {
      email    = "invited_developer@konghq.com",
      status   = enums.CONSUMERS.STATUS.INVITED,
      password = "password-invited_developer@konghq.com",
      key = "key-invited_developer@konghq.com",
      meta = '{"full_name":"Invited Name"}',
    }

    assert(helpers.start_kong({
      database = strategy,
      portal_auth = auth_type,
      portal_session_conf = "{ \"cookie_name\": \"portal_session\", \"secret\": \"super-secret\", \"cookie_secure\": false, \"storage\": \"kong\" }",
    }))

    proxy_client = helpers.proxy_client()
  end)

  lazy_teardown(function()
    if proxy_client then
      proxy_client:close()
    end

    helpers.stop_kong()
    mock:stop()
  end)

  describe("Proxy Consumer", function()
    it("succeeds with no status", function()
      local request_obj = {
        method  = "GET",
        path    = "/request",
        headers = get_auth_header(auth_type, proxy_consumer)
      }

      local res = assert(proxy_client:send(request_obj))
      assert.res_status(200, res)
    end)
  end)

  describe("Developer Consumer", function()
    it("succeeds when developer status is approved", function()
      local request_obj = {
        method  = "GET",
        path    = "/request",
        headers = get_auth_header(auth_type, approved_developer)
      }

      local res = assert(proxy_client:send(request_obj))
      assert.res_status(200, res)
    end)

    it("returns 401 when consumer status is pending", function()
      local request_obj = {
        method  = "GET",
        path    = "/request",
        headers = get_auth_header(auth_type, pending_developer)
      }

      local res = assert(proxy_client:send(request_obj))
      local body = assert.res_status(401, res)
      local json = cjson.decode(body)
      assert.same(json.message, 'Unauthorized: Developer status "PENDING"')
    end)

    it("returns 401 when consumer status is rejected", function()
      local request_obj = {
        method  = "GET",
        path    = "/request",
        headers = get_auth_header(auth_type, rejected_developer)
      }

      local res = assert(proxy_client:send(request_obj))
      local body = assert.res_status(401, res)
      local json = cjson.decode(body)
      assert.same(json.message, 'Unauthorized: Developer status "REJECTED"')
    end)

    it("returns 401 when consumer status is revoked", function()
      local request_obj = {
        method  = "GET",
        path    = "/request",
        headers = get_auth_header(auth_type, revoked_developer)
      }

      local res = assert(proxy_client:send(request_obj))
      local body = assert.res_status(401, res)
      local json = cjson.decode(body)
      assert.same(json.message, 'Unauthorized: Developer status "REVOKED"')
    end)

    it("returns 401 when consumer status is invited", function()
      local request_obj = {
        method  = "GET",
        path    = "/request",
        headers = get_auth_header(auth_type, invited_developer)
      }

      local res = assert(proxy_client:send(request_obj))
      local body = assert.res_status(401, res)
      local json = cjson.decode(body)
      assert.same(json.message, 'Unauthorized: Developer status "INVITED"')
    end)
  end)
end)
end
end
