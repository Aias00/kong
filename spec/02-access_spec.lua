-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local helpers = require "spec.helpers"
local cjson   = require "cjson"
local utils   = require "kong.tools.utils"


local UDP_PORT = 35001


local CA = [[
-----BEGIN CERTIFICATE-----
MIIFoTCCA4mgAwIBAgIUQDBLwIychoRbVRO44IzBBk9R4oYwDQYJKoZIhvcNAQEL
BQAwWDELMAkGA1UEBhMCVVMxEzARBgNVBAgMCkNhbGlmb3JuaWExFTATBgNVBAoM
DEtvbmcgVGVzdGluZzEdMBsGA1UEAwwUS29uZyBUZXN0aW5nIFJvb3QgQ0EwHhcN
MTkwNTAyMTkzNDQyWhcNMzkwNDI3MTkzNDQyWjBYMQswCQYDVQQGEwJVUzETMBEG
A1UECAwKQ2FsaWZvcm5pYTEVMBMGA1UECgwMS29uZyBUZXN0aW5nMR0wGwYDVQQD
DBRLb25nIFRlc3RpbmcgUm9vdCBDQTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCC
AgoCggIBAMp6IggUp3aSNRbLAac8oOkrbUnFuxtlKGYgg8vfA2UU71qTktigdwO6
Kod0/M+daO3RDqJJXQL2rD14NDO3MaextICanoQSEe+nYyMFUIk+QplXLD3fbshU
nHoJcMS2w0x4cm1os4ebxR2Evndo6luz39ivcjau+BL+9iBAYL1g6+eGOjcSy7ft
1nAMvbxcQ7dmbAH2KP6OmF8cok+eQWVqXEjqtVx5GDMDlj1BjX6Kulmh/vhNi3Hr
NEi+kPrw/YtRgnqnN0sv3NnAyKnantxy7w0TDicFjiBsSIhjB5aUfWYErBR+Nj/m
uumwc/kRJcHWklqDzxrZKCIyOyWcE5Dyjjr46cnF8HxhYwgZcwkmgTtaXOLpBMlo
XUTgOQrWpm9HYg2vOJMMA/ZPUJ2tJ34/4RgiA00EJ5xG8r24suZmT775l+XFLFzp
Ihxvs3BMbrWsXlcZkI5neNk7Q/1jLoBhWeTYjMpUS7bJ/49YVGQZFs3xu2IcLqeD
5WsB1i+EqBAI0jm4vWEynsyX+kS2BqAiDtCsS6WYT2q00DTeP5eIHh/vHsm75jJ+
yUEb1xFxGnNevLKNTcHUeXxPUnowdC6wqFnaJm7l09qVGDom7tLX9i6MCojgpAP0
hMpBxzh8jLxHh+zZQdiORSFdYxNnlnWwbic2GUJruiQVLuhpseenAgMBAAGjYzBh
MB0GA1UdDgQWBBQHT/IIheEC2kdBxI/TfGqUxWJw9zAfBgNVHSMEGDAWgBQHT/II
heEC2kdBxI/TfGqUxWJw9zAPBgNVHRMBAf8EBTADAQH/MA4GA1UdDwEB/wQEAwIB
hjANBgkqhkiG9w0BAQsFAAOCAgEAqXZjy4EltJCRtBmN0ohAHPWqH4ZJQCI2HrM3
wHB6c4oPWcJ+M2PfmYPUJo9VMjvn4S3sZuAysyoHduvRdGDnElW4wglL1xxpoUOx
FqoZUoYWV8hDFmUTWM5b4CtJxOPdTAd8VgypulM3iUEzBQrjR6tnMOdkiFMOmVag
0/Nnr+Tcfk/crMCx3xsVnisYjJoQBFBH4UY+gWE/V/MS1Sya4/qTbuuCUq+Qym5P
r8TkWAJlg7iVVLbZ2j94VUdpiQPWJEGMtJck/NEmOTruhhQlT7c1u/lqXCGj7uci
LmhLsBVmdtWT9AWS8Rl7Qo5GXbjxKIaP3IM9axhDLm8WHwPRLx7DuIFEc+OBxJhz
wkr0g0yLS0AMZpaC6UGbWX01ed10U01mQ/qPU5uZiB0GvruwsYWZsyL1QXUeqLz3
/KKrx3XsXjtBu3ZG4LAnwuxfeZCNw9ofg8CqF9c20ko+7tZAv6DCu9UL+2oZnEyQ
CboRDwpnAlQ7qJVSp2xMgunO3xxVMlhD5LZpEJz1lRT0nQV3uuLpMYNM4FS9OW/X
MZSzwHhDdCTDWtc/iRszimOnYYV8Y0ubJcb59uhwcsHmdfnwL9DVO6X5xyzb8wsf
wWaPbub8SN2jKnT0g6ZWuca4VwEo1fRaBkzSZDqXwhkBDWP8UBqLXMXWHdZaT8NK
0NEO74c=
-----END CERTIFICATE-----
]]

