-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local validate_entity = require("spec.helpers").validate_plugin_config_schema
local ldap_schema = require("kong.plugins.ldap-auth-advanced.schema")


describe("ldap auth advanced schema", function()
  it("should pass with default configuration parameters", function()
    local ok, err = validate_entity({ base_dn = "ou=scientists,dc=ldap,dc=mashape,dc=com", attribute = "uuid",
                                      ldap_host = "host" }, ldap_schema)

    assert.is_truthy(ok)
    assert.is_nil(err)
  end)

  it("should fail with both config.ldaps and config.start_tls options enabled", function()
    local ok, err = validate_entity({ base_dn = "ou=scientists,dc=ldap,dc=mashape,dc=com", attribute = "uuid",
                                      ldap_host = "host", ldaps = true, start_tls = true }, ldap_schema)

    local expected = {
      "ldaps and StartTLS cannot be enabled simultaneously."
    }
    assert.is_falsy(ok)
    assert.is_same(expected, err["@entity"])
  end)

  it("should pass with parameters config.ldaps enabled and config.start_tls disbled", function()
    local ok, err = validate_entity({ base_dn = "ou=scientists,dc=ldap,dc=mashape,dc=com", attribute = "uuid",
                                      ldap_host = "host", ldaps = true, start_tls = false }, ldap_schema)

    assert.is_truthy(ok)
    assert.is_nil(err)
  end)

  it("should pass with parameters config.ldaps disabled and config.start_tls enabled", function()
    local ok, err = validate_entity({ base_dn = "ou=scientists,dc=ldap,dc=mashape,dc=com", attribute = "uuid",
                                      ldap_host = "host", ldaps = false, start_tls = true }, ldap_schema)

    assert.is_truthy(ok)
    assert.is_nil(err)
  end)

  it("should pass with parameters config.anonymous to be configures as username of consumer", function()
    local ok, err = validate_entity({
      base_dn = "ou=scientists,dc=ldap,dc=mashape,dc=com",
      attribute = "uuid",
      ldap_host = "host",
      anonymous = "test",
    }, ldap_schema)

    assert.is_nil(err)
    assert.is_truthy(ok)
  end)


end)

