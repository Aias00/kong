-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local helpers = require "spec.helpers"
local utils   = require "kong.tools.utils"
local sha256   = require "kong.tools.sha256"
local cjson = require "cjson"

local ws = require "spec-ee.fixtures.websocket"
local ee_helpers = require "spec-ee.helpers"


local lower   = string.lower
local fmt     = string.format

local AD_SERVER_HOST = os.getenv("KONG_SPEC_TEST_AD_SERVER_HOST") or "ad-server"
local AD_SERVER_PORT = tonumber(os.getenv("KONG_SPEC_TEST_AD_SERVER_PORT_389")) or 389

local function cache_key(conf, username, password)
  local prefix = sha256.sha256_hex(fmt("%s:%u:%s:%s:%s:%s:%s:%s:%u",
    lower(conf.ldap_host),
    conf.ldap_port,
    conf.base_dn,
    conf.bind_dn or "",
    conf.attribute,
    conf.group_member_attribute,
    conf.group_base_dn or conf.base_dn,
    conf.group_name_attribute or conf.attribute,
    conf.cache_ttl
  ))

  return fmt("ldap_auth_cache:%s:%s:%s", prefix, username, password)
end


local ldap_host_aws = "ec2-54-172-82-117.compute-1.amazonaws.com"

local ldap_strategies = {
  non_secure = { name = "non-secure", port = 389, start_tls = false, ldaps = false},
  ldaps = { name = "ldaps", port = 636, start_tls = false, ldaps = true },
  start_tls = { name = "starttls", port = 389, start_tls = true, ldaps = false }
}

local strategies = helpers.all_strategies ~= nil and helpers.all_strategies or helpers.each_strategy

for _, strategy in strategies() do
for proto, conf in ee_helpers.each_protocol() do
  describe("Plugin: ldap-auth-advanced (access) [#" .. strategy .. "] (#" .. proto .. ")", function()
    local proxy_client
    local admin_client
    local plugin, plugin2

    local db_strategy = strategy ~= "off" and strategy or nil

    setup(function()
      local bp = helpers.get_db_utils(db_strategy, nil, { "ldap-auth-advanced" })

      if proto == "websocket" then
        bp.services:defaults({ protocol = conf.service_proto })
        bp.routes:defaults({ protocols = conf.route_protos })
        bp.plugins:defaults({ protocols = conf.route_protos })
      end

      local route = bp.routes:insert {
        hosts = { "ldap.test" }
      }

      local route2 = bp.routes:insert {
        hosts = { "ldap2.test" }
      }

      plugin = bp.plugins:insert {
        route = { id = route.id },
        name     = "ldap-auth-advanced",
        config   = {
           consumer_optional = true,
           ldap_host         = ldap_host_aws,
           ldap_password     = "password",
           ldap_port         = 389,
           bind_dn           = "uid=einstein,ou=scientists,dc=ldap,dc=mashape,dc=com",
           base_dn           = "dc=ldap,dc=mashape,dc=com",
           attribute         = "uid",
           hide_credentials  = true,
           cache_ttl         = 2,
        }
      }

      plugin2 = bp.plugins:insert {
        route = { id = route2.id },
        name     = "ldap-auth-advanced",
        config = {
          ldap_host          = AD_SERVER_HOST,
          ldap_port          = AD_SERVER_PORT,
          ldap_password      = "wrongpassword",
          attribute          = "cn",
          base_dn            = "cn=Users,dc=ldap,dc=mashape,dc=com",
          bind_dn            = "cn=Ophelia,cn=Users,dc=ldap,dc=mashape,dc=com",
          consumer_optional  = true,
          hide_credentials   = true,
          cache_ttl          = 5,
        }
      }

      assert(helpers.start_kong({
        plugins    = "ldap-auth-advanced",
        database   = db_strategy,
        nginx_conf = "spec/fixtures/custom_nginx.template",
      }, nil, nil, { http_mock = { ws = ws.mock_upstream() } }))
    end)

    before_each(function()
      proxy_client = conf.proxy_client()
      admin_client = helpers.admin_client()
    end)

    after_each(function()
      if proxy_client then
        proxy_client:close()
      end

      if admin_client then
        admin_client:close()
      end
    end)

    teardown(function()
      helpers.stop_kong()
    end)

    describe("authenticated LDAP user", function()
      it("should not fail to get data from the LDAP when plugin settings being changed from non-secure connection to StartTLS", function()
        local res = assert(proxy_client:send {
          method  = "GET",
          path    = "/get",
          body    = {},
          headers = {
            host             = "ldap.test",
            authorization    = "ldap " .. ngx.encode_base64("euclid:password"),
          }
        })
        assert.response(res).has.status(200)

        local res = assert(admin_client:send {
          method  = "PATCH",
          path    = "/plugins/" .. plugin.id,
          body    = {
            config = { start_tls = true }
          },
          headers = {
            ["Content-Type"] = "application/json"
          }
        })
        local body = assert.res_status(200, res)
        local json = cjson.decode(body)
        assert.equal(true, json.config.start_tls)

        local res = assert(proxy_client:send {
          method  = "GET",
          path    = "/get",
          body    = {},
          headers = {
            host             = "ldap.test",
            authorization    = "ldap " .. ngx.encode_base64("andrei.sakharov:password"),
          }
        })
        assert.response(res).has.status(200)

        local res = assert(admin_client:send {
          method  = "PATCH",
          path    = "/plugins/" .. plugin.id,
          body    = {
            config = { start_tls = false }
          },
          headers = {
            ["Content-Type"] = "application/json"
          }
        })
        local body = assert.res_status(200, res)
        local json = cjson.decode(body)
        assert.equal(false, json.config.start_tls)
      end)

      it("should not cache the value when an undesired error occurs", function()
        helpers.clean_logfile()
        local res = assert(proxy_client:send {
          method  = "GET",
          path    = "/get",
          body    = {},
          headers = {
            host             = "ldap2.test",
            authorization    = "ldap " .. ngx.encode_base64("User1:pass:w2rd1111A$"),
          }
        })
        assert.response(res).has.status(500)
        assert.logfile().has.line("error during bind request", true)

        local res = assert(admin_client:send {
          method  = "PATCH",
          path    = "/plugins/" .. plugin2.id,
          body    = {
            config = { ldap_password = "pass:w2rd1111A$" }
          },
          headers = {
            ["Content-Type"] = "application/json"
          }
        })
        local body = assert.res_status(200, res)
        local json = cjson.decode(body)
        assert.equal("pass:w2rd1111A$", json.config.ldap_password)

        helpers.wait_for_all_config_update({
          disable_ipv6 = true,
        })

        res = assert(proxy_client:send {
          method  = "GET",
          path    = "/get",
          body    = {},
          headers = {
            host             = "ldap2.test",
            authorization    = "ldap " .. ngx.encode_base64("User1:pass:w2rd1111A$"),
          }
        })
        assert.response(res).has.status(200)
      end)
    end)
  end)