local mtls_fixtures = { http_mock = {
  mtls_server_block = [[
    server {
        server_name mtls_test_client;
        listen 10121;

        location = /example_client {
            proxy_ssl_certificate ../spec/fixtures/client_example.com.crt;
            proxy_ssl_certificate_key ../spec/fixtures/client_example.com.key;
            proxy_ssl_name example.com;
            # enable send the SNI sent to server
            proxy_ssl_server_name on;
            proxy_set_header Host example.com;

            proxy_pass https://127.0.0.1:9443/get;
        }

        location = /bad_client {
            proxy_ssl_certificate ../spec/fixtures/bad_client.crt;
            proxy_ssl_certificate_key ../spec/fixtures/bad_client.key;
            proxy_ssl_name example.com;
            proxy_set_header Host example.com;

            proxy_pass https://127.0.0.1:9443/get;
        }

        location = /no_san_client {
            proxy_ssl_certificate ../spec/fixtures/no_san.crt;
            proxy_ssl_certificate_key ../spec/fixtures/no_san.key;
            proxy_ssl_name example.com;
            proxy_set_header Host example.com;

            proxy_pass https://127.0.0.1:9443/get;
        }
    }
  ]], }
}

for _, strategy in helpers.each_strategy() do
  describe("Plugin: mtls-auth (access) [#" .. strategy .. "]", function()
    local proxy_client, admin_client, proxy_ssl_client, mtls_client
    local bp, db
    local anonymous_user, consumer, customized_consumer, service, route
    local plugin
    local ca_cert

    lazy_setup(function()
      bp, db = helpers.get_db_utils(strategy, {
        "routes",
        "services",
        "plugins",
        "consumers",
        "ca_certificates",
        "mtls_auth_credentials",
      }, { "mtls-auth", })

      anonymous_user = bp.consumers:insert {
        username = "anonymous@example.com",
      }

      consumer = bp.consumers:insert {
        username = "foo@example.com"
      }

      customized_consumer = bp.consumers:insert {
        username = "customized@example.com"
      }

      service = bp.services:insert{
        protocol = "https",
        port     = 443,
        host     = "httpbin.org",
      }

      route = bp.routes:insert {
        hosts   = { "example.com" },
        service = { id = service.id, },
      }

      ca_cert = assert(db.ca_certificates:insert({
        cert = CA,
      }))

      plugin = assert(bp.plugins:insert {
        name = "mtls-auth",
        route = { id = route.id },
        config = { ca_certificates = { ca_cert.id, }, },
      })

      bp.plugins:insert {
        route = { id = route.id },
        name     = "udp-log",
        config   = {
          host   = "127.0.0.1",
          port   = UDP_PORT
        },
      }


      assert(helpers.start_kong({
        database   = strategy,
        plugins = "bundled,mtls-auth",
        nginx_conf = "spec/fixtures/custom_nginx.template",
      }, nil, nil, mtls_fixtures))

      proxy_client = helpers.proxy_client()
      proxy_ssl_client = helpers.proxy_ssl_client()
      mtls_client = helpers.http_client("127.0.0.1", 10121)
      admin_client = helpers.admin_client()
    end)

    lazy_teardown(function()
      if proxy_client then
        proxy_client:close()
      end

      if proxy_ssl_client then
        proxy_ssl_client:close()
      end

      if mtls_client then
        mtls_client:close()
      end

      if admin_client then
        admin_client:close()
      end

      helpers.stop_kong()
    end)

    describe("Unauthorized", function()
      it("returns HTTP 401 on non-https request", function()
        local res = assert(proxy_client:send {
          method  = "GET",
          path    = "/get",
          headers = {
            ["Host"] = "example.com"
          }
        })
        local body = assert.res_status(401, res)
        local json = cjson.decode(body)
        assert.same({ message = "No required TLS certificate was sent" }, json)
      end)

      it("returns HTTP 401 on https request if mutual TLS was not completed", function()
        local res = assert(proxy_ssl_client:send {
          method  = "GET",
          path    = "/get",
          headers = {
            ["Host"] = "example.com"
          }
        })
        local body = assert.res_status(401, res)
        local json = cjson.decode(body)
        assert.same({ message = "No required TLS certificate was sent" }, json)
      end)

      it("returns HTTP 401 on https request if certificate validation failed", function()
        local res = assert(mtls_client:send {
          method  = "GET",
          path    = "/bad_client",
        })
        local body = assert.res_status(401, res)
        local json = cjson.decode(body)
        assert.same({ message = "TLS certificate failed verification" }, json)
      end)
    end)

    describe("valid certificate", function()
      it("returns HTTP 200 on https request if certificate validation passed", function()
        local res = assert(mtls_client:send {
          method  = "GET",
          path    = "/example_client",
        })
        local body = assert.res_status(200, res)
        local json = cjson.decode(body)
        assert.equal("foo@example.com", json.headers["X-Consumer-Username"])
        assert.equal(consumer.id, json.headers["X-Consumer-Id"])
        assert.equal("consumer-id-2", json.headers["X-Consumer-Custom-Id"])
      end)

      it("returns HTTP 401 on https request if certificate validation passed", function()
        local res = assert(mtls_client:send {
          method  = "GET",
          path    = "/no_san_client",
        })
        assert.res_status(401, res)
      end)

      it("overrides client_verify field in basic log serialize so it contains sensible content #4626", function()
        local udp_thread = helpers.udp_server(UDP_PORT)

        local res = assert(mtls_client:send {
          method  = "GET",
          path    = "/example_client",
        })
        assert.res_status(200, res)

        -- Getting back the UDP server input
        local ok, res = udp_thread:join()
        assert.True(ok)
        assert.is_string(res)

        -- Making sure it's alright
        local log_message = cjson.decode(res)
        assert.equal("SUCCESS", log_message.request.tls.client_verify)
      end)
    end)

    describe("custom credential", function()
      lazy_setup(function()
        local res = assert(admin_client:send({
          method  = "POST",
          path    = "/consumers/" .. customized_consumer.id  .. "/mtls-auth",
          body    = {
            subject_name   = "foo@example.com"
          },
          headers = {
            ["Content-Type"] = "application/json"
          }
        }))
        assert.res_status(201, res)
      end)

      it("overrides auto-matching", function()
        local res = assert(mtls_client:send {
          method  = "GET",
          path    = "/example_client",
        })
        local body = assert.res_status(200, res)
        local json = cjson.decode(body)
        assert.equal("customized@example.com", json.headers["X-Consumer-Username"])
        assert.equal(customized_consumer.id, json.headers["X-Consumer-Id"])
        assert.equal("consumer-id-3", json.headers["X-Consumer-Custom-Id"])
      end)
    end)

    describe("skip consumer lookup with valid certificate", function()
      lazy_setup(function()
        local res = assert(admin_client:send({
          method  = "PATCH",
          path    = "/plugins/" .. plugin.id,
          body    = {
            config = { skip_consumer_lookup = true, },
          },
          headers = {
            ["Content-Type"] = "application/json"
          }
        }))
        assert.res_status(200, res)
      end)
      lazy_teardown(function()
        local res = assert(admin_client:send({
          method  = "PATCH",
          path    = "/plugins/" .. plugin.id,
          body    = {
            config = { skip_consumer_lookup = false, },
          },
          headers = {
            ["Content-Type"] = "application/json"
          }
        }))
        assert.res_status(200, res)
      end)
      it("returns HTTP 200 on https request if certificate validation passed", function()
        local res = assert(mtls_client:send {
          method  = "GET",
          path    = "/example_client",
        })
        local body = assert.res_status(200, res)
        local json = cjson.decode(body)
        assert.is_nil(json.headers["X-Consumer-Username"])
        assert.is_nil(json.headers["X-Consumer-Id"])
        assert.is_nil(json.headers["X-Consumer-Custom-Id"])
        assert.not_nil(json.headers["X-Client-Cert-San"])
        assert.not_nil(json.headers["X-Client-Cert-Dn"])
      end)

      it("returns HTTP 401 on https request if certificate validation failed", function()
        local res = assert(mtls_client:send {
          method  = "GET",
          path    = "/bad_client",
        })
        assert.res_status(401, res)
      end)
    end)

    describe("config.anonymous", function()
      lazy_setup(function()
        local res = assert(admin_client:send({
          method  = "PATCH",
          path    = "/plugins/" .. plugin.id,
          body    = {
            config = { anonymous = anonymous_user.id, },
          },
          headers = {
            ["Content-Type"] = "application/json"
          }
        }))
        assert.res_status(200, res)
      end)

      it("works with right credentials and anonymous", function()
        local res = assert(mtls_client:send {
          method  = "GET",
          path    = "/example_client",
        })
        local body = assert.res_status(200, res)
        local json = cjson.decode(body)
        assert.equal("customized@example.com", json.headers["X-Consumer-Username"])
        assert.equal(customized_consumer.id, json.headers["X-Consumer-Id"])
        assert.equal("consumer-id-3", json.headers["X-Consumer-Custom-Id"])
        assert.is_nil(json.headers["X-Anonymous-Consumer"])
      end)

      it("works with wrong credentials and anonymous", function()
        local res = assert(mtls_client:send {
          method  = "GET",
          path    = "/bad_client",
        })
        local body = assert.res_status(200, res)
        local json = cjson.decode(body)
        assert.equal("anonymous@example.com", json.headers["X-Consumer-Username"])
        assert.equal(anonymous_user.id, json.headers["X-Consumer-Id"])
        assert.equal("consumer-id-1", json.headers["X-Consumer-Custom-Id"])
        assert.equal("true", json.headers["X-Anonymous-Consumer"])
      end)

      it("logging with wrong credentials and anonymous", function()
        local udp_thread = helpers.udp_server(UDP_PORT)

        local res = assert(mtls_client:send {
          method  = "GET",
          path    = "/bad_client",
        })
        assert.res_status(200, res)

        -- Getting back the UDP server input
        local ok, res = udp_thread:join()
        assert.True(ok)
        assert.is_string(res)

        -- Making sure it's alright
        local log_message = cjson.decode(res)
        assert.equal("FAILED:self signed certificate", log_message.request.tls.client_verify)
      end)

      it("works with http (no mTLS handshake)", function()
        local res = assert(proxy_client:send {
          method  = "GET",
          path    = "/get",
          headers = {
            ["Host"] = "example.com"
          }
        })
        local body = assert.res_status(200, res)
        local json = cjson.decode(body)
        assert.equal("anonymous@example.com", json.headers["X-Consumer-Username"])
        assert.equal(anonymous_user.id, json.headers["X-Consumer-Id"])
        assert.equal("consumer-id-1", json.headers["X-Consumer-Custom-Id"])
        assert.equal("true", json.headers["X-Anonymous-Consumer"])
      end)

      it("logging with https (no mTLS handshake)", function()
        local udp_thread = helpers.udp_server(UDP_PORT)

        local res = assert(proxy_ssl_client:send {
          method  = "GET",
          path    = "/get",
          headers = {
            ["Host"] = "example.com"
          }
        })
        assert.res_status(200, res)

        local res = assert(mtls_client:send {
          method  = "GET",
          path    = "/bad_client",
        })
        assert.res_status(200, res)

        -- Getting back the UDP server input
        local ok, res = udp_thread:join()
        assert.True(ok)
        assert.is_string(res)

        -- Making sure it's alright
        local log_message = cjson.decode(res)
        assert.equal("NONE", log_message.request.tls.client_verify)
      end)


      it("errors when anonymous user doesn't exist", function()
        local res = assert(admin_client:send({
          method  = "PATCH",
          path    = "/plugins/" .. plugin.id,
          body    = {
            config = { anonymous = "00000000-0000-0000-0000-000000000000", },
          },
          headers = {
            ["Content-Type"] = "application/json"
          }
        }))
        assert.res_status(200, res)

        local res = assert(proxy_client:send {
          method  = "GET",
          path    = "/get",
          headers = {
            ["Host"] = "example.com"
          }
        })
        assert.res_status(500, res)
      end)
    end)

    describe("errors", function()
      lazy_setup(function()
        local res = assert(admin_client:send({
          method  = "PATCH",
          path    = "/plugins/" .. plugin.id,
          body    = {
            config = { ca_certificates = { ca_cert.id, }, },
          },
          headers = {
            ["Content-Type"] = "application/json"
          }
        }))
        assert.res_status(200, res)
      end)

      it("errors when CA doesn't exist", function()
        local res = assert(admin_client:send({
          method  = "PATCH",
          path    = "/plugins/" .. plugin.id,
          body    = {
            config = { ca_certificates = { '00000000-0000-0000-0000-000000000000', }, },
          },
          headers = {
            ["Content-Type"] = "application/json"
          }
        }))
        assert.res_status(400, res)

        local res = assert(mtls_client:send {
          method  = "GET",
          path    = "/example_client",
        })
        assert.res_status(200, res)

      end)
    end)
  end)

  describe("Plugin: mtls-auth (access) with filter [#" .. strategy .. "]", function()
    local proxy_client, admin_client, mtls_client
    local proxy_ssl_client_foo, proxy_ssl_client_bar, proxy_ssl_client_alice
    local bp, db
    local service
    local ca_cert

    lazy_setup(function()
      bp, db = helpers.get_db_utils(strategy, {
        "routes",
        "services",
        "plugins",
        "consumers",
        "ca_certificates",
        "mtls_auth_credentials",
        "workspaces",
      }, { "mtls-auth", })

      bp.consumers:insert {
        username = "foo@example.com"
      }

      bp.consumers:insert {
        username = "customized@example.com"
      }

      service = bp.services:insert{
        protocol = "https",
        port     = 443,
        host     = "httpbin.org",
      }

      assert(bp.routes:insert {
        hosts   = { "foo.com" },
        service = { id = service.id, },
        snis = { "foo.com" },
      })

      assert(bp.routes:insert {
        hosts   = { "bar.com" },
        service = { id = service.id, },
        snis = { "bar.com" },
      })

      ca_cert = assert(db.ca_certificates:insert({
        cert = CA,
      }))

      assert(bp.plugins:insert {
        name = "mtls-auth",
        config = { ca_certificates = { ca_cert.id, }, },
        service = { id = service.id, },
      })

      local service2 = bp.services:insert{
        protocol = "https",
        port     = 443,
        host     = "httpbin.org",
      }

      assert(bp.routes:insert {
        hosts   = { "alice.com" },
        service = { id = service2.id, },
        snis = { "alice.com" },
      })

      assert(helpers.start_kong({
        database   = strategy,
        plugins = "bundled,mtls-auth",
        nginx_conf = "spec/fixtures/custom_nginx.template",
      }, nil, nil, mtls_fixtures))

      proxy_client = helpers.proxy_client()
      proxy_ssl_client_foo = helpers.proxy_ssl_client(nil, "foo.com")
      proxy_ssl_client_bar = helpers.proxy_ssl_client(nil, "bar.com")
      proxy_ssl_client_alice = helpers.proxy_ssl_client(nil, "alice.com")
      mtls_client = helpers.http_client("127.0.0.1", 10121)
      admin_client = helpers.admin_client()
    end)

    lazy_teardown(function()
      if proxy_client then
        proxy_client:close()
      end

      if proxy_ssl_client_foo then
        proxy_ssl_client_foo:close()
      end

      if proxy_ssl_client_bar then
        proxy_ssl_client_bar:close()
      end

      if proxy_ssl_client_alice then
        proxy_ssl_client_alice:close()
      end

      if mtls_client then
        mtls_client:close()
      end

      if admin_client then
        admin_client:close()
      end

      helpers.stop_kong(nil, true)
    end)

    describe("request certs for specific routes", function()
      it("request cert for host foo", function()
        local res = assert(proxy_ssl_client_foo:send {
          method  = "GET",
          path    = "/get",
          headers = {
            ["Host"] = "foo.com"
          }
        })
        local body = assert.res_status(401, res)
        local json = cjson.decode(body)
        assert.same({ message = "No required TLS certificate was sent" }, json)
      end)

      it("request cert for host for host bar", function()
        local res = assert(proxy_ssl_client_bar:send {
          method  = "GET",
          path    = "/get",
          headers = {
            ["Host"] = "bar.com"
          }
        })
        local body = assert.res_status(401, res)
        local json = cjson.decode(body)
        assert.same({ message = "No required TLS certificate was sent" }, json)
      end)

      it("do not request cert for host alice", function()
        local res = assert(proxy_ssl_client_alice:send {
          method  = "GET",
          path    = "/get",
          headers = {
            ["Host"] = "alice.com"
          }
        })
        assert.res_status(200, res)
      end)

      it("request cert for specific request", function()
        local res = assert(admin_client:send {
          method  = "GET",
          path    = "/cache/mtls-auth:cert_enabled_snis",
        })
        local body = assert.res_status(200, res)
        local json = cjson.decode(body)
        assert.is_true(json["foo.com"])
        assert.is_true(json["bar.com"])
        assert.is_nil(json["*"])

      end)
    end)
    describe("request certs for all routes", function()
      it("request cert for all request", function()
        local res = assert(admin_client:send {
          method  = "POST",
          path    = "/routes",
          body = {
            hosts   = { "all.com" },
            service = { id = service.id, },
          },
          headers = {
            ["Content-Type"] = "application/json"
          }
        })
        assert.res_status(201, res)

        helpers.wait_until(function()
          local res = assert(admin_client:send {
            method  = "GET",
            path    = "/cache/mtls-auth:cert_enabled_snis",
          })
          res:read_body()
          return res.status == 404
        end)

        local res = assert(proxy_ssl_client_bar:send {
          method  = "GET",
          path    = "/get",
          headers = {
            ["Host"] = "all.com"
          }
        })
        local body = assert.res_status(401, res)
        local json = cjson.decode(body)
        assert.same({ message = "No required TLS certificate was sent" }, json)

        --helpers.wait_until(function()
        --  local client = helpers.admin_client()
        --  local res = assert(client:send {
        --    method  = "GET",
        --    path    = "/cache/mtls-auth:cert_enabled_snis",
        --  })
        --  res:read_body()
        --  if res.status == 404 then
        --    return false
        --  end
        --
        --  local raw = assert.res_status(200, res)
        --  local body = cjson.decode(raw)
        --  if body["*"] then
        --    return true
        --  end
        --end, 10)

      end)
    end)
  end)
  describe("Plugin: mtls-auth (access) with filter [#" .. strategy .. "] non default workspace", function()
    local proxy_client, admin_client, mtls_client
    local proxy_ssl_client_foo, proxy_ssl_client_example
    local bp, db
    local service, workspace, consumer
    local ca_cert

    lazy_setup(function()
      bp, db = helpers.get_db_utils(strategy, {
        "routes",
        "services",
        "plugins",
        "consumers",
        "ca_certificates",
        "mtls_auth_credentials",
        "workspaces",
      }, { "mtls-auth", })

      workspace = assert(db.workspaces:insert({ name = "test_ws_" .. utils.uuid()}))

      consumer = bp.consumers:insert({
        username = "foo@example.com"
      },  { workspace = workspace.id })

      service = bp.services:insert({
        protocol = "https",
        port     = 443,
        host     = "httpbin.org",
      }, { workspace = workspace.id })

      assert(bp.routes:insert({
        snis   = { "example.com" },
        service = { id = service.id, },
        paths = { "/get" },
        strip_path = false,
      }, { workspace = workspace.id }))

      assert(bp.routes:insert({
        service = { id = service.id, },
        paths = { "/anotherroute" },
      }, { workspace = workspace.id }))

      ca_cert = assert(db.ca_certificates:insert({
        cert = CA,
      }, { workspace = workspace.id }))

      assert(bp.plugins:insert({
        name = "mtls-auth",
        config = { ca_certificates = { ca_cert.id, }, },
        service = { id = service.id, },
      }, { workspace = workspace.id }))

      -- in default workspace:
      local service2 = bp.services:insert({
        protocol = "https",
        port     = 443,
        host     = "httpbin.org",
      })

      assert(bp.routes:insert({
        service = { id = service2.id, },
        paths = { "/default" },
      }))

      assert(helpers.start_kong({
        database   = strategy,
        plugins = "bundled,mtls-auth",
        nginx_conf = "spec/fixtures/custom_nginx.template",
      }, nil, nil, mtls_fixtures))

      proxy_client = helpers.proxy_client()
      proxy_ssl_client_foo = helpers.proxy_ssl_client(nil, "foo.com")
      proxy_ssl_client_example = helpers.proxy_ssl_client(nil, "example.com")
      mtls_client = helpers.http_client("127.0.0.1", 10121)
      admin_client = helpers.admin_client()
    end)

    lazy_teardown(function()
      if proxy_client then
        proxy_client:close()
      end

      if proxy_ssl_client_foo then
        proxy_ssl_client_foo:close()
      end

      if mtls_client then
        mtls_client:close()
      end

      if admin_client then
        admin_client:close()
      end

      helpers.stop_kong(nil, true)
    end)

    describe("filter cache is isolated per workspace", function()
      it("doesn't request cert for route that's in a different workspace", function()
        -- this maps to the default workspace
        local res = assert(proxy_ssl_client_foo:send {
          method  = "GET",
          path    = "/default",
          headers = {
            ["Host"] = "foo.com"
          }
        })
        assert.res_status(200, res)
      end)

      it("request cert for route applied the plugin", function()
        local res = assert(proxy_ssl_client_foo:send {
          method  = "GET",
          path    = "/anotherroute",
          headers = {
            ["Host"] = "foo.com"
          }
        })
        local body = assert.res_status(401, res)
        local json = cjson.decode(body)
        assert.same({ message = "No required TLS certificate was sent" }, json)
      end)

      it("still request cert for route applied the plugin", function()
        local res = assert(proxy_ssl_client_example:send {
          method  = "GET",
          path    = "/get",
          headers = {
            ["Host"] = "example.com"
          }
        })
        local body = assert.res_status(401, res)
        local json = cjson.decode(body)
        assert.same({ message = "No required TLS certificate was sent" }, json)
      end)

      it("returns HTTP 200 on https request if certificate validation passed", function()
        local res = assert(mtls_client:send {
          method  = "GET",
          path    = "/example_client",
        })
        local body = assert.res_status(200, res)
        local json = cjson.decode(body)
        assert.equal("foo@example.com", json.headers["X-Consumer-Username"])
        assert.equal(consumer.id, json.headers["X-Consumer-Id"])
        assert.equal("consumer-id-1", json.headers["X-Consumer-Custom-Id"])
      end)
    end)
  end)
end
