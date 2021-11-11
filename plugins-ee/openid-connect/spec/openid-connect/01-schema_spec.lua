-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local PLUGIN_NAME = "openid-connect"


local validate do
  local validate_entity = require("spec.helpers").validate_plugin_config_schema
  local plugin_schema = require("kong.plugins."..PLUGIN_NAME..".schema")

  function validate(data)
    return validate_entity(data, plugin_schema)
  end
end


describe(PLUGIN_NAME .. ": (schema)", function()

  it("allows to configure plugin with issuer url", function()
    local ok, err = validate({
        issuer = "https://accounts.google.com/.well-known/openid-configuration",
      })
    assert.is_nil(err)
    assert.is_truthy(ok)
  end)


  it("does not allow configure plugin without issuer url", function()
    local ok, err = validate({
      })
    assert.is_same({
        config = {
          issuer = 'required field missing'
        }
      }, err)
    assert.is_falsy(ok)
  end)

  it("redis cluster nodes accepts ips or hostnames", function()
    local ok, err = validate({
      issuer = "https://accounts.google.com/.well-known/openid-configuration",
      session_redis_cluster_nodes = {
        {
          ip = "redis-node-1",
          port = 6379,
        },
        {
          ip = "redis-node-2",
          port = 6380,
        },
        {
          ip = "127.0.0.1",
          port = 6381,
        },
      },
    })
    assert.is_nil(err)
    assert.is_truthy(ok)
  end)


  it("redis cluster nodes rejects bad ports", function()
    local ok, err = validate({
      issuer = "https://accounts.google.com/.well-known/openid-configuration",
      session_redis_cluster_nodes = {
        {
          ip = "redis-node-1",
          port = "6379",
        },
        {
          ip = "redis-node-2",
          port = 6380,
        },
      },
    })
    assert.is_same(
    { port = "expected an integer" },
    err.config.session_redis_cluster_nodes[1]
    )
    assert.is_falsy(ok)
  end)

end)