end
end

for proto, conf in ee_helpers.each_protocol() do
for _, ldap_strategy in pairs(ldap_strategies) do
  describe("Connection strategy [" .. ldap_strategy.name .. "] (#" .. proto .. ")", function()
    for _, strategy in helpers.each_strategy() do
      describe("Plugin: ldap-auth-advanced (access) [#" .. strategy .. "]", function()
        local proxy_client
        local admin_client
        local route2
        local plugin2

        local db_strategy = strategy ~= "off" and strategy or nil

        setup(function()
          local bp = helpers.get_db_utils(db_strategy, nil, { "ldap-auth-advanced" })

          if proto == "websocket" then
            bp.services:defaults({ protocol = conf.service_proto })
            bp.routes:defaults({ protocols = conf.route_protos })
            bp.plugins:defaults({ protocols = conf.route_protos })
          end

          local route1 = bp.routes:insert {
            hosts = { "ldap.test" },
            paths = { "/" },
          }

          route2 = bp.routes:insert {
            hosts = { "ldap2.test" },
          }

          local route3 = bp.routes:insert {
            hosts = { "ldap3.test" },
          }

          local route4 = bp.routes:insert {
            hosts = { "ldap4.test" },
          }

          local route5 = bp.routes:insert {
            hosts = { "ldap5.test" },
          }

          bp.routes:insert {
            hosts = { "ldap6.test" },
          }

          local route7 = bp.routes:insert {
            hosts   = { "ldap7.test" },
          }

          local route8 = bp.routes:insert {
            hosts   = { "ldap8.test" },
          }

          local anonymous_user = bp.consumers:insert {
            username = "no-body"
          }

          bp.plugins:insert {
            route = { id = route1.id },
            name     = "ldap-auth-advanced",
            config   = {
              consumer_optional = true,
              ldap_host = ldap_host_aws,
              ldap_port = ldap_strategy.port,
              start_tls = ldap_strategy.start_tls,
              ldaps     = ldap_strategy.ldaps,
              base_dn   = "ou=scientists,dc=ldap,dc=mashape,dc=com",
              attribute = "uid"
            }
          }

          plugin2 = bp.plugins:insert {
            route = { id = route2.id },
            name     = "ldap-auth-advanced",
            config   = {
              consumer_optional     = true,
              ldap_host        = ldap_host_aws,
              ldap_port        = ldap_strategy.port,
              start_tls        = ldap_strategy.start_tls,
              ldaps            = ldap_strategy.ldaps,
              base_dn          = "ou=scientists,dc=ldap,dc=mashape,dc=com",
              attribute        = "uid",
              hide_credentials = true,
              cache_ttl        = 2,
            }
          }

          bp.plugins:insert {
            route = { id = route3.id },
            name     = "ldap-auth-advanced",
            config   = {
              consumer_optional = true,
              ldap_host = ldap_host_aws,
              ldap_port = ldap_strategy.port,
              start_tls = ldap_strategy.start_tls,
              ldaps     = ldap_strategy.ldaps,
              base_dn   = "ou=scientists,dc=ldap,dc=mashape,dc=com",
              attribute = "uid",
              anonymous = anonymous_user.id,
            }
          }

          bp.plugins:insert {
            route = { id = route4.id },
            name     = "ldap-auth-advanced",
            config   = {
              consumer_optional = true,
              ldap_host = "ec2-54-210-29-167.compute-1.amazonaws.com",
              ldap_port = ldap_strategy.port,
              start_tls = ldap_strategy.start_tls,
              ldaps     = ldap_strategy.ldaps,
              base_dn   = "ou=scientists,dc=ldap,dc=mashape,dc=com",
              attribute = "uid",
              cache_ttl = 2,
              anonymous = utils.uuid(), -- non existing consumer
            }
          }

          bp.plugins:insert {
            route = { id = route5.id },
            name     = "ldap-auth-advanced",
            config   = {
              consumer_optional = true,
              ldap_host = ldap_host_aws,
              ldap_port = ldap_strategy.port,
              start_tls = ldap_strategy.start_tls,
              ldaps     = ldap_strategy.ldaps,
              base_dn   = "ou=scientists,dc=ldap,dc=mashape,dc=com",
              attribute = "uid",
              header_type = "Basic",
            }
          }

          bp.plugins:insert {
           -- route = { id = route6.id },
            name     = "ldap-auth-advanced",
            config   = {
              consumer_optional = true,
              ldap_host = ldap_host_aws,
              ldap_port = ldap_strategy.port,
              start_tls = ldap_strategy.start_tls,
              ldaps     = ldap_strategy.ldaps,
              base_dn   = "ou=scientists,dc=ldap,dc=mashape,dc=com",
              attribute = "uid"
            }
          }

          bp.plugins:insert {
            route = { id = route7.id },
            name     = "ldap-auth-advanced",
            config   = {
              consumer_optional = true,
              ldap_host         = ldap_host_aws,
              ldap_password     = "password",
              ldap_port         = ldap_strategy.port,
              start_tls         = ldap_strategy.start_tls,
              ldaps             = ldap_strategy.ldaps,
              bind_dn           = "uid=einstein,ou=scientists,dc=ldap,dc=mashape,dc=com",
              base_dn           = "dc=ldap,dc=mashape,dc=com",
              attribute         = "uid",
              hide_credentials  = true,
              cache_ttl         = 2,
            }
          }

          bp.plugins:insert {
            route = { id = route8.id },
            name     = "ldap-auth-advanced",
            config   = {
              consumer_optional = true,
              ldap_host         = ldap_host_aws,
              ldap_password     = "password",
              ldap_port         = ldap_strategy.port,
              start_tls         = ldap_strategy.start_tls,
              ldaps             = ldap_strategy.ldaps,
              bind_dn           = "uid=einstein,ou=scientists,dc=ldap,dc=mashape,dc=com",
              base_dn           = "dc=ldap,dc=mashape,dc=com",
              attribute         = "cn",
              hide_credentials  = true,
              cache_ttl         = 2,
            }
          }

          assert(helpers.start_kong({
            plugins = "ldap-auth-advanced",
            database   = db_strategy,
            nginx_conf = "spec/fixtures/custom_nginx.template",
          }, nil, nil, { http_mock = { ws = ws.mock_upstream() } }))
        end)

        teardown(function()
          helpers.stop_kong(nil, true)
        end)

        before_each(function()
          proxy_client = conf.proxy_client()
          admin_client = helpers.admin_client()
        end)

        after_each(function()
          if proxy_client then
            proxy_client:close()
          end

          if admin_client then
            admin_client:close()
          end
        end)

        it("passes if credential is valid request with bind_dn", function()
          local res = assert(proxy_client:send {
            method  = "GET",
            path    = "/get",
            body    = {},
            headers = {
              host             = "ldap7.test",
              authorization    = "ldap " .. ngx.encode_base64("euclid:password"),
            }
          })
          assert.response(res).has.status(200)
        end)

        it("passes if credential contains non-word characters", function()
          local res = assert(proxy_client:send {
            method  = "GET",
            path    = "/get",
            body    = {},
            headers = {
              host             = "ldap7.test",
              authorization    = "ldap " .. ngx.encode_base64("andrei.sakharov:password"),
            }
          })
          assert.response(res).has.status(200)
        end)

        it("passes if password contains a colon", function()
          local res = assert(proxy_client:send {
            method  = "GET",
            path    = "/get",
            body    = {},
            headers = {
              host             = "ldap7.test",
              authorization    = "ldap " .. ngx.encode_base64("i.like.colons:pass:word"),
            }
          })
          assert.response(res).has.status(200)
        end)

        it("returns forbidden if user cannot be found with valid bind_dn", function()
          local res = assert(proxy_client:send {
            method  = "GET",
            path    = "/get",
            body    = {},
            headers = {
              host             = "ldap7.test",
              authorization    = "ldap " .. ngx.encode_base64("nobody:found"),
            }
          })
          assert.response(res).has.status(401)
          local json = assert.response(res).has.jsonbody()
          assert.equal("Unauthorized", json.message)
        end)

        it("passes if attribute is cn instead of uid with bind_dn", function()
          local res = assert(proxy_client:send {
            method  = "GET",
            path    = "/get",
            body    = {},
            headers = {
              host             = "ldap8.test",
              authorization    = "ldap " .. ngx.encode_base64("einstein:password"),
            }
          })

          assert.response(res).has.status(200)
        end)

        it("returns 'invalid credentials' and www-authenticate header when the credential is missing", function()
          local res = assert(proxy_client:send {
            method  = "GET",
            path    = "/get",
            headers = {
              host  = "ldap.test"
            }
          })
          assert.response(res).has.status(401)
          local value = assert.response(res).has.header("www-authenticate")
          assert.are.equal('LDAP realm="kong"', value)
          local json = assert.response(res).has.jsonbody()
          assert.equal("Unauthorized", json.message)
        end)
        it("returns 'invalid credentials' when credential value is in wrong format in authorization header", function()
          local res = assert(proxy_client:send {
            method  = "GET",
            path    = "/get",
            headers = {
              host  = "ldap.test",
              authorization = "abcd"
            }
          })
          assert.response(res).has.status(401)
          local json = assert.response(res).has.jsonbody()
          assert.equal("Unauthorized", json.message)
        end)
        it("returns 'invalid credentials' when credential value is in wrong format in proxy-authorization header", function()
          local res = assert(proxy_client:send {
            method  = "GET",
            path    = "/get",
            headers = {
              host  = "ldap.test",
              ["proxy-authorization"] = "abcd"
            }
          })
          assert.response(res).has.status(401)
          local json = assert.response(res).has.jsonbody()
          assert.equal("Unauthorized", json.message)
        end)
        it("returns 'invalid credentials' when credential value is missing in authorization header", function()
          local res = assert(proxy_client:send {
            method  = "GET",
            path    = "/get",
            headers = {
              host          = "ldap.test",
              authorization = "ldap "
            }
          })
          assert.response(res).has.status(401)
          local json = assert.response(res).has.jsonbody()
          assert.equal("Unauthorized", json.message)
        end)
        it("returns 'invalid credentials' when credential value is not a username-password pair in authorization header", function()
          local res = assert(proxy_client:send {
            method  = "GET",
            path    = "/get",
            headers = {
              host  = "ldap8.test",
              authorization = "ldap " .. ngx.encode_base64("abcd"),
            }
          })
          assert.response(res).has.status(401)
          local json = assert.response(res).has.jsonbody()
          assert.equal("Unauthorized", json.message)
        end)
        it("returns 'invalid credentials' when credential value doesn't contain username in authorization header", function()
          local res = assert(proxy_client:send {
            method  = "GET",
            path    = "/get",
            headers = {
              host  = "ldap8.test",
              authorization = "ldap " .. ngx.encode_base64(":password"),
            }
          })
          assert.response(res).has.status(401)
          local json = assert.response(res).has.jsonbody()
          assert.equal("Unauthorized", json.message)
        end)
        it("returns 'invalid credentials' when credential value doesn't contain password in authorization header", function()
          local res = assert(proxy_client:send {
            method  = "GET",
            path    = "/get",
            headers = {
              host  = "ldap8.test",
              authorization = "ldap " .. ngx.encode_base64("einstein:"),
            }
          })
          assert.response(res).has.status(401)
          local json = assert.response(res).has.jsonbody()
          assert.equal("Unauthorized", json.message)
        end)
        if proto ~= "websocket" then
        it("passes if credential is valid in post request", function()
          local res = assert(proxy_client:send {
            method  = "POST",
            path    = "/request",
            body    = {},
            headers = {
              host             = "ldap.test",
              authorization    = "ldap " .. ngx.encode_base64("einstein:password"),
              ["content-type"] = "application/x-www-form-urlencoded",
            }
          })
          assert.response(res).has.status(200)
        end)
        it("fails if credential type is invalid in post request", function()
          local r = assert(proxy_client:send {
            method = "POST",
            path = "/request",
            body = {},
            headers = {
              host = "ldap.test",
              authorization = "invalidldap " .. ngx.encode_base64("einstein:password"),
              ["content-type"] = "application/x-www-form-urlencoded",
            }
          })
          assert.response(r).has.status(401)
        end)
        it("passes if credential is valid and starts with space in post request", function()
          local res = assert(proxy_client:send {
            method  = "POST",
            path    = "/request",
            headers = {
              host          = "ldap.test",
              authorization = " ldap " .. ngx.encode_base64("einstein:password")
            }
          })
          assert.response(res).has.status(200)
        end)
        it("passes if signature type indicator is in caps and credential is valid in post request", function()
          local res = assert(proxy_client:send {
            method  = "POST",
            path    = "/request",
            headers = {
              host          = "ldap.test",
              authorization = "LDAP " .. ngx.encode_base64("einstein:password")
            }
          })
          assert.response(res).has.status(200)
        end)
        end
        it("passes if credential is valid in get request", function()
          local res = assert(proxy_client:send {
            method  = "GET",
            path    = "/request",
            headers = {
              host          = "ldap.test",
              authorization = "ldap " .. ngx.encode_base64("einstein:password")
            }
          })
          assert.response(res).has.status(200)
          local value = assert.request(res).has.header("x-credential-identifier")
          assert.are.equal("einstein", value)
          assert.request(res).has_not.header("x-anonymous-username")
        end)
        it("authorization fails if credential does has no password encoded in get request", function()
          local res = assert(proxy_client:send {
            method  = "GET",
            path    = "/request",
            headers = {
              host          = "ldap.test",
              authorization = "ldap " .. ngx.encode_base64("einstein:")
            }
          })
          assert.response(res).has.status(401)
        end)
        it("authorization fails with correct status with wrong very long password", function()
          local res = assert(proxy_client:send {
            method  = "GET",
            path    = "/request",
            headers = {
              host          = "ldap.test",
    	      authorization = "ldap " .. ngx.encode_base64("einstein:e0d91f53c566e0d91f53c566e0d91f53c566e0d91f53c566e0d91f53c566e0d91f53c566e0d91f53c566e0d91f53c566e0d91f53c566e0d91f53c566e0d91f53c566e0d91f53c566e0d91f53c566")
            }
          })
          assert.response(res).has.status(401)
        end)
        it("authorization fails if credential has multiple encoded usernames or passwords separated by ':' in get request", function()
          local res = assert(proxy_client:send {
            method  = "GET",
            path    = "/request",
            headers = {
              host          = "ldap.test",
              authorization = "ldap " .. ngx.encode_base64("einstein:password:another_password")
            }
          })
          assert.response(res).has.status(401)
        end)
        it("does not pass if credential is invalid in get request", function()
          local res = assert(proxy_client:send {
            method  = "GET",
            path    = "/request",
            headers = {
              host          = "ldap.test",
              authorization = "ldap " .. ngx.encode_base64("einstein:wrong_password")
            }
          })
          assert.response(res).has.status(401)
        end)
        it("does not hide credential sent along with authorization header to upstream server", function()
          local res = assert(proxy_client:send {
            method  = "GET",
            path    = "/request",
            headers = {
              host          = "ldap.test",
              authorization = "ldap " .. ngx.encode_base64("einstein:password")
            }
          })
          assert.response(res).has.status(200)
          local value = assert.request(res).has.header("authorization")
          assert.equal("ldap " .. ngx.encode_base64("einstein:password"), value)
        end)
        it("hides credential sent along with authorization header to upstream server", function()
          local res = assert(proxy_client:send {
            method  = "GET",
            path    = "/request",
            headers = {
              host          = "ldap2.test",
              authorization = "ldap " .. ngx.encode_base64("einstein:password")
            }
          })
          assert.response(res).has.status(200)
          assert.request(res).has.no.header("authorization")
        end)
        if proto ~= "websocket" then
        it("passes if custom credential type is given in post request", function()
          local r = assert(proxy_client:send {
            method = "POST",
            path = "/request",
            body = {},
            headers = {
              host = "ldap5.test",
              authorization = "basic " .. ngx.encode_base64("einstein:password"),
              ["content-type"] = "application/x-www-form-urlencoded",
            }
          })
          assert.response(r).has.status(200)
        end)
        it("fails if custom credential type is invalid in post request", function()
          local r = assert(proxy_client:send {
            method = "POST",
            path = "/request",
            body = {},
            headers = {
              host = "ldap5.test",
              authorization = "invalidldap " .. ngx.encode_base64("einstein:password"),
              ["content-type"] = "application/x-www-form-urlencoded",
            }
          })
          assert.response(r).has.status(401)
        end)
        end
        it("fails if neither authorization nor proxy-authorization header is provided", function()
          local r = assert(proxy_client:send{
            method = "GET",
            path = "/basic",
            body = {},
            headers = {
              host = "ldap5.test",
            }
          })
          assert.response(r).has.status(401)
          local value = assert.response(r).has.header("www-authenticate")
          assert.are.equal('Basic realm="kong"', value)
          local json = assert.response(r).has.jsonbody()
          assert.equal("Unauthorized", json.message)
        end)
        it("passes if credential is valid in get request using global plugin", function()
          local res = assert(proxy_client:send {
            method  = "GET",
            path    = "/request",
            headers = {
              host          = "ldap6.test",
              authorization = "ldap " .. ngx.encode_base64("einstein:password")
            }
          })
          assert.response(res).has.status(200)
          local value = assert.request(res).has.header("x-credential-identifier")
          assert.are.equal("einstein", value)
          assert.request(res).has_not.header("x-anonymous-username")
        end)
        it("caches LDAP Auth Credential", function()
          local res = assert(proxy_client:send {
            method  = "GET",
            path    = "/request",
            headers = {
              host          = "ldap2.test",
              authorization = "ldap " .. ngx.encode_base64("einstein:password")
            }
          })
          assert.response(res).has.status(200)

          -- Check that cache is populated
          local key = cache_key(plugin2.config, "einstein", "password")

          helpers.wait_until(function()
            local res = assert(admin_client:send {
              method  = "GET",
              path    = "/cache/" .. key
            })
            res:read_body()
            return res.status == 200
          end)

          -- Check that cache is invalidated
          helpers.wait_until(function()
            local res = admin_client:send {
              method  = "GET",
              path    = "/cache/" .. key
            }
            res:read_body()
            --if res.status ~= 404 then
            --  ngx.sleep( plugin2.config.cache_ttl / 5 )
            --end
            return res.status == 404
          end, plugin2.config.cache_ttl + 10)
        end)

        describe("config.anonymous", function()
          it("works with right credentials and anonymous", function()
            local res = assert(proxy_client:send {
              method  = "GET",
              path    = "/request",
              headers = {
                host          = "ldap3.test",
                authorization = "ldap " .. ngx.encode_base64("einstein:password")
              }
            })
            assert.response(res).has.status(200)

            local value = assert.request(res).has.header("x-credential-identifier")
            assert.are.equal("einstein", value)
            assert.request(res).has_not.header("x-anonymous-username")
          end)
          it("works with wrong credentials and anonymous", function()
            local res = assert(proxy_client:send {
              method  = "GET",
              path    = "/request",
              headers = {
                host  = "ldap3.test"
              }
            })
            assert.response(res).has.status(200)
            local value = assert.request(res).has.header("x-anonymous-consumer")
            assert.are.equal("true", value)
            value = assert.request(res).has.header("x-consumer-username")
            assert.equal('no-body', value)
          end)
          it("fails 500 when anonymous user doesn't exist", function()
            local res = assert(proxy_client:send {
              method  = "GET",
              path    = "/request",
              headers = {
                ["Host"] = "ldap4.test"
              }
            })
            assert.response(res).has.status(500)
          end)
        end)
      end)

      describe("Plugin: ldap-auth-advanced (access) [#" .. strategy .. "]", function()
        local proxy_client
        local user
        local anonymous
        local user_credentials

        local db_strategy = strategy ~= "off" and strategy or nil

        setup(function()
          local bp = helpers.get_db_utils(db_strategy, nil, { "ldap-auth-advanced", "ctx-checker-last" })

          if proto == "websocket" then
            bp.services:defaults({ protocol = conf.service_proto })
            bp.routes:defaults({ protocols = conf.route_protos })
            bp.plugins:defaults({ protocols = conf.route_protos })
          end


          local service1 = bp.services:insert({
            path = "/request"
          })

          local route1 = bp.routes:insert {
            hosts   = { "logical-and.test" },
            service = service1,
          }

          bp.plugins:insert {
            route = { id = route1.id },
            name     = "ldap-auth-advanced",
            config   = {
              consumer_optional = true,
              ldap_host = ldap_host_aws,
              ldap_port = ldap_strategy.port,
              start_tls = ldap_strategy.start_tls,
              ldaps     = ldap_strategy.ldaps,
              base_dn   = "ou=scientists,dc=ldap,dc=mashape,dc=com",
              attribute = "uid",
            },
          }

          bp.plugins:insert {
            name     = "key-auth",
            route = { id = route1.id },
          }

          anonymous = bp.consumers:insert {
            username = "Anonymous",
          }

          user = bp.consumers:insert {
            username = "Mickey",
          }

          local service2 = bp.services:insert({
            path = "/request"
          })

          local route2 = bp.routes:insert {
            hosts   = { "logical-or.test" },
            service = service2
          }

          bp.plugins:insert({
            name     = "ctx-checker-last",
            route = { id = route2.id },
            config   = {
              ctx_check_field = "authenticated_consumer",
            }
          })

          bp.plugins:insert {
            route = { id = route2.id },
            name     = "ldap-auth-advanced",
            config   = {
              consumer_optional = true,
              ldap_host = ldap_host_aws,
              ldap_port = ldap_strategy.port,
              start_tls = ldap_strategy.start_tls,
              ldaps     = ldap_strategy.ldaps,
              base_dn   = "ou=scientists,dc=ldap,dc=mashape,dc=com",
              attribute = "uid",
              anonymous = anonymous.id,
            },
          }

          bp.plugins:insert {
            name     = "key-auth",
            route = { id = route2.id },
            config   = {
              anonymous = anonymous.id,
            },
          }

          user_credentials = bp.keyauth_credentials:insert {
            key         = "Mouse",
            consumer = { id = user.id },
          }

          assert(helpers.start_kong({
            plugins = "ldap-auth-advanced,key-auth,ctx-checker-last",
            database   = db_strategy,
            nginx_conf = "spec/fixtures/custom_nginx.template",
          }, nil, nil, { http_mock = { ws = ws.mock_upstream() } }))

          proxy_client = conf.proxy_client()
        end)


        teardown(function()
          if proxy_client then
            proxy_client:close()
          end

          helpers.stop_kong(nil, true)
        end)

        describe("multiple auth without anonymous, logical AND", function()

          it("passes with all credentials provided", function()
            local res = assert(proxy_client:send {
              method  = "GET",
              path    = "/request",
              headers = {
                ["Host"]          = "logical-and.test",
                ["apikey"]        = "Mouse",
                ["Authorization"] = "ldap " .. ngx.encode_base64("einstein:password"),
              }
            })
            assert.response(res).has.status(200)
            assert.request(res).has.no.header("x-anonymous-consumer")
          end)

          it("fails 401, with only the first credential provided", function()
            local res = assert(proxy_client:send {
              method  = "GET",
              path    = "/request",
              headers = {
                ["Host"]   = "logical-and.test",
                ["apikey"] = "Mouse",
              }
            })
            assert.response(res).has.status(401)
          end)

          it("fails 401, with only the second credential provided", function()
            local res = assert(proxy_client:send {
              method  = "GET",
              path    = "/request",
              headers = {
                ["Host"]          = "logical-and.test",
                ["Authorization"] = "ldap " .. ngx.encode_base64("einstein:password"),
              }
            })
            assert.response(res).has.status(401)
          end)

          it("fails 401, with no credential provided", function()
            local res = assert(proxy_client:send {
              method  = "GET",
              path    = "/request",
              headers = {
                ["Host"] = "logical-and.test",
              }
            })
            assert.response(res).has.status(401)
          end)

        end)

        describe("multiple auth with anonymous, logical OR", function()

          it("passes with all credentials provided", function()
            local res = assert(proxy_client:send {
              method  = "GET",
              path    = "/request",
              headers = {
                ["Host"]          = "logical-or.test",
                ["apikey"]        = "Mouse",
                ["Authorization"] = "ldap " .. ngx.encode_base64("einstein:password"),
              }
            })
            assert.response(res).has.status(200)
            assert.request(res).has.no.header("x-anonymous-consumer")
            local consumer_id = assert.request(res).has.header("x-consumer-id")
            local credential_identifier = assert.request(res).has.header("x-credential-identifier")
            assert.not_equal(consumer_id, anonymous.id)
            assert.equal(user.id, consumer_id)  -- the apikey consumer
            assert.equal(user_credentials.id, credential_identifier) -- the apikey creds
          end)

          it("passes with only the first credential provided", function()
            local res = assert(proxy_client:send {
              method  = "GET",
              path    = "/request",
              headers = {
                ["Host"]   = "logical-or.test",
                ["apikey"] = "Mouse",
              }
            })
            assert.response(res).has.status(200)
            assert.request(res).has.no.header("x-anonymous-consumer")
            local id = assert.request(res).has.header("x-consumer-id")
            assert.not_equal(id, anonymous.id)
            assert.equal(user.id, id)
          end)

          it("passes with only the second credential provided", function()
            local res = assert(proxy_client:send {
              method  = "GET",
              path    = "/request",
              headers = {
                ["Host"]          = "logical-or.test",
                ["Authorization"] = "ldap " .. ngx.encode_base64("einstein:password"),
              }
            })
            assert.response(res).has.status(200)
            assert.request(res).has.no.header("x-anonymous-consumer")
            local id = assert.request(res).has.header("x-credential-identifier")
            assert.equal("einstein", id)
          end)

          it("passes with no credential provided", function()
            local res = assert(proxy_client:send {
              method  = "GET",
              path    = "/request",
              headers = {
                ["Host"] = "logical-or.test",
              }
            })
            assert.response(res).has.status(200)
            assert.request(res).has.header("x-anonymous-consumer")
            local id = assert.request(res).has.header("x-consumer-id")
            assert.equal(id, anonymous.id)
          end)
          if proto ~= "websocket" then
          it("check authenticated_consumer ctx", function()
            local res = assert(proxy_client:send {
              method  = "GET",
              path    = "/request",
              headers = {
                ["Host"]   = "logical-or.test",
                ["apikey"] = "Mouse",
              }
            })
            assert.response(res).has.status(200)
            assert.request(res).has.no.header("x-anonymous-consumer")
            local id = assert.request(res).has.header("x-consumer-id")
            assert.not_equal(id, anonymous.id)
            assert.equal(user.id, id)
            assert.not_nil(res.headers["ctx-checker-last-authenticated-consumer"])
            assert.matches(user.username, res.headers["ctx-checker-last-authenticated-consumer"])
          end)
          end
        end)
      end)

      describe("Plugin: ldap-auth-advanced (access) [#" .. strategy .. "]", function()
        local proxy_client, admin_client
        local bp
        local dao
        local routes
        local plugin

        local consumer_with_custom_id, consumer2_with_custom_id
        local consumer_with_username, consumer2_with_username
        local anonymous_consumer

        local db_strategy = strategy ~= "off" and strategy or nil

        setup(function()
          local _
          bp, dao, _ = helpers.get_db_utils(db_strategy, nil, { "ldap-auth-advanced" })

          if proto == "websocket" then
            bp.services:defaults({ protocol = conf.service_proto })
            bp.routes:defaults({ protocols = conf.route_protos })
            bp.plugins:defaults({ protocols = conf.route_protos })
          end


          routes = {
            bp.routes:insert {
              hosts = { "ldap.id.custom_id.username.test" },
            },

            bp.routes:insert {
              hosts = { "ldap.username.test" },
            },

            bp.routes:insert {
              hosts = { "ldap.custom_id.test" },
            },

            bp.routes:insert {
              hosts = { "ldap.anonymous.test" },
            },

            bp.routes:insert {
              hosts = { "ldap5.test" },
            },

            bp.routes:insert {
              hosts = { "ldap6.test" },
            },

            bp.routes:insert {
              hosts = { "ldap7.test" },
            },
          }

          consumer_with_username = bp.consumers:insert {
            username = "einstein"
          }

          consumer_with_custom_id = bp.consumers:insert {
            custom_id = "einstein"
          }

          consumer2_with_username = bp.consumers:insert {
            username = "euclid"
          }

          consumer2_with_custom_id = bp.consumers:insert {
            custom_id = "euclid"
          }

          anonymous_consumer = bp.consumers:insert {
            username = "whoknows"
          }

          bp.plugins:insert {
            route = { id = routes[1].id },
            name     = "ldap-auth-advanced",
            config   = {
              ldap_host = ldap_host_aws,
              ldap_port = ldap_strategy.port,
              start_tls = ldap_strategy.start_tls,
              ldaps     = ldap_strategy.ldaps,
              base_dn   = "ou=scientists,dc=ldap,dc=mashape,dc=com",
              attribute = "uid"
            }
          }

          bp.plugins:insert {
            route = { id = routes[2].id },
            name     = "ldap-auth-advanced",
            config   = {
              ldap_host = ldap_host_aws,
              ldap_port = ldap_strategy.port,
              start_tls = ldap_strategy.start_tls,
              ldaps     = ldap_strategy.ldaps,
              consumer_by = { "username" },
              base_dn   = "ou=scientists,dc=ldap,dc=mashape,dc=com",
              attribute = "uid",
            }
          }

          plugin = bp.plugins:insert {
            route = { id = routes[3].id },
            name     = "ldap-auth-advanced",
            config   = {
              ldap_host = ldap_host_aws,
              ldap_port = ldap_strategy.port,
              start_tls = ldap_strategy.start_tls,
              ldaps     = ldap_strategy.ldaps,
              consumer_by = { "custom_id" },
              base_dn   = "ou=scientists,dc=ldap,dc=mashape,dc=com",
              attribute = "uid",
              cache_ttl = 2,
            }
          }

          bp.plugins:insert {
            route = { id = routes[4].id },
            name     = "ldap-auth-advanced",
            config   = {
              ldap_host = ldap_host_aws,
              ldap_port = ldap_strategy.port,
              start_tls = ldap_strategy.start_tls,
              ldaps     = ldap_strategy.ldaps,
              base_dn   = "ou=scientists,dc=ldap,dc=mashape,dc=com",
              attribute = "uid",
              anonymous = anonymous_consumer.id
            }
          }

          bp.plugins:insert {
            route = { id = routes[5].id },
            name     = "ldap-auth-advanced",
            config   = {
              ldap_host         = ldap_host_aws,
              ldap_password     = "password",
              ldap_port         = ldap_strategy.port,
              start_tls         = ldap_strategy.start_tls,
              ldaps             = ldap_strategy.ldaps,
              bind_dn           = "uid=einstein,ou=scientists,dc=ldap,dc=mashape,dc=com",
              base_dn           = "dc=ldap,dc=mashape,dc=com",
              consumer_by       = { "custom_id" },
              attribute         = "uid",
              hide_credentials  = true,
              cache_ttl         = 2,
            }
          }

          bp.plugins:insert {
            route = { id = routes[6].id },
            name     = "ldap-auth-advanced",
            config   = {
              ldap_host         = ldap_host_aws,
              ldap_password     = "password",
              ldap_port         = ldap_strategy.port,
              start_tls         = ldap_strategy.start_tls,
              ldaps             = ldap_strategy.ldaps,
              bind_dn           = "uid=einstein,ou=scientists,dc=ldap,dc=mashape,dc=com",
              base_dn           = "dc=ldap,dc=mashape,dc=com",
              consumer_by       = { "username" },
              attribute         = "uid",
              hide_credentials  = true,
              cache_ttl         = 2,
            }
          }

          bp.plugins:insert {
            route = { id = routes[7].id },
            name     = "ldap-auth-advanced",
            config   = {
              ldap_host         = ldap_host_aws,
              ldap_password     = "password",
              ldap_port         = ldap_strategy.port,
              start_tls         = ldap_strategy.start_tls,
              ldaps             = ldap_strategy.ldaps,
              bind_dn           = "something=is,wrong=com",
              base_dn           = "dc=ldap,dc=mashape,dc=com",
              consumer_by       = { "username" },
              attribute         = "uid",
              hide_credentials  = true,
              cache_ttl         = 2,
            }
          }

          assert(helpers.start_kong({
            plugins = "ldap-auth-advanced",
            database   = db_strategy,
            nginx_conf = "spec/fixtures/custom_nginx.template",
          }, nil, nil, { http_mock = { ws = ws.mock_upstream() } }))
        end)

        teardown(function()
          helpers.stop_kong(nil, true)
        end)

        before_each(function()
          proxy_client = conf.proxy_client()
          admin_client = helpers.admin_client()
        end)

        after_each(function()
          if proxy_client then
            proxy_client:close()
          end

          if admin_client then
            admin_client:close()
          end
        end)

        describe("consumer mapping", function()

          it("passes auth and maps consumer with username only, consumer_by = username, custom_id", function()
            local res = assert(proxy_client:send {
              method  = "GET",
              path    = "/get",
              headers = {
                ["Host"]          = "ldap.id.custom_id.username.test",
                ["Authorization"] = "ldap " .. ngx.encode_base64("einstein:password"),
              }
            })

            assert.response(res).has.status(200)
            assert.request(res).has.no.header("x-anonymous-consumer")
            assert.are.equal('einstein',
                             assert.request(res).has.header("x-consumer-username"))
            assert.request(res).has.no.header("x-anonymous-consumer")
          end)

          it("passes auth and maps consumer with username only, consumer_by = username", function()
            local res = assert(proxy_client:send {
              method  = "GET",
              path    = "/get",
              headers = {
                ["Host"]          = routes[2].hosts[1],
                ["Authorization"] = "ldap " .. ngx.encode_base64("einstein:password"),
              }
            })

            assert.response(res).has.status(200)
            assert.request(res).has.no.header("x-anonymous-consumer")
            assert.are.equal(consumer_with_username.id,
                             assert.request(res).has.header("x-consumer-id"))
            assert.are.equal(consumer_with_username.username,
                             assert.request(res).has.header("x-consumer-username"))
          end)

          it("passes auth and maps consumer with custom_id only, consumer_by = custom_id", function()
            local res = assert(proxy_client:send {
              method  = "GET",
              path    = "/get",
              headers = {
                ["Host"]          = routes[3].hosts[1],
                ["Authorization"] = "ldap " .. ngx.encode_base64("einstein:password"),
              }
            })

            assert.response(res).has.status(200)
            assert.request(res).has.no.header("x-anonymous-consumer")
            assert.are.equal(consumer_with_custom_id.id,
                             assert.request(res).has.header("x-consumer-id"))
            assert.are.equal(consumer_with_custom_id.username,
                             assert.request(res).has.header("x-consumer-username"))
          end)

          it("fails ldap auth but maps to anonymous", function()
            local res = assert(proxy_client:send {
              method  = "GET",
              path    = "/get",
              headers = {
                ["Host"]          = routes[4].hosts[1],
                ["Authorization"] = "ldap " .. ngx.encode_base64("noway:jose"),
              }
            })

            assert.response(res).has.status(200)
            assert.are.equal(anonymous_consumer.id,
                             assert.request(res).has.header("x-consumer-id"))
            assert.are.equal(anonymous_consumer.username,
                             assert.request(res).has.header("x-consumer-username"))
            assert.are.equal("true",
                             assert.request(res).has.header("x-anonymous-consumer"))
          end)

          it("binds to anonymous with no credentials", function()
            local res = assert(proxy_client:send {
              method  = "GET",
              path    = "/get",
              headers = {
                ["Host"]          = routes[4].hosts[1]
              }
            })

            assert.response(res).has.status(200)
            assert.are.equal(anonymous_consumer.id,
                             assert.request(res).has.header("x-consumer-id"))
            assert.are.equal(anonymous_consumer.username,
                             assert.request(res).has.header("x-consumer-username"))
            assert.are.equal("true",
                             assert.request(res).has.header("x-anonymous-consumer"))
          end)

          it("caches LDAP consumer map by consumer_by and invalidates", function()
            local res = assert(proxy_client:send {
              method  = "GET",
              path    = "/get",
              headers = {
                ["Host"]          = routes[3].hosts[1],
                ["Authorization"] = "ldap " .. ngx.encode_base64("einstein:password"),
              }
            })
            assert.response(res).has.status(200)
            assert.are.equal(consumer_with_custom_id.username,
                             assert.request(res).has.header("x-consumer-username"))
            --consumers:username:einstein:consumers:::
            local key = dao.consumers:cache_key("custom_id", consumer_with_custom_id.custom_id, "consumers")

            helpers.wait_until(function()
              local res = assert(admin_client:send {
                method  = "GET",
                path    = "/cache/" .. key
              })
              res:read_body()
              return res.status == 200
            end)

            admin_client:send {
              method = "DELETE",
              path = "/consumers/" .. consumer_with_custom_id.id
            }

            -- Check that cache is invalidated
            helpers.wait_until(function()
              local res = admin_client:send {
                method  = "GET",
                path    = "/cache/" .. key
              }
              res:read_body()
              return res.status == 404
            end, plugin.config.cache_ttl + 10)
          end)

          it("bind_dn passes and authenticates user and maps consumer with " ..
             "custom_id only, consumer_by = custom_id", function()
            local res = assert(proxy_client:send {
              method  = "GET",
              path    = "/get",
              headers = {
                ["Host"]          = routes[5].hosts[1],
                ["Authorization"] = "ldap " .. ngx.encode_base64("euclid:password"),
              }
            })

            assert.response(res).has.status(200)
            assert.request(res).has.no.header("x-anonymous-consumer")
            assert.are.equal(consumer2_with_custom_id.id,
                             assert.request(res).has.header("x-consumer-id"))
            assert.are.equal(consumer2_with_custom_id.username,
                             assert.request(res).has.header("x-consumer-username"))
          end)

          it("bind_dn passes and authenticates user and maps consumer with " ..
             "username only, consumer_by = username", function()
            local res = assert(proxy_client:send {
              method  = "GET",
              path    = "/get",
              headers = {
                ["Host"]          = routes[6].hosts[1],
                ["Authorization"] = "ldap " .. ngx.encode_base64("euclid:password"),
              }
            })

            assert.response(res).has.status(200)
            assert.request(res).has.no.header("x-anonymous-consumer")
            assert.are.equal(consumer2_with_username.id,
                             assert.request(res).has.header("x-consumer-id"))
            assert.are.equal(consumer2_with_username.username,
                             assert.request(res).has.header("x-consumer-username"))
          end)

          it("returns internal server error when bind_dn is invalid", function()
            local res = assert(proxy_client:send {
              method  = "GET",
              path    = "/get",
              headers = {
                ["Host"]          = routes[7].hosts[1],
                ["Authorization"] = "ldap " .. ngx.encode_base64("einstein:password"),
              }
            })

            assert.response(res).has.status(500)
          end)
        end)
      end)
    end
  end)
end
end
