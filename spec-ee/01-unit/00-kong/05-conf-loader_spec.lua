-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local ee_conf_loader = require("kong.enterprise_edition.conf_loader")

describe("ee conf loader", function()
  local msgs
  before_each(function()
    msgs = {}
  end)
  describe("validate_admin_gui_authentication()", function()
    it("returns error if admin_gui_auth value is not supported", function()
      ee_conf_loader.validate_admin_gui_authentication({ admin_gui_auth ="foo",
                                                         enforce_rbac = true,
                                                       }, msgs)

      local expected = { "admin_gui_auth must be 'key-auth', 'basic-auth', " ..
                         "'ldap-auth-advanced', 'openid-connect' or not set" }
      assert.same(expected, msgs)
    end)

    it("returns error if admin_gui_auth_config is set without admin_gui_auth", function()
      ee_conf_loader.validate_admin_gui_authentication({
        admin_gui_auth_conf = "{ \"hide_credentials\": true }" }, msgs)

      local expected = { "admin_gui_auth_conf is set with no admin_gui_auth" }
      assert.same(expected, msgs)
    end)

    it("returns error if admin_gui_auth_config is invalid JSON", function()
      ee_conf_loader.validate_admin_gui_authentication({
        admin_gui_auth = "basic-auth",
        admin_gui_auth_conf = "{ \"hide_credentials\" = true }",
        enforce_rbac = true,
      }, msgs)

      local expected = { "admin_gui_auth_conf must be valid json or not set: " ..
                         "Expected colon but found invalid token at " ..
                         "character 22 - { \"hide_credentials\" = true }" }

      assert.same(expected, msgs)
    end)

    it("returns error if admin_gui_auth_password_complexity is set without basic-auth", function()
      ee_conf_loader.validate_admin_gui_authentication({
        admin_gui_auth_password_complexity = "{ \"min\": \"disabled,24,11,9,8\", \"match\": 3 }"
      }, msgs)

      local expected = { "admin_gui_auth_password_complexity is set without basic-auth" }
      assert.same(expected, msgs)
    end)

    it("returns error if admin_gui_auth_password_complexity is invalid JSON", function()
      ee_conf_loader.validate_admin_gui_authentication({
        admin_gui_auth = "basic-auth",
        admin_gui_auth_password_complexity = "{ \"min\"= \"disabled,24,11,9,8\", \"match\": 3 }",
        enforce_rbac = true,
      }, msgs)

      local expected = { "admin_gui_auth_password_complexity must be valid json or not set: " ..
                         "Expected colon but found invalid token at " ..
                         "character 8 - { \"min\"= \"disabled,24,11,9,8\", \"match\": 3 }" }

      assert.same(expected, msgs)
    end)

    it("returns error if admin_gui_auth is on but rbac is off", function()
      ee_conf_loader.validate_admin_gui_authentication({
        admin_gui_auth = "basic-auth",
        enforce_rbac = false,
      }, msgs)

       local expected = { "enforce_rbac must be enabled when admin_gui_auth " ..
                         "is enabled" }

      assert.same(expected, msgs)
    end)

    it("returns {} if there are no errors", function()
      ee_conf_loader.validate_admin_gui_authentication({
        admin_gui_auth = "basic-auth",
        admin_gui_auth_conf = "{ \"hide_credentials\": true }",
        enforce_rbac = true,
      }, msgs)

      assert.same({}, msgs)
    end)

    it("returns {} if admin gui auth settings are not present", function()
      ee_conf_loader.validate_admin_gui_authentication({
        some_other_property = "on"
      }, msgs)

      assert.same({}, msgs)
    end)
  end)

  describe("validate_admin_gui_session()", function()
    it("returns error if admin_gui_auth is set without admin_gui_session_conf", function()
      ee_conf_loader.validate_admin_gui_session({
        admin_gui_auth = "basic-auth",
      }, msgs)

      local expected = { "admin_gui_session_conf must be set when admin_gui_auth is enabled" }
      assert.same(expected, msgs)
    end)

    it("returns error if admin_gui_session_conf is set with no admin_gui_auth", function()
      ee_conf_loader.validate_admin_gui_session({
        admin_gui_session_conf = "{ \"secret\": \"super-secret\" }",
      }, msgs)

      local expected = { "admin_gui_session_conf is set with no admin_gui_auth" }
      assert.same(expected, msgs)
    end)

    it("returns error if admin_gui_session_conf is invalid json", function()
      ee_conf_loader.validate_admin_gui_session({
        admin_gui_auth = "basic-auth",
        admin_gui_session_conf = "{ 'secret': 'i-am-invalid-json' }",
      }, msgs)

      local expected = { "admin_gui_session_conf must be valid json or not set: " ..
                         "Expected object key string but found invalid token at " ..
                         "character 3 - { 'secret': 'i-am-invalid-json' }" }
      assert.same(expected, msgs)
    end)
  end)

  describe("validate_admin_gui_ssl()", function()
    it("returns errors if ssl_cert is set and doesn't exist", function()
      local conf = {
        admin_gui_listen = { "0.0.0.0:8002", "0.0.0.0:8445 ssl" },
        admin_gui_ssl_cert = "/path/to/cert",
      }

      ee_conf_loader.validate_admin_gui_ssl(conf, msgs)
      local expected = {
        "admin_gui_ssl_cert_key must be specified",
        "admin_gui_ssl_cert: no such file at /path/to/cert",
      }

      assert.same(expected, msgs)
    end)

    it("returns errors if ssl_cert_key is set and file not found", function()
      local conf = {
        admin_gui_listen = { "0.0.0.0:8002", "0.0.0.0:8445 ssl" },
        admin_gui_ssl_cert_key = "/path/to/cert",
      }

      ee_conf_loader.validate_admin_gui_ssl(conf, msgs)
      local expected = {
        "admin_gui_ssl_cert must be specified",
        "admin_gui_ssl_cert_key: no such file at /path/to/cert",
      }

      assert.same(expected, msgs)
    end)

    it("returns {} if ssl_cert and ssl_cert_key are not set", function()
      local conf = {
        some_other_key = "foo",
        admin_gui_listen = { "0.0.0.0:8002" },
      }

      ee_conf_loader.validate_admin_gui_ssl(conf, msgs)
      assert.same({}, msgs)
    end)

    it("returns {} if admin_gui_listen doesn't include SSL", function()
      local conf = {
        admin_gui_listen = { "0.0.0.0:8002" },
        admin_gui_ssl_cert_key = "/path/to/cert",
      }

      ee_conf_loader.validate_admin_gui_ssl(conf, msgs)
      assert.same({}, msgs)
    end)
  end)

  describe("validate_tracing", function()
    it("requires a write endpoint when enabled", function()
      ee_conf_loader.validate_tracing({
        tracing = true,
      }, msgs)

      local expected = {
        "'tracing_write_endpoint' must be defined when 'tracing' is enabled"
      }

      assert.same(expected, msgs)
    end)
  end)
end)
