-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]


local helpers = require "spec.helpers"

-- using the full path so that we don't have to modify package.path in
-- this context
local test_vault = require "spec.fixtures.custom_vaults.kong.vaults.test"
local utils = require "kong.tools.utils"
local cjson = require "cjson"
local pl_file = require "pl.file"

-- AWS dependencies

local aws = require "resty.aws"
local EnvironmentCredentials = require "resty.aws.credentials.EnvironmentCredentials"

-- GCP dependencies

local gcp = require "resty.gcp"
local access_token = require "resty.gcp.request.credentials.accesstoken"


-- HCV dependencies

local hcv = require "kong.vaults.hcv"


local CUSTOM_VAULTS = "./spec/fixtures/custom_vaults"
local CUSTOM_PLUGINS = "./spec/fixtures/custom_plugins"

local LUA_PATH = CUSTOM_VAULTS .. "/?.lua;" ..
                 CUSTOM_VAULTS .. "/?/init.lua;" ..
                 CUSTOM_PLUGINS .. "/?.lua;" ..
                 CUSTOM_PLUGINS .. "/?/init.lua;;"

local DUMMY_HEADER = "Dummy-Plugin"
local fmt = string.format



--- A vault test harness is a driver for vault backends, which implements
--- all the necessary glue for initializing a vault backend and performing
--- secret read/write operations.
---
--- All functions defined here are called as "methods" (e.g. harness:fn()), so
--- it is permitted to keep state on the harness object (self).
---
---@class harness
---
---@field name string
---
--- this table is passed directly to kong.db.vaults:insert()
---@field config table
---
--- create_secret() is called once per test run for a given secret
---@field create_secret fun(self: harness, secret: string, value: string, opts?: table)
---
--- update_secret() may be called more than once per test run for a given secret
---@field update_secret fun(self: harness, secret: string, value: string, opts?: table)
---
--- setup() is called before kong is started and before any DB entities
--- have been created and is best used for things like validating backend
--- credentials and establishing a connection to a backend
---@field setup fun(self: harness)
---
--- teardown() is exactly what you'd expect
---@field teardown fun(self: harness)
---
--- fixtures() output is passed directly to `helpers.start_kong()`
---@field fixtures fun(self: harness):table|nil
---
---
---@field prefix   string   # generated by the test suite
---@field host     string   # generated by the test suite


---@type harness[]
local VAULTS = {
  {
    name = "test",

    config = {
      default_value = "DEFAULT",
      default_value_ttl = 1,
    },

    create_secret = function(self, _, value)
      -- Currently, create_secret is called _before_ starting Kong.
      --
      -- This means our backend won't be available yet because it is
      -- piggy-backing on Kong as an HTTP mock fixture.
      --
      -- We can, however, inject a default value into our configuration.
      self.config.default_value = cjson.encode({secret = value})
    end,

    update_secret = function(_, secret, value, opts)
      return test_vault.client.put(secret, cjson.encode({secret = value}), opts)
    end,

    delete_secret = function(_, secret)
      -- noop
    end,

    fixtures = function()
      return {
        http_mock = {
          test_vault = test_vault.http_mock,
        }
      }
    end,
  },

  {
    name = "aws",

    config = {
      region = "us-east-1",
    },

    -- lua-resty-aws sdk object
    AWS = nil,

    -- lua-resty-aws secrets-manager client object
    sm = nil,

    -- secrets that were created during the test run, for cleanup purposes
    secrets = {},

    setup = function(self)
      assert(os.getenv("AWS_ACCESS_KEY_ID"),
             "missing AWS_ACCESS_KEY_ID environment variable")

      assert(os.getenv("AWS_SECRET_ACCESS_KEY"),
             "missing AWS_SECRET_ACCESS_KEY environment variable")

      self.AWS = aws({ credentials = EnvironmentCredentials.new() })
      self.sm = assert(self.AWS:SecretsManager(self.config))
    end,

    create_secret = function(self, secret, value, _)
      assert(self.sm, "secrets manager is not initialized")

      local res, err = self.sm:createSecret({
        ClientRequestToken = utils.uuid(),
        Name = secret,
        SecretString = cjson.encode({secret = value}),
      })

      assert.is_nil(err)
      assert.is_equal(200, res.status)

      table.insert(self.secrets, res.body.ARN)
    end,

    update_secret = function(self, secret, value, _)
      local res, err = self.sm:putSecretValue({
        ClientRequestToken = utils.uuid(),
        SecretId = secret,
        SecretString = cjson.encode({secret = value}),
      })

      assert.is_nil(err)
      assert.is_equal(200, res.status)
    end,

    delete_secret = function(self, secret)
      local res, err = self.sm:deleteSecret({
        SecretId = secret,
      })

      assert.is_nil(err)
      assert.is_equal(200, res.status)
    end
  },

  {
    name = "gcp",

    GCP = nil,

    access_token = nil,

    secrets = {},

    config = {},

    setup = function(self)
      local service_account = assert(os.getenv("GCP_SERVICE_ACCOUNT"), "missing GCP_SERVICE_ACCOUNT environment variable")

      self.GCP = gcp()
      self.config.project_id = assert(cjson.decode(service_account).project_id)
      self.access_token = access_token.new()
    end,

    create_secret = function(self, secret, value, _)
      local res, err = self.GCP.secretmanager_v1.secrets.create(
        self.access_token,
        {
          projectsId = self.config.project_id,
          secretId = secret,
        },
        {
          replication = {
            automatic = {}
          }
        }
      )
      assert.is_nil(err)
      assert.is_nil(res.error)

      self:update_secret(secret, value, _)

      table.insert(self.secrets, secret)
    end,

    update_secret = function(self, secret, value)
      local res, err = self.GCP.secretmanager_v1.secrets.addVersion(
        self.access_token,
        {
          projectsId = self.config.project_id,
          secretsId = secret,
        },
        {
          payload = {
            data = ngx.encode_base64(cjson.encode({secret = value})),
          }
        }
      )
      assert.is_nil(err)
      assert.is_nil(res.error)
    end,

    delete_secret = function(self, secret)
      local res, err = self.GCP.secretmanager_v1.secrets.delete(
        self.access_token,
        {
          projectsId = self.config.project_id,
          secretsId = secret,
        }
      )
      assert.is_nil(err)
      assert.is_nil(res.error)
    end
  },

  -- hashi vault
  {
    name = "hcv",

    config = {
      token = "vault-plaintext-root-token",
      host = "localhost",
      port = 8200,
      kv = "v2",
    },

    create_secret = function(self, ...)
      return self:update_secret(...)
    end,

    update_secret = function(self, secret, value, _)
      local _, err = hcv._request(
        self.config,
        secret,
        nil,
        {
          method = "POST",
          body = cjson.encode({data = { secret = value }})
        })
      assert.is_nil(err)
    end,

    delete_secret = function(self, secret)
      local _, err = hcv._request(
        self.config,
        secret,
        nil,
        {
          method = "DELETE",
        })
      assert.is_nil(err)
    end
  }
}


