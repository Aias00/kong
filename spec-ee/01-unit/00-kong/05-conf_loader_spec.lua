local conf_loader = require "kong.conf_loader"
local ee_conf_loader = require("kong.enterprise_edition.conf_loader")
local helpers = require "spec.helpers"

describe("Configuration loader - enterprise", function()
  it("loads the defaults", function()
    local conf = assert(conf_loader())
    assert.same({"0.0.0.0:8002", "0.0.0.0:8445 ssl"}, conf.admin_gui_listen)
    assert.same({"0.0.0.0:8003", "0.0.0.0:8446 ssl"}, conf.portal_gui_listen)
    assert.same({"0.0.0.0:8004", "0.0.0.0:8447 ssl"}, conf.portal_api_listen)
    assert.equal("logs/admin_gui_access.log", conf.admin_gui_access_log)
    assert.equal("logs/admin_gui_error.log", conf.admin_gui_error_log)
    assert.equal("logs/portal_gui_access.log", conf.portal_gui_access_log)
    assert.equal("logs/portal_gui_error.log", conf.portal_gui_error_log)
    assert.equal("logs/portal_api_access.log", conf.portal_api_access_log)
    assert.equal("logs/portal_api_error.log", conf.portal_api_error_log)
    assert.is_nil(conf.admin_gui_ssl_cert)
    assert.is_nil(conf.admin_gui_ssl_cert_key)
    assert.is_nil(conf.portal_gui_ssl_cert)
    assert.is_nil(conf.portal_gui_ssl_cert_key)
    assert.is_nil(conf.portal_api_ssl_cert)
    assert.is_nil(conf.portal_api_ssl_cert_key)
    assert.is_nil(getmetatable(conf))
  end)

  it("loads a given file, with higher precedence", function()
    local conf = assert(conf_loader(helpers.test_conf_path))
    -- defaults
    assert.equal("on", conf.nginx_daemon)
    -- overrides
    assert.same({"0.0.0.0:9999"}, conf.admin_gui_listen)
    assert.same({"0.0.0.0:9003", "0.0.0.0:9446 ssl"}, conf.portal_gui_listen)
    assert.equal("127.0.0.1:9003", conf.portal_gui_host)
    assert.equal("http", conf.portal_gui_protocol)
    assert.same({"0.0.0.0:9004", "0.0.0.0:9447 ssl"}, conf.portal_api_listen)
    assert.equal("http://127.0.0.1:9004", conf.portal_api_url)
    assert.is_nil(getmetatable(conf))
  end)

  it("extracts flags, ports and listen ips from proxy_listen/admin_listen", function()
    local conf = assert(conf_loader())
    -- portal is disabled by default
    assert.equal(nil, conf.portal_gui_listeners)
    assert.equal(nil, conf.portal_api_listeners)

    assert.equal("0.0.0.0", conf.admin_gui_listeners[1].ip)
    assert.equal(8002, conf.admin_gui_listeners[1].port)
    assert.equal(false, conf.admin_gui_listeners[1].ssl)
    assert.equal(false, conf.admin_gui_listeners[1].http2)
    assert.equal("0.0.0.0:8000 reuseport backlog=16384", conf.proxy_listeners[1].listener)

    assert.equal("0.0.0.0", conf.admin_gui_listeners[2].ip)
    assert.equal(8445, conf.admin_gui_listeners[2].port)
    assert.equal(true, conf.admin_gui_listeners[2].ssl)
    assert.equal(false, conf.admin_gui_listeners[2].http2)
    assert.equal("0.0.0.0:8445 ssl", conf.admin_gui_listeners[2].listener)
  end)

  it("attaches prefix paths", function()
    local conf = assert(conf_loader())
    assert.equal("/usr/local/kong/ssl/admin-gui-kong-default.crt", conf.admin_gui_ssl_cert_default)
    assert.equal("/usr/local/kong/ssl/admin-gui-kong-default.key", conf.admin_gui_ssl_cert_key_default)
    assert.equal("/usr/local/kong/ssl/portal-gui-kong-default.crt", conf.portal_gui_ssl_cert_default)
    assert.equal("/usr/local/kong/ssl/portal-gui-kong-default.key", conf.portal_gui_ssl_cert_key_default)
    assert.equal("/usr/local/kong/ssl/portal-api-kong-default.crt", conf.portal_api_ssl_cert_default)
    assert.equal("/usr/local/kong/ssl/portal-api-kong-default.key", conf.portal_api_ssl_cert_key_default)
  end)

  describe("validations", function()
    it("enforces enforce_rbac values", function()
      local conf, _, errors = conf_loader(nil, {
        enforce_rbac = "foo",
      })
      assert.equal(1, #errors)
      assert.is_nil(conf)
    end)

    it("enforces admin_gui_auth if admin_gui_auth_conf is present", function()
      local conf, err = conf_loader(nil, {
        admin_gui_auth_conf = "{ \"hide_credentials\": true }",
        enforce_rbac = "on",
      })
      assert.is_nil(conf)
      assert.equal("admin_gui_auth_conf is set with no admin_gui_auth", err)
    end)

    it("enforces valid json for admin_gui_auth_conf", function()
      local conf, err = conf_loader(nil, {
        admin_gui_auth = "basic-auth",
        admin_gui_auth_conf = "{ \"hide_credentials\": derp }",
        enforce_rbac = "on",
      })
      assert.is_nil(conf)
      assert.equal("admin_gui_auth_conf must be valid json or not set: Expected value but found invalid token at character 23 - { \"hide_credentials\": derp }", err)
    end)

    it("#flaky enforces listen addresses format", function()
      local err_str = "must be of form: [off] | <ip>:<port> [ssl] [http2] [proxy_protocol] [deferred] [bind] [reuseport] [backlog=%d+], [... next entry ...]"
      local conf, err = conf_loader(nil, {
        admin_gui_listen = "127.0.0.1"
      })
      assert.is_nil(conf)
      assert.equal("admin_gui_listen " .. err_str, err)

      conf, err = conf_loader(nil, {
        portal = "on",
        smtp_mock = "on",
        portal_gui_listen = "127.0.0.1",
        portal_token_exp = 21600,
      })
      assert.is_nil(conf)
      assert.equal("portal_gui_listen " .. err_str, err)

      conf, err = conf_loader(nil, {
        portal = "on",
        smtp_mock = "on",
        portal_api_listen = "127.0.0.1",
        portal_token_exp = 21600,
      })
      assert.is_nil(conf)
      assert.equal("portal_api_listen " .. err_str, err)
    end)

    it("enforces positive number for portal_token_exp ", function()
      local conf, err = conf_loader(nil, {
        portal = "on",
        smtp_mock = "on",
        portal_api_listen = "0.0.0.0:8004, 0.0.0.0:8447 ssl",
        portal_token_exp = 0,
      })
      assert.is_nil(conf)
      assert.equal("portal_token_exp must be a positive number", err)

      conf, err = conf_loader(nil, {
        portal = "on",
        smtp_mock = "on",
        portal_api_listen = "0.0.0.0:8004, 0.0.0.0:8447 ssl",
        portal_token_exp = "whut",
      })
      assert.is_nil(conf)
      assert.equal("portal_token_exp must be a positive number", err)

      conf, err = conf_loader(nil, {
        portal = "on",
        smtp_mock = "on",
        portal_api_listen = "0.0.0.0:8004, 0.0.0.0:8447 ssl",
        portal_token_exp = -1,
      })
      assert.is_nil(conf)
      assert.equal("portal_token_exp must be a positive number", err)

      conf, err = conf_loader(nil, {
        portal = "on",
        smtp_mock = "on",
        portal_api_listen = "0.0.0.0:8004, 0.0.0.0:8447 ssl",
        portal_token_exp = false,
      })
      assert.is_nil(conf)
      assert.equal("portal_token_exp must be a positive number", err)
    end)

    it("enforces smtp credentials when smtp_mock is off", function()
      local _, err = conf_loader(nil, {
        portal = "off",
        smtp_mock = "off",
      })
      assert.is_nil(err)

      local conf, err = conf_loader(nil, {
        portal = "off",
        smtp_mock = "off",
        smtp_auth_type = "weirdo",
      })
      assert.is_nil(conf)
      assert.equal("smtp_auth_type must be 'plain', 'login', or nil", err)

      local conf, err = conf_loader(nil, {
        portal = "off",
        smtp_mock = "off",
        smtp_auth_type = "plain",
      })
      assert.is_nil(conf)
      assert.equal("smtp_username must be set when using smtp_auth_type", err)

      local conf, err = conf_loader(nil, {
        portal = "off",
        smtp_mock = "off",
        smtp_auth_type = "plain",
        smtp_username = "meme_lord"
      })
      assert.is_nil(conf)
      assert.equal("smtp_password must be set when using smtp_auth_type", err)

      local _, err = conf_loader(nil, {
        portal = "off",
        smtp_mock = "off",
        smtp_auth_type = "plain",
        smtp_username = "meme_lord",
        smtp_password = "dank memes"
      })
      assert.is_nil(err)
    end)

    it("enforces portal_session_conf must be valid json", function()
      local _, err = conf_loader(nil, {
        portal = "on",
        portal_auth = "basic-auth",
        portal_session_conf = "{ \"cookie_name\": \"portal_session\", \"secret\": \"super-secret\", \"cookie_secure\": false, \"storage\": \"kong\" }",
      })
      assert.is_nil(err)

      local conf, err = conf_loader(nil, {
        portal = "on",
        portal_auth = "basic-auth",
        portal_session_conf = "wow",
      })
      assert.is_nil(conf)
      assert.equal("portal_session_conf must be valid json or not set: Expected value but found invalid token at character 1 - wow", err)
    end)

    it("enforces portal_session_conf when portal_auth is set to something other than openid-connect", function()
      local _, err = conf_loader(nil, {
        portal = "on",
        portal_auth = "basic-auth",
        portal_session_conf = "{ \"cookie_name\": \"portal_session\", \"secret\": \"super-secret\", \"cookie_secure\": false, \"storage\": \"kong\" }",
      })
      assert.is_nil(err)

      local _, err = conf_loader(nil, {
        portal = "on",
        portal_auth = "openid-connect",
      })
      assert.is_nil(err)

      local conf, err = conf_loader(nil, {
        portal = "on",
        portal_auth = "basic-auth",
      })
      assert.is_nil(conf)
      assert.equal("portal_session_conf is required when portal_auth is set to basic-auth", err)
    end)

    it("enforces portal_session_conf 'secret' must be type 'string'", function()
      local _, err = conf_loader(nil, {
        portal = "on",
        portal_auth = "basic-auth",
        portal_session_conf = "{ \"secret\": \"super-secret\" }",
      })
      assert.is_nil(err)

      local conf, err = conf_loader(nil, {
        portal = "on",
        portal_auth = "basic-auth",
        portal_session_conf = "{}",
      })
      assert.is_nil(conf)
      assert.equal("portal_session_conf 'secret' must be type 'string'", err)
    end)
  end)

  describe("vitals strategy", function()
    it("disabled by default", function()
      local conf = assert(conf_loader(helpers.test_conf_path, {
      }))
      assert.equal("database", conf.vitals_strategy)
    end)
    it("can be set to database", function()
      local conf = assert(conf_loader(helpers.test_conf_path, {
        vitals_strategy = "database",
      }))
      assert.equal("database", conf.vitals_strategy)
    end)
    it("can be set to prometheus", function()
      local conf = assert(conf_loader(helpers.test_conf_path, {
        vitals_strategy = "prometheus",
        vitals_tsdb_address = "127.0.0.1:9090",
        vitals_statsd_address = "127.0.0.1:8125",
      }))
      assert.equal("prometheus", conf.vitals_strategy)
    end)
    it("can't be set to other strategy", function()
      local ok, err = conf_loader(helpers.test_conf_path, {
        vitals_strategy = "sometsdb"
      })
      assert.is_nil(ok)
      assert.same("vitals_strategy must be one of \"database\", \"prometheus\", or \"influxdb\"", err)
    end)
    it("errors if vitals_tsdb_address and vitals_statsd_address not set " ..
       "with prometheus strategy", function()

      local expected = "vitals_statsd_address must be defined " ..
      "when vitals_strategy is set to \"prometheus\""
      local ok, err = conf_loader(helpers.test_conf_path, {
        vitals_strategy = "prometheus",
        vitals_tsdb_address = "127.0.0.1:9090",
      })
      assert.is_nil(ok)
      assert.same(expected, err)

      for _, strategy in ipairs({"prometheus", "influxdb"}) do
        expected = 'vitals_tsdb_address must be defined when vitals_strategy = "prometheus" or "influxdb"'
        local ok, err = conf_loader(helpers.test_conf_path, {
          vitals_strategy = strategy,
        })
        assert.is_nil(ok)
        assert.same(expected, err)
      end

      local ok, err = conf_loader(helpers.test_conf_path, {
        vitals_strategy = "prometheus",
      })
      assert.is_nil(ok)
      assert.same(expected, err)
    end)
  end)
end)

describe("ee conf loader", function()
  local msgs
  before_each(function()
    msgs = {}
  end)

  describe("validate_enforce_rbac()", function()
    it("returns error if admin_gui_auth is set and enforce_rbac off", function()
      local _, err = ee_conf_loader.validate_enforce_rbac({ admin_gui_auth = "basic-auth",
                                             enforce_rbac = "off",
                                           })

      local expected = "RBAC authorization is off" ..
                         " and admin_gui_auth is 'basic-auth'"

      assert.same(expected, err)
    end)

    it("returns error if admin_gui_auth not set and enforce_rbac on", function()
      local _, err = ee_conf_loader.validate_enforce_rbac({ enforce_rbac = "on" })

      local expected = "RBAC authorization is on" ..
                         " and admin_gui_auth is 'nil'"

      assert.same(expected, err)
    end)

    it("returns nil if admin_gui_auth not set and enforce_rbac off", function()
      local _, err = ee_conf_loader.validate_enforce_rbac({ enforce_rbac = "off" })

      assert.is_nil(err)
    end)

    it("returns nil if admin_gui_auth is set and enforce_rbac on", function()
      local _, err = ee_conf_loader.validate_enforce_rbac({ admin_gui_auth = "basic-auth",
                                             enforce_rbac = "on" })

      assert.is_nil(err)
    end)
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

  describe("portal_app_auth", function()
    it("no errors for unset", function()
      ee_conf_loader.validate_portal_app_auth({
      }, msgs)


      assert.same({}, msgs)
    end)

    it("accepts kong-oauth", function()
      ee_conf_loader.validate_portal_app_auth({
        portal_app_auth = "kong-oauth2",
      }, msgs)


      assert.same({}, msgs)
    end)

    it("does not accept invalid string", function()
      ee_conf_loader.validate_portal_app_auth({
        portal_app_auth = "not-valid",
      }, msgs)

      local expected = {
        "portal_app_auth must be not set or one of: kong-oauth2, external-oauth2"
      }

      assert.same(expected, msgs)
    end)
  end)
end)