local noop = function(...) end

for _, vault in ipairs(VAULTS) do
  -- fill out some values that we'll use in route/service/plugin config
  vault.prefix     = vault.name .. "-ttl-test"
  vault.host       = vault.name .. ".vault-ttl.test"

  -- ...and fill out non-required methods
  vault.setup         = vault.setup or noop
  vault.teardown      = vault.teardown or noop
  vault.fixtures      = vault.fixtures or noop
end


for _, strategy in helpers.each_strategy() do
for _, vault in ipairs(VAULTS) do

describe("vault ttl and rotation (#" .. strategy .. ") #" .. vault.name, function()
  local client
  local secret = "my-secret-" .. utils.uuid()


  local function http_get(path)
    path = path or "/"

    local res = client:get(path, {
      headers = {
        host = assert(vault.host),
      },
    })

    assert.response(res).has.status(200)

    return res
  end


  lazy_setup(function()
    helpers.setenv("KONG_LUA_PATH_OVERRIDE", LUA_PATH)
    helpers.setenv("KONG_VAULT_ROTATION_INTERVAL", "1")

    helpers.test_conf.loaded_plugins = {
      dummy = true,
    }

    vault:setup()
    vault:create_secret(secret, "init")

    local bp = helpers.get_db_utils(strategy,
                                    nil,
                                    { "dummy" },
                                    { vault.name })


    assert(bp.vaults:insert({
      name     = vault.name,
      prefix   = vault.prefix,
      config   = vault.config,
    }))

    local route = assert(bp.routes:insert({
      name      = vault.host,
      hosts     = { vault.host },
      paths     = { "/" },
      service   = assert(bp.services:insert()),
    }))


    -- used by the plugin config test case
    assert(bp.plugins:insert({
      name = "dummy",
      config = {
        resp_header_value = fmt("{vault://%s/%s/secret?ttl=%s}",
                                vault.prefix, secret, 1),
      },
      route = { id = route.id },
    }))

    helpers.setenv("KONG_LICENSE_DATA", pl_file.read("spec-ee/fixtures/mock_license.json"))
    assert(helpers.start_kong({
      database   = strategy,
      nginx_conf = "spec/fixtures/custom_nginx.template",
      vaults     = vault.name,
      plugins    = "dummy",
      log_level  = "info",
    }, nil, nil, vault:fixtures()))

    client = helpers.proxy_client()
  end)


  lazy_teardown(function()
    if client then
      client:close()
    end

    helpers.stop_kong()
    vault:delete_secret(secret)
    vault:teardown()

    helpers.unsetenv("KONG_LUA_PATH_OVERRIDE")
  end)


  it("updates plugin config references (backend: #" .. vault.name .. ")", function()
    local function check_plugin_secret(expect, ttl, leeway)
      leeway = leeway or 0.25 -- 25%

      local timeout = ttl + (ttl * leeway)

      assert
        .with_timeout(timeout)
        .with_step(0.5)
        .eventually(function()
          local res = http_get("/")
          local value = assert.response(res).has.header(DUMMY_HEADER)

          if value == expect then
            return true
          end

          return nil, { expected = expect, got = value }
        end)
        .is_truthy("expected plugin secret to be updated to '" .. expect .. "' "
                .. "' within " .. tostring(timeout) .. " seconds")
    end

    vault:update_secret(secret, "old", { ttl = 5 })
    check_plugin_secret("old", 5)

    vault:update_secret(secret, "new", { ttl = 5 })
    check_plugin_secret("new", 5)
  end)
end)

end -- each vault backend
end -- each strategy
