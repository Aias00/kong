-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]


local uri = require "kong.openid-connect.uri"
local cjson = require "cjson.safe"
local helpers = require "spec.helpers"
local http_mock = require "spec.helpers.http_mock"
local redis_helper = require "spec.helpers.redis_helper"
local keycloak_api = require "spec-ee.fixtures.keycloak_api".new()

local encode_base64 = ngx.encode_base64
local sub = string.sub
local find = string.find


local PLUGIN_NAME = "openid-connect"
local keycloak_config = keycloak_api.config
local KEYCLOAK_HOST = keycloak_config.host_name
local KEYCLOAK_PORT = tonumber(keycloak_config.port)
local KEYCLOAK_SSL_PORT = tonumber(keycloak_config.ssl_port)
local KEYCLOAK_HOST_HEADER = keycloak_config.host
local REALM_PATH = keycloak_config.realm_path
local DISCOVERY_PATH = "/.well-known/openid-configuration"
local ISSUER_URL = keycloak_config.issuer
local ISSUER_SSL_URL = keycloak_config.ssl_issuer

local USERNAME = "john"
local USERNAME2 = "bill"
local USERNAME2_UPPERCASE = USERNAME2:upper()
local INVALID_USERNAME = "irvine"
local PASSWORD = "doe"
local CLIENT_ID = "service"
local CLIENT_SECRET = "7adf1a21-6b9e-45f5-a033-d0e8f47b1dbc"
local INVALID_ID = "unknown"
local INVALID_SECRET = "soldier"

local INVALID_CREDENTIALS = "Basic " .. encode_base64(INVALID_ID .. ":" .. INVALID_SECRET)
local PASSWORD_CREDENTIALS = "Basic " .. encode_base64(USERNAME .. ":" .. PASSWORD)
local USERNAME2_PASSWORD_CREDENTIALS = "Basic " .. encode_base64(USERNAME2 .. ":" .. PASSWORD)
local CLIENT_CREDENTIALS = "Basic " .. encode_base64(CLIENT_ID .. ":" .. CLIENT_SECRET)

local KONG_HOST = "localhost" -- only use other names and when it's resolvable by resty.http
local KONG_CLIENT_ID = keycloak_config.client_id
local KONG_CLIENT_SECRET = keycloak_config.client_secret
local KONG_PRIVATE_KEY_JWT_CLIENT_ID = "kong-private-key-jwt"

local PUBLIC_CLIENT_ID = "kong-public"

local REDIS_HOST = helpers.redis_host
local REDIS_PORT = helpers.redis_port
local REDIS_PORT_ERR = 6480
local REDIS_USER_VALID = "openid-connect-user"
local REDIS_PASSWORD = "secret"

local NODE2PORT = helpers.get_available_port()

local HTTP_SERVER_PORT = helpers.get_available_port()
local mock = http_mock.new(HTTP_SERVER_PORT, {
  ["/"] = {
    directives = [[
      set $target "";
      proxy_pass $target;
    ]],
    access = [[
      local body = ngx.ctx.req.body
      if body then
        -- change the custom token param name back into the default name
        local modified_body = body:gsub("mytoken=", "token=")
        ngx.req.set_body_data(modified_body)
      end

      local socket = require "socket"
      local host = "]] .. KEYCLOAK_HOST .. [["
      local ip = socket.dns.toip(host)
      local ipport = ip .. ":" .. ]] .. KEYCLOAK_PORT .. [[
      ngx.ctx.ipport = ipport
      ngx.var.target = "http://" .. ipport .. ngx.var.request_uri
    ]],
  },}, {
    log_opts = {
      req = true,
      req_body = true,
      req_large_body = true,
    }
  })
local MOCK_ISSUER_URL = "http://localhost:" .. HTTP_SERVER_PORT .. REALM_PATH

local function request_uri(endpoint, opts)
  return require("resty.http").new():request_uri(endpoint, opts)
end

local function error_assert(res, code, desc)
  local header = res.headers["WWW-Authenticate"]
  assert.match(string.format('error="%s"', code), header)

  if desc then
    assert.match(string.format('error_description="%s"', desc), header)
  end
end

local function extract_cookie(cookie)
  local user_session
  local user_session_header_table = {}
  cookie = type(cookie) == "table" and cookie or {cookie}
  for i = 1, #cookie do
    local cookie_chunk = cookie[i]
    user_session = sub(cookie_chunk, 0, find(cookie_chunk, ";") -1)
    user_session_header_table[i] = user_session
  end
  return user_session_header_table
end


for _, strategy in helpers.all_strategies() do
  describe(PLUGIN_NAME .. ": (keycloak) with strategy: #" .. strategy .. " ->", function()
    local red

    setup(function()
      red = redis_helper.connect(REDIS_HOST, REDIS_PORT)
      redis_helper.add_admin_user(red, REDIS_USER_VALID, REDIS_PASSWORD)
    end)

    teardown(function()
      redis_helper.remove_user(red, REDIS_USER_VALID)
    end)

    it("can access openid connect discovery endpoint on demo realm with http", function()
      local client = helpers.http_client(KEYCLOAK_HOST, KEYCLOAK_PORT)
      local res = client:get(REALM_PATH .. DISCOVERY_PATH)
      assert.response(res).has.status(200)
      local json = assert.response(res).has.jsonbody()
      assert.equal(ISSUER_URL, json.issuer)
    end)

    it("can access openid connect discovery endpoint on demo realm with https", function()
      local client = helpers.http_client(KEYCLOAK_HOST, KEYCLOAK_SSL_PORT)
      assert(client:ssl_handshake(nil, nil, false))
      local res = client:get(REALM_PATH .. DISCOVERY_PATH)
      assert.response(res).has.status(200)
      local json = assert.response(res).has.jsonbody()
      assert.equal(ISSUER_SSL_URL, json.issuer)
    end)

    describe("authentication", function()
      local custom_redis_db = 15
      local proxy_client
      local jane
      local jack
      lazy_setup(function()
        local bp = helpers.get_db_utils(strategy, {
          "routes",
          "services",
          "plugins",
        }, {
          PLUGIN_NAME
        })

        local service = bp.services:insert {
          name = PLUGIN_NAME,
          path = "/anything"
        }

        local route = bp.routes:insert {
          service = service,
          paths   = { "/" },
        }

        bp.plugins:insert {
          route   = route,
          name    = PLUGIN_NAME,
          config  = {
            issuer    = ISSUER_URL,
            scopes = {
              -- this is the default
              "openid",
            },
            client_id = {
              KONG_CLIENT_ID,
            },
            client_secret = {
              KONG_CLIENT_SECRET,
            },
            upstream_refresh_token_header = "refresh_token",
            refresh_token_param_name      = "refresh_token",
          },
        }

        local route_custom = bp.routes:insert {
          service = service,
          paths   = { "/custom" },
        }

        bp.plugins:insert {
          route   = route_custom,
          name    = PLUGIN_NAME,
          config  = {
            issuer    = MOCK_ISSUER_URL,
            scopes = {
              -- this is the default
              "openid",
            },
            client_id = {
              KONG_CLIENT_ID,
            },
            client_secret = {
              KONG_CLIENT_SECRET,
            },
            upstream_refresh_token_header = "refresh_token",
            refresh_token_param_name      = "refresh_token",
          },
        }

        local leeway_refresh_route = bp.routes:insert {
          service = service,
          paths   = { "/leeway-refresh" },
        }

        bp.plugins:insert {
          route   = leeway_refresh_route,
          name    = PLUGIN_NAME,
          config  = {
            display_errors = true,
            issuer    = ISSUER_URL,
            scopes = {
              -- this is the default
              "openid",
            },
            -- token expiry is 600 seconds
            -- so we have 2 seconds of token validity
            leeway = 598,
            client_id = {
              KONG_CLIENT_ID,
            },
            client_secret = {
              KONG_CLIENT_SECRET,
            },
            refresh_tokens = true,
            upstream_refresh_token_header = "refresh_token",
            refresh_token_param_name      = "refresh_token",
          },
        }

        local code_flow_route = bp.routes:insert {
          service = service,
          paths   = { "/code-flow" },
        }

        local par_code_flow_route = bp.routes:insert {
          service = service,
          paths = { "/par-code-flow" },
        }

        local jar_code_flow_route = bp.routes:insert {
          service = service,
          paths   = { "/jar-code-flow" },
        }

        local jarm_code_flow_route = bp.routes:insert {
          service = service,
          paths   = { "/jarm-code-flow" },
        }

        local cookie_attrs_route = bp.routes:insert {
          service = service,
          paths   = { "/cookie-attrs" },
        }

        bp.plugins:insert {
          route   = code_flow_route,
          name    = PLUGIN_NAME,
          config  = {
            issuer    = ISSUER_URL,
            scopes = {
              -- this is the default
              "openid",
            },
            auth_methods = {
              "authorization_code",
              "session"
            },
            preserve_query_args = true,
            login_action = "redirect",
            login_tokens = {},
            client_id = {
              KONG_CLIENT_ID,
            },
            client_secret = {
              KONG_CLIENT_SECRET,
            },
            upstream_refresh_token_header = "refresh_token",
            refresh_token_param_name      = "refresh_token",
            require_proof_key_for_code_exchange = true,
          },
        }

        bp.plugins:insert {
          route   = par_code_flow_route,
          name    = PLUGIN_NAME,
          config  = {
            issuer    = ISSUER_URL,
            scopes = {
              -- this is the default
              "openid",
            },
            auth_methods = {
              "authorization_code",
              "session"
            },
            preserve_query_args = true,
            login_action = "redirect",
            login_tokens = {},
            client_id = {
              KONG_CLIENT_ID,
            },
            client_secret = {
              KONG_CLIENT_SECRET,
            },
            upstream_refresh_token_header = "refresh_token",
            refresh_token_param_name      = "refresh_token",
            require_pushed_authorization_requests = true,
          },
        }

        bp.plugins:insert {
          route   = jar_code_flow_route,
          name    = PLUGIN_NAME,
          config  = {
            issuer    = ISSUER_URL,
            scopes = {
              -- this is the default
              "openid",
            },
            auth_methods = {
              "authorization_code",
              "session"
            },
            preserve_query_args = true,
            login_action = "redirect",
            login_tokens = {},
            client_id = {
              KONG_PRIVATE_KEY_JWT_CLIENT_ID,
            },
            client_auth = {
              "private_key_jwt"
            },
            client_jwk = {
              {
                kty = "RSA",
                n = "2q4Xg7nrWYhwU3xMlIValpB_BkdWEkoOluk1e7U5elXEITkEUaXm8BzLU-PU0yHiqWe5s1wiceaEXNvpwgVDhpzisBMutmpoxEnVMNC-n6LS1IIOdup6NbhPD_zI-2wJD9YD40kmHEtpoUR1ZrRIitrkP4S-iKamVhKRxAVvZqEfftEpaDwN-V9YlXbSGFMPC_Hkjsi3WkynS9BMl0GDH7k7qFr5SDxkCZiL7MvgQrrIrB1mYhOF7HNmiWTOlbX7qbitw_H3vvnZzPz4RDloPti51c22dRTredvEdE-PYpwSrzkXESuQwxLJGT9LUENHXJUWtWp6i2uav1KIHbWzUQ",
                e = "AQAB",
                d = "ZaP3P_2hOzskYllqyrl00niU4dk0U0nioBgDCN3Bum-0unBi5oRC46Wuh-5kVEHytSSF9qzDQceQDA0XCFwj96Rh5M71rkmlKl7a3VaY01_9uFI-4Ny5MtDYxqiKzfl3-MlTg0fTk-ElVpSYMMVo1klJP5C2cpNqyqTU5ZRVJBCxrowFvpNi4YnyyPzd5PpLSr5dM_M0Ut6aE8xYbKj8HvpmMsoG_fxapZL7OBCeBUGBKb0QWJwfTEElLMQ5hTTobZyVzIIpjOoH7Pjxk8kHzjwPmS86JT4h8zor4YyH2vvwjoo9WgLsyuSc3vPVKDlLBeLBALPfgX7cgO4dhJb4MQ",
                p = "8hhUwnjY3HFqz4Bs771H_wSmNGDdHNzX8hEeOBhtRpJBuAHcqXW4EwZXRFij0MUjdm64jqJAgpKzp4hnErZroJUsmlAC2oFqqPBPicD_dTZFE9xBr3IvndgpkdockL3GyRl6ju1-b_-AT3LlTeL-jJPROh2UYKpDT85unbiz8A0",
                q = "5z152ml7gMIL4Szo0JC19aOXXCbS4mu_tzwJZ_c9pvEJCiqOECbvHJAR_9cWvR9IhSIwCd3BjMoeIUQyMuWqZuRmQxht93AScMApxF0ZkCOhhmo9fvGMEOIUXbfap6XVwOdRKRxwHX8Kf1WupPjmeX2Xa9jaKJeXqkEv5ws0O1U",
                dp = "sArRV7jYuTQgH1Ob45kYSXDwCxaEswBEZ1nbR587lx2zfEKeWvunJu5tdt2eAanY574LpmyFzG0xBppBmXHdQaA4Ft4ntQx2qvJUZC9bk7gq8w4vFY1K4tTVJaIdM4NMkd9dJ6G7V2XLv_oklEaEI2U5t7DavJAS8m2CMl6lOeE",
                dq = "P-qzOtb7R0zbwcMLG1NUqHAuj08_7UwBMyHKK82gYfuwFvpKSFaqs0dzYjdO1rnF7t7TTnbYYBUiHOnfwkfPQR-S0Kr5AnMc9cN4CAn_3eKrbB8DnoofwC7tmDYQn1RscCTAP0_YAZ8zBJ1nZ7xQ4HYBm9LWAnBcgLgCCKgFKP0",
                qi = "l5ci1Tnsh6G5lm9qmqF6lF25yjCJhM-Qh6hTa9M2MxtQIEgtRWv9lhUzahepUswgCMg2dq_Azqih46ITmI6zLZhURdGPPmBRYeNFSsAy0ZsCyWJhGp2fa-a1apno5yJi9gWE0J7c8W1rNO-cM6I1rn9yhtpdkz6NO-nH668e9LU",
              },
            },
            upstream_refresh_token_header = "refresh_token",
            refresh_token_param_name      = "refresh_token",
            require_signed_request_object = true,
          },
        }

        bp.plugins:insert {
          route   = jarm_code_flow_route,
          name    = PLUGIN_NAME,
          config  = {
            issuer    = ISSUER_URL,
            scopes = {
              -- this is the default
              "openid",
            },
            auth_methods = {
              "authorization_code",
              "session"
            },
            preserve_query_args = true,
            login_action = "upstream",
            login_tokens = {},
            client_id = {
              KONG_CLIENT_ID,
            },
            client_secret = {
              KONG_CLIENT_SECRET,
            },
            upstream_refresh_token_header = "refresh_token",
            refresh_token_param_name      = "refresh_token",
            require_proof_key_for_code_exchange = true,
            response_mode = "jwt",
          },
        }

        bp.plugins:insert {
          route   = cookie_attrs_route,
          name    = PLUGIN_NAME,
          config  = {
            issuer    = ISSUER_URL,
            scopes = {
              -- this is the default
              "openid",
            },
            auth_methods = {
              "authorization_code",
              "session"
            },
            preserve_query_args = true,
            login_action = "redirect",
            client_id = {
              KONG_CLIENT_ID,
            },
            client_secret = {
              KONG_CLIENT_SECRET,
            },
            upstream_refresh_token_header  = "refresh_token",
            refresh_token_param_name       = "refresh_token",
            session_cookie_http_only       = false,
            session_cookie_domain          = "example.org",
            session_cookie_path            = "/test",
            session_cookie_same_site       = "Default",
            authorization_cookie_http_only = false,
            authorization_cookie_domain    = "example.org",
            authorization_cookie_path      = "/test",
            authorization_cookie_same_site = "Default",
          },
        }

        local route_compressed = bp.routes:insert {
          service = service,
          paths   = { "/compressed-session" },
        }

        bp.plugins:insert {
          route   = route_compressed,
          name    = PLUGIN_NAME,
          config  = {
            issuer    = ISSUER_URL,
            scopes = {
              -- this is the default
              "openid",
            },
            client_id = {
              KONG_CLIENT_ID,
            },
            client_secret = {
              KONG_CLIENT_SECRET,
            },
            upstream_refresh_token_header = "refresh_token",
            refresh_token_param_name      = "refresh_token",
            session_compressor = "zlib"
          },
        }

        local introspection = bp.routes:insert {
          service = service,
          paths   = { "/introspection" },
        }

        local introspection_custom = bp.routes:insert {
          service = service,
          paths   = { "/introspection_custom" },
        }

        bp.plugins:insert {
          route   = introspection,
          name    = PLUGIN_NAME,
          config  = {
            issuer    = ISSUER_URL,
            client_id = {
              KONG_CLIENT_ID,
            },
            client_secret = {
              KONG_CLIENT_SECRET,
            },
            -- Types of credentials/grants to enable. Limit to introspection for this case
            auth_methods = {
              "introspection",
            },
          },
        }

        bp.plugins:insert {
          route   = introspection_custom,
          name    = PLUGIN_NAME,
          config  = {
            issuer    = MOCK_ISSUER_URL,
            client_id = {
              KONG_CLIENT_ID,
            },
            client_secret = {
              KONG_CLIENT_SECRET,
            },
            -- Types of credentials/grants to enable. Limit to introspection for this case
            auth_methods = {
              "introspection",
            },
	          introspection_endpoint = MOCK_ISSUER_URL .. "/protocol/openid-connect/token/introspect",
            introspection_token_param_name = "mytoken",
          },
        }

        local route_redis_session = bp.routes:insert {
          service = service,
          paths   = { "/redis-session" },
        }

        bp.plugins:insert {
          route   = route_redis_session,
          name    = PLUGIN_NAME,
          config  = {
            issuer    = ISSUER_URL,
            scopes = {
              -- this is the default
              "openid",
            },
            client_id = {
              KONG_CLIENT_ID,
            },
            client_secret = {
              KONG_CLIENT_SECRET,
            },
            upstream_refresh_token_header = "refresh_token",
            refresh_token_param_name      = "refresh_token",
            session_storage = "redis",
            session_redis_host = REDIS_HOST,
            session_redis_port = REDIS_PORT,
            -- This will allow for testing with a secured redis instance
            session_redis_password = os.getenv("REDIS_PASSWORD") or nil,
          },
        }

        local route_redis_session_db = bp.routes:insert {
          service = service,
          paths   = { "/redis-session-db" },
        }

        bp.plugins:insert {
          route   = route_redis_session_db,
          name    = PLUGIN_NAME,
          config  = {
            issuer    = ISSUER_URL,
            scopes = {
              -- this is the default
              "openid",
            },
            auth_methods = {
              "client_credentials",
              "session",
            },
            client_id = {
              KONG_CLIENT_ID,
            },
            client_secret = {
              KONG_CLIENT_SECRET,
            },
            upstream_refresh_token_header = "refresh_token",
            refresh_token_param_name      = "refresh_token",
            session_storage = "redis",
            redis = {
              host = REDIS_HOST,
              port = REDIS_PORT,
              database = custom_redis_db,
            },
          },
        }

        local route_redis_session_acl = bp.routes:insert {
          service = service,
          paths   = { "/redis-session-acl" },
        }

        bp.plugins:insert {
          route   = route_redis_session_acl,
          name    = PLUGIN_NAME,
          config  = {
            issuer    = ISSUER_URL,
            scopes = {
              -- this is the default
              "openid",
            },
            client_id = {
              KONG_CLIENT_ID,
            },
            client_secret = {
              KONG_CLIENT_SECRET,
            },
            upstream_refresh_token_header = "refresh_token",
            refresh_token_param_name      = "refresh_token",
            session_storage = "redis",
            session_redis_host = REDIS_HOST,
            session_redis_port = REDIS_PORT,
            session_redis_username = REDIS_USER_VALID,
            session_redis_password = REDIS_PASSWORD,
          },
        }

        local userinfo = bp.routes:insert {
          service = service,
          paths   = { "/userinfo" },
        }

        bp.plugins:insert {
          route   = userinfo,
          name    = PLUGIN_NAME,
          config  = {
            issuer    = ISSUER_URL,
            client_id = {
              KONG_CLIENT_ID,
            },
            client_secret = {
              KONG_CLIENT_SECRET,
            },
            auth_methods = {
              "userinfo",
            },
          },
        }

        local kong_oauth2 = bp.routes:insert {
          service = service,
          paths   = { "/kong-oauth2" },
        }

        bp.plugins:insert {
          route   = kong_oauth2,
          name    = PLUGIN_NAME,
          config  = {
            issuer    = ISSUER_URL,
            client_id = {
              KONG_CLIENT_ID,
            },
            client_secret = {
              KONG_CLIENT_SECRET,
            },
            auth_methods = {
              "kong_oauth2",
            },
          },
        }

        local session = bp.routes:insert {
          service = service,
          paths   = { "/session" },
        }

        bp.plugins:insert {
          route   = session,
          name    = PLUGIN_NAME,
          config  = {
            issuer    = ISSUER_URL,
            client_id = {
              KONG_CLIENT_ID,
            },
            client_secret = {
              KONG_CLIENT_SECRET,
            },
            auth_methods = {
              "session",
            },
          },
        }

        local session_scopes = bp.routes:insert {
          service = service,
          paths   = { "/session_scopes" },
        }

        bp.plugins:insert {
          route   = session_scopes,
          name    = PLUGIN_NAME,
          config  = {
            issuer    = ISSUER_URL,
            client_id = {
              KONG_CLIENT_ID,
            },
            client_secret = {
              KONG_CLIENT_SECRET,
            },
            auth_methods = {
              "session",
            },
            scopes = {
              "openid",
            },
            scopes_required = {
              "openid",
            },
          },
        }

        local session_invalid_scopes = bp.routes:insert {
          service = service,
          paths   = { "/session_invalid_scopes" },
        }

        bp.plugins:insert {
          route   = session_invalid_scopes,
          name    = PLUGIN_NAME,
          config  = {
            issuer    = ISSUER_URL,
            client_id = {
              KONG_CLIENT_ID,
            },
            client_secret = {
              KONG_CLIENT_SECRET,
            },
            auth_methods = {
              "session",
            },
            scopes = {
              "openid",
            },
            scopes_required = {
              "nonexistentscope",
            },
          },
        }

        local session_compressor = bp.routes:insert {
          service = service,
          paths   = { "/session_compressed" },
        }

        bp.plugins:insert {
          route   = session_compressor,
          name    = PLUGIN_NAME,
          config  = {
            issuer    = ISSUER_URL,
            client_id = {
              KONG_CLIENT_ID,
            },
            client_secret = {
              KONG_CLIENT_SECRET,
            },
            auth_methods = {
              "session",
            },
            session_compressor = 'zlib'
          },
        }

        jane = bp.consumers:insert {
          username = "jane",
        }

        bp.oauth2_credentials:insert {
          name          = "demo",
          client_id     = "client",
          client_secret = "secret",
          hash_secret   = not helpers.is_fips_build(), -- disable hash_secret in FIPS mode
          consumer      = jane
        }

        jack = bp.consumers:insert {
          username = "jack",
        }

        bp.oauth2_credentials:insert {
          name          = "demo-2",
          client_id     = "client-2",
          client_secret = "secret-2",
          hash_secret   = not helpers.is_fips_build(), -- disable hash_secret in FIPS mode,
          consumer      = jack
        }

        local auth = bp.routes:insert {
          service = ngx.null,
          paths   = { "/auth" },
        }

        bp.plugins:insert {
          route   = auth,
          name    = "oauth2",
          config  = {
            global_credentials        = true,
            enable_client_credentials = true,
          },
        }

	      assert(mock:start())
        assert(helpers.start_kong({
          database   = strategy,
          nginx_conf = "spec/fixtures/custom_nginx.template",
          plugins    = "bundled," .. PLUGIN_NAME,
        }))
      end)

      lazy_teardown(function()
        helpers.stop_kong()
	      mock:stop()
      end)

      before_each(function()
        proxy_client = helpers.proxy_client()
      end)

      after_each(function()
        if proxy_client then
          proxy_client:close()
        end
      end)

      local function auth_code_flow(path, kong_redirect_assert_cb, idp_redirect_assert_cb, upstream_request_assert_cb)
        local res = proxy_client:get(path, {
          headers = {
            ["Host"] = "kong"
          }
        })
        assert.response(res).has.status(302)
        local redirect = res.headers["Location"]
        local url = assert(uri.parse(redirect))
        kong_redirect_assert_cb(url)

        -- get authorization=...; cookie
        local auth_cookie = res.headers["Set-Cookie"]
        local auth_cookie_cleaned = sub(auth_cookie, 0, find(auth_cookie, ";") -1)
        local rres, err = request_uri(redirect, {
          headers = {
            -- impersonate as browser
            ["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/93.0.4577.63 Safari/537.36", -- luacheck: ignore
            ["Host"] = KEYCLOAK_HOST_HEADER,
          }
        })
        assert.is_nil(err)
        assert.equal(200, rres.status)

        local cookies = rres.headers["Set-Cookie"]
        local user_session
        local user_session_header_table = {}
        for _, cookie in ipairs(cookies) do
          user_session = sub(cookie, 0, find(cookie, ";") -1)
          if find(user_session, 'AUTH_SESSION_ID=', 1, true) ~= 1 then
            -- auth_session_id is dropped by the browser for non-https connections
            table.insert(user_session_header_table, user_session)
          end
        end
        -- get the action_url from submit button and post username:password
        local action_start = find(rres.body, 'action="', 0, true)
        local action_end = find(rres.body, '"', action_start+8, true)
        local login_button_url = string.sub(rres.body, action_start+8, action_end-1)
        -- the login_button_url is endcoded. decode it
        login_button_url = string.gsub(login_button_url,"&amp;", "&")
        -- build form_data
        local form_data = "username="..USERNAME.."&password="..PASSWORD.."&credentialId="
        local opts = { method = "POST",
          body = form_data,
          headers = {
            -- impersonate as browser
            ["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/93.0.4577.63 Safari/537.36", --luacheck: ignore
            ["Host"] = KEYCLOAK_HOST_HEADER,
            -- due to form_data
            ["Content-Type"] = "application/x-www-form-urlencoded",
            Cookie = user_session_header_table,
        }}
        local loginres
        loginres, err = request_uri(login_button_url, opts)
        assert.is_nil(err)
        idp_redirect_assert_cb(loginres)

        -- after sending login data to the login action page, expect a redirect
        local upstream_url = loginres.headers["Location"]
        local ures
        ures, err = request_uri(upstream_url, {
          headers = {
            -- authenticate using the cookie from the initial request
            Cookie = auth_cookie_cleaned
          }
        })
        assert.is_nil(err)
        local continue = upstream_request_assert_cb(ures)
        if not continue then
          return
        end

        local client_session
        local client_session_header_table = {}
        -- extract session cookies
        local ucookies = ures.headers["Set-Cookie"]
        -- extract final redirect
        local final_url = ures.headers["Location"]
        for i, cookie in ipairs(ucookies) do
          client_session = sub(cookie, 0, find(cookie, ";") -1)
          client_session_header_table[i] = client_session
        end
        local ures_final
        ures_final, err = request_uri(final_url, {
          headers = {
            -- send session cookie
            Cookie = client_session_header_table
          }
        })
        assert.is_nil(err)
        assert.equal(200, ures_final.status)

        local json = assert(cjson.decode(ures_final.body))
        assert.is_not_nil(json.headers.authorization)
        assert.equal("Bearer", sub(json.headers.authorization, 1, 6))
      end

      describe("authorization code flow", function()
        it("initial request, expect redirect to login page", function()
          local function kong_redirect_assert_cb(url)
            assert.equal("http", url.scheme)
            assert.equal(KEYCLOAK_HOST, url.host)
            assert.equal(KEYCLOAK_PORT, url.port)
            assert.equal(KONG_CLIENT_ID, url.args.client_id)
            assert.is_nil(url.args.request_uri)
            assert.is_string(url.args.redirect_uri)
            assert.not_equal("", url.args.redirect_uri)
            assert.is_string(url.args.code_challenge)
            assert.not_equal("", url.args.code_challenge)
            assert.is_string(url.args.code_challenge_method)
            assert.not_equal("", url.args.code_challenge_method)
          end

          local function idp_redirect_assert_cb(res)
            assert.equal(302, res.status)
          end

          local function upstream_request_assert_cb(res)
            assert.equal(302, res.status)
            return true
          end

          auth_code_flow("/code-flow", kong_redirect_assert_cb, idp_redirect_assert_cb, upstream_request_assert_cb)
        end)

        it("initial request, expect redirect to login page using PAR", function()
          local function kong_redirect_assert_cb(url)
            assert.equal("http", url.scheme)
            assert.equal(KEYCLOAK_HOST, url.host)
            assert.equal(KEYCLOAK_PORT, url.port)
            assert.equal(KONG_CLIENT_ID, url.args.client_id)
            assert.is_string(url.args.request_uri)
            assert.not_equal("", url.args.request_uri)
            assert.is_nil(url.args.redirect_uri)
            local rurl = assert(uri.parse(url.args.request_uri))
            assert.is_string(rurl.scheme)
            assert.not_equal("", rurl.scheme)
          end

          local function idp_redirect_assert_cb(res)
            assert.equal(302, res.status)
          end

          local function upstream_request_assert_cb(res)
            assert.equal(302, res.status)
            return true
          end

          auth_code_flow("/par-code-flow", kong_redirect_assert_cb, idp_redirect_assert_cb, upstream_request_assert_cb)
        end)

        it("initial request, expect redirect to login page using JAR", function()
          local function kong_redirect_assert_cb(url)
            assert.equal("http", url.scheme)
            assert.equal(KEYCLOAK_HOST, url.host)
            assert.equal(KEYCLOAK_PORT, url.port)
            assert.equal(KONG_PRIVATE_KEY_JWT_CLIENT_ID, url.args.client_id)
            assert.is_string(url.args.request)
            assert.not_equal("", url.args.request)
            assert.is_nil(url.args.redirect_uri)
          end

          local function idp_redirect_assert_cb(res)
            assert.equal(302, res.status)
          end

          local function upstream_request_assert_cb(res)
            assert.equal(302, res.status)
            return true
          end

          auth_code_flow("/jar-code-flow", kong_redirect_assert_cb, idp_redirect_assert_cb, upstream_request_assert_cb)
        end)

        it("initial request, expect redirect to login page using JARM", function()
          local function kong_redirect_assert_cb(url)
            assert.equal("http", url.scheme)
            assert.equal(KEYCLOAK_HOST, url.host)
            assert.equal(KEYCLOAK_PORT, url.port)
            assert.equal(KONG_CLIENT_ID, url.args.client_id)
            assert.is_nil(url.args.request_uri)
            assert.is_string(url.args.redirect_uri)
            assert.not_equal("", url.args.redirect_uri)
            assert.is_string(url.args.code_challenge)
            assert.not_equal("", url.args.code_challenge)
            assert.is_string(url.args.code_challenge_method)
            assert.not_equal("", url.args.code_challenge_method)
          end

          local function idp_redirect_assert_cb(res)
            assert.equal(302, res.status)
            local upstream_url = res.headers["Location"]
            local parsed = assert(uri.parse(upstream_url))
            -- expected jarm arg is in the query params
            assert.matches("response=", parsed.query)
          end

          local function upstream_request_assert_cb(res)
            assert.equal(200, res.status)
            local json = assert(cjson.decode(res.body))
            assert.is_nil(json.uri_args.response)
            return false
          end

          auth_code_flow("/jarm-code-flow", kong_redirect_assert_cb, idp_redirect_assert_cb, upstream_request_assert_cb)
        end)

        it("post wrong login credentials", function()
          local res = proxy_client:get("/code-flow", {
            headers = {
              ["Host"] = "localhost"
            }
          })
          assert.response(res).has.status(302)

          local redirect = res.headers["Location"]
          -- get authorization=...; cookie
          local auth_cookie = res.headers["Set-Cookie"]
          local auth_cookie_cleaned = sub(auth_cookie, 0, find(auth_cookie, ";") -1)
          local rres, err = request_uri(redirect, {
            headers = {
              -- impersonate as browser
              ["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/93.0.4577.63 Safari/537.36", --luacheck: ignore
              ["Host"] = KEYCLOAK_HOST_HEADER,
            }
          })
          assert.is_nil(err)
          assert.equal(200, rres.status)

          local cookies = rres.headers["Set-Cookie"]
          local user_session
          local user_session_header_table = {}
          for _, cookie in ipairs(cookies) do
            user_session = sub(cookie, 0, find(cookie, ";") -1)
            if find(user_session, 'AUTH_SESSION_ID=', 1, true) ~= 1 then
              -- auth_session_id is dropped by the browser for non-https connections
              table.insert(user_session_header_table, user_session)
            end
          end
          -- get the action_url from submit button and post username:password
          local action_start = find(rres.body, 'action="', 0, true)
          local action_end = find(rres.body, '"', action_start+8, true)
          local login_button_url = string.sub(rres.body, action_start+8, action_end-1)
          -- the login_button_url is endcoded. decode it
          login_button_url = string.gsub(login_button_url,"&amp;", "&")
          -- build form_data
          local form_data = "username="..INVALID_USERNAME.."&password="..PASSWORD.."&credentialId="
          local opts = { method = "POST",
            body = form_data,
            headers = {
              -- impersonate as browser
              ["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/93.0.4577.63 Safari/537.36", --luacheck: ignore
              ["Host"] = KEYCLOAK_HOST_HEADER,
              -- due to form_data
              ["Content-Type"] = "application/x-www-form-urlencoded",
              Cookie = user_session_header_table,
          }}
          local loginres
          loginres, err = request_uri(login_button_url, opts)
          local idx = find(loginres.body, "Invalid username or password", 0, true)
          assert.is_number(idx)
          assert.is_nil(err)
          assert.equal(200, loginres.status)

          -- verify that access isn't granted
          local final_res = proxy_client:get("/code-flow", {
            headers = {
              Cookie = auth_cookie_cleaned
            }
          })
          assert.response(final_res).has.status(302)
        end)

        it("is not allowed with invalid session-cookie", function()
          local res = proxy_client:get("/code-flow", {
            headers = {
              ["Host"] = KONG_HOST,
            }
          })
          assert.response(res).has.status(302)
          local redirect = res.headers["Location"]
          -- get authorization=...; cookie
          local auth_cookie = res.headers["Set-Cookie"]
          local auth_cookie_cleaned = sub(auth_cookie, 0, find(auth_cookie, ";") -1)
          local rres, err = request_uri(redirect, {
            headers = {
              -- impersonate as browser
              ["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/93.0.4577.63 Safari/537.36", -- luacheck: ignore
              ["Host"] = KEYCLOAK_HOST_HEADER,
            }
          })
          assert.is_nil(err)
          assert.equal(200, rres.status)

          local cookies = rres.headers["Set-Cookie"]
          local user_session
          local user_session_header_table = {}
          for _, cookie in ipairs(cookies) do
            user_session = sub(cookie, 0, find(cookie, ";") -1)
            if find(user_session, 'AUTH_SESSION_ID=', 1, true) ~= 1 then
              -- auth_session_id is dropped by the browser for non-https connections
              table.insert(user_session_header_table, user_session)
            end
          end
          -- get the action_url from submit button and post username:password
          local action_start = find(rres.body, 'action="', 0, true)
          local action_end = find(rres.body, '"', action_start+8, true)
          local login_button_url = string.sub(rres.body, action_start+8, action_end-1)
          -- the login_button_url is endcoded. decode it
          login_button_url = string.gsub(login_button_url,"&amp;", "&")
          -- build form_data
          local form_data = "username="..USERNAME.."&password="..PASSWORD.."&credentialId="
          local opts = { method = "POST",
            body = form_data,
            headers = {
              -- impersonate as browser
              ["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/93.0.4577.63 Safari/537.36", -- luacheck: ignore
              ["Host"] = KEYCLOAK_HOST_HEADER,
              -- due to form_data
              ["Content-Type"] = "application/x-www-form-urlencoded",
              Cookie = user_session_header_table,
          }}
          local loginres
          loginres, err = request_uri(login_button_url, opts)
          assert.is_nil(err)
          assert.equal(302, loginres.status)

          -- after sending login data to the login action page, expect a redirect
          local upstream_url = loginres.headers["Location"]
          local ures
          ures, err = request_uri(upstream_url, {
            headers = {
              -- authenticate using the cookie from the initial request
              Cookie = auth_cookie_cleaned
            }
          })
          assert.is_nil(err)
          assert.equal(302, ures.status)

          local client_session
          local client_session_header_table = {}
          -- extract session cookies
          local ucookies = ures.headers["Set-Cookie"]
          -- extract final redirect
          local final_url = ures.headers["Location"]
          for i, cookie in ipairs(ucookies) do
            client_session = sub(cookie, 0, find(cookie, ";") -1)
            -- making session cookie invalid
            client_session = client_session .. "invalid"
            client_session_header_table[i] = client_session
          end
          local ures_final
          ures_final, err = request_uri(final_url, {
            headers = {
              -- send session cookie
              Cookie = client_session_header_table
            }
          })

          assert.is_nil(err)
          assert.equal(302, ures_final.status)
        end)

        it("configures cookie attributes correctly", function()
          local res = proxy_client:get("/cookie-attrs", {
            headers = {
              ["Host"] = "kong"
            }
          })
          assert.response(res).has.status(302)
          local cookie = res.headers["Set-Cookie"]
          assert.does_not.match("HttpOnly", cookie)
          assert.matches("Domain=example.org", cookie)
          assert.matches("Path=/test", cookie)
          assert.matches("SameSite=Default", cookie)
        end)
      end)

      describe("password grant", function()
        it("is not allowed with invalid credentials", function()
          local res = proxy_client:get("/", {
            headers = {
              Authorization = INVALID_CREDENTIALS,
            },
          })

          assert.response(res).has.status(401)
          local json = assert.response(res).has.jsonbody()
          assert.same("Unauthorized", json.message)
        end)

        it("is not allowed with valid client credentials when grant type is given", function()
          local res = proxy_client:get("/", {
            headers = {
              Authorization = CLIENT_CREDENTIALS,
              ["Grant-Type"] = "password",
            },
          })

          assert.response(res).has.status(401)
          local json = assert.response(res).has.jsonbody()
          assert.same("Unauthorized", json.message)
          error_assert(res, "invalid_token")
        end)

        it("is allowed with valid credentials", function()
          local res = proxy_client:get("/", {
            headers = {
              Authorization = PASSWORD_CREDENTIALS,
            },
          })

          assert.response(res).has.status(200)
          local json = assert.response(res).has.jsonbody()
          assert.is_not_nil(json.headers.authorization)
          assert.equal("Bearer", sub(json.headers.authorization, 1, 6))
        end)
      end)

      describe("client credentials grant", function()
        it("is not allowed with invalid credentials", function()
          local res = proxy_client:get("/", {
            headers = {
              Authorization = INVALID_CREDENTIALS,
            },
          })

          assert.response(res).has.status(401)
          local json = assert.response(res).has.jsonbody()
          assert.same("Unauthorized", json.message)
          error_assert(res, "invalid_token")
        end)

        it("is not allowed with valid password credentials when grant type is given", function()
          local res = proxy_client:get("/", {
            headers = {
              Authorization = PASSWORD_CREDENTIALS,
              ["Grant-Type"] = "client_credentials",
            },
          })

          assert.response(res).has.status(401)
          local json = assert.response(res).has.jsonbody()
          assert.same("Unauthorized", json.message)
          error_assert(res, "invalid_token")
        end)

        it("is allowed with valid credentials", function()
          local res = proxy_client:get("/", {
            headers = {
              Authorization = CLIENT_CREDENTIALS,
            },
          })

          assert.response(res).has.status(200)
          local json = assert.response(res).has.jsonbody()
          assert.is_not_nil(json.headers.authorization)
          assert.equal("Bearer", sub(json.headers.authorization, 1, 6))
        end)
      end)

      describe("jwt access token", function()
        local user_token
        local client_token
        local invalid_token

        lazy_setup(function()
          local client = helpers.proxy_client()
          local res = client:get("/", {
            headers = {
              Authorization = PASSWORD_CREDENTIALS,
            },
          })
          assert.response(res).has.status(200)
          local json = assert.response(res).has.jsonbody()
          assert.equal("Bearer", sub(json.headers.authorization, 1, 6))

          user_token = sub(json.headers.authorization, 8)

          if sub(user_token, -4) == "7oig" then
            invalid_token = sub(user_token, 1, -5) .. "cYe8"
          else
            invalid_token = sub(user_token, 1, -5) .. "7oig"
          end

          res = client:get("/", {
            headers = {
              Authorization = CLIENT_CREDENTIALS,
            },
          })
          assert.response(res).has.status(200)
          json = assert.response(res).has.jsonbody()
          assert.equal("Bearer", sub(json.headers.authorization, 1, 6))

          client_token = sub(json.headers.authorization, 8)

          client:close()
        end)

        it("is not allowed with invalid token", function()
          local res = proxy_client:get("/", {
            headers = {
              Authorization = "Bearer " .. invalid_token,
            },
          })

          assert.response(res).has.status(401)
          local json = assert.response(res).has.jsonbody()
          assert.same("Unauthorized", json.message)
          error_assert(res, "invalid_token")
        end)

        it("is allowed with valid user token", function()
          local res = proxy_client:get("/", {
            headers = {
              Authorization = "Bearer " .. user_token,
            },
          })

          assert.response(res).has.status(200)
          local json = assert.response(res).has.jsonbody()
          assert.is_not_nil(json.headers.authorization)
          assert.equal(user_token, sub(json.headers.authorization, 8))
        end)

        it("is allowed with valid client token", function()
          local res = proxy_client:get("/", {
            headers = {
              Authorization = "Bearer " .. client_token,
            },
          })

          assert.response(res).has.status(200)
          local json = assert.response(res).has.jsonbody()
          assert.is_not_nil(json.headers.authorization)
          assert.equal(client_token, sub(json.headers.authorization, 8))
        end)
      end)

      describe("refresh token", function()
        local user_token
        local invalid_token

        lazy_setup(function()
          local client = helpers.proxy_client()
          local res = client:get("/", {
            headers = {
              Authorization = PASSWORD_CREDENTIALS,
            },
          })
          assert.response(res).has.status(200)
          local json = assert.response(res).has.jsonbody()
          assert.is_not_nil(json.headers.refresh_token)

          user_token = json.headers.refresh_token

          if sub(user_token, -4) == "7oig" then
            invalid_token = sub(user_token, 1, -5) .. "cYe8"
          else
            invalid_token = sub(user_token, 1, -5) .. "7oig"
          end
          client:close()
        end)

        it("is not allowed with invalid token", function()
          local res = proxy_client:get("/", {
            headers = {
              ["Refresh-Token"] = invalid_token,
            },
          })

          assert.response(res).has.status(401)
          local json = assert.response(res).has.jsonbody()
          assert.same("Unauthorized", json.message)
          error_assert(res, "invalid_token")
        end)

        it("is allowed with valid user token", function()
          local res = proxy_client:get("/", {
            headers = {
              ["Refresh-Token"] = user_token,
            },
          })

          assert.response(res).has.status(200)
          local json = assert.response(res).has.jsonbody()
          assert.is_not_nil(json.headers.authorization)
          assert.equal("Bearer", sub(json.headers.authorization, 1, 6))
          assert.is_not_nil(json.headers.refresh_token)
          assert.not_equal(user_token, json.headers.refresh_token)
        end)
      end)

      describe("introspection", function()
        local user_token
        local client_token
        local invalid_token

        lazy_setup(function()
          local client = helpers.proxy_client()
          local res = client:get("/", {
            headers = {
              Authorization = PASSWORD_CREDENTIALS,
            },
          })
          assert.response(res).has.status(200)
          local json = assert.response(res).has.jsonbody()
          assert.equal("Bearer", sub(json.headers.authorization, 1, 6))

          user_token = sub(json.headers.authorization, 8)

          if sub(user_token, -4) == "7oig" then
            invalid_token = sub(user_token, 1, -5) .. "cYe8"
          else
            invalid_token = sub(user_token, 1, -5) .. "7oig"
          end

          res = client:get("/", {
            headers = {
              Authorization = CLIENT_CREDENTIALS,
            },
          })
          assert.response(res).has.status(200)
          json = assert.response(res).has.jsonbody()
          assert.equal("Bearer", sub(json.headers.authorization, 1, 6))

          client_token = sub(json.headers.authorization, 8)

          client:close()
        end)

        it("is not allowed with invalid token", function()
          local res = proxy_client:get("/introspection", {
            headers = {
              Authorization = "Bearer " .. invalid_token,
            },
          })

          assert.response(res).has.status(401)
          local json = assert.response(res).has.jsonbody()
          assert.same("Unauthorized", json.message)
          error_assert(res, "invalid_token")
        end)

        it("is allowed with valid user token", function()
          local res = proxy_client:get("/introspection", {
            headers = {
              Authorization = "Bearer " .. user_token,
            },
          })

          assert.response(res).has.status(200)
          local json = assert.response(res).has.jsonbody()
          assert.is_not_nil(json.headers.authorization)
          assert.equal(user_token, sub(json.headers.authorization, 8))
        end)

        it("is allowed with valid client token", function()
          local res = proxy_client:get("/introspection", {
            headers = {
              Authorization = "Bearer " .. client_token,
            },
          })

          assert.response(res).has.status(200)
          local json = assert.response(res).has.jsonbody()
          assert.is_not_nil(json.headers.authorization)
          assert.equal(client_token, sub(json.headers.authorization, 8))
        end)
      end)

      describe("introspection (specify custom token param name)", function()
        local user_token
        local client_token
        local invalid_token

        lazy_setup(function()
          local client = helpers.proxy_client()
          local res = client:get("/custom", {
            headers = {
              Authorization = PASSWORD_CREDENTIALS,
            },
          })
          assert.response(res).has.status(200)
          local json = assert.response(res).has.jsonbody()
          assert.equal("Bearer", sub(json.headers.authorization, 1, 6))

          user_token = sub(json.headers.authorization, 8)

          if sub(user_token, -4) == "7oig" then
            invalid_token = sub(user_token, 1, -5) .. "cYe8"
          else
            invalid_token = sub(user_token, 1, -5) .. "7oig"
          end

          res = client:get("/custom", {
            headers = {
              Authorization = CLIENT_CREDENTIALS,
            },
          })
          assert.response(res).has.status(200)
          json = assert.response(res).has.jsonbody()
          assert.equal("Bearer", sub(json.headers.authorization, 1, 6))

          client_token = sub(json.headers.authorization, 8)

          client:close()
        end)

        it("is not allowed with invalid token", function()
          local res = proxy_client:get("/introspection_custom", {
            headers = {
              Authorization = "Bearer " .. invalid_token,
            },
          })

          assert.response(res).has.status(401)
          local json = assert.response(res).has.jsonbody()
          assert.same("Unauthorized", json.message)
          error_assert(res, "invalid_token")
        end)

        it("is allowed with valid user token", function()
          local res = proxy_client:get("/introspection_custom", {
            headers = {
              Authorization = "Bearer " .. user_token,
            },
          })

          assert.response(res).has.status(200)
          local json = assert.response(res).has.jsonbody()
          assert.is_not_nil(json.headers.authorization)
          assert.equal(user_token, sub(json.headers.authorization, 8))
        end)

        it("is allowed with valid client token", function()
          local res = proxy_client:get("/introspection_custom", {
            headers = {
              Authorization = "Bearer " .. client_token,
            },
          })

          assert.response(res).has.status(200)
          local json = assert.response(res).has.jsonbody()
          assert.is_not_nil(json.headers.authorization)
          assert.equal(client_token, sub(json.headers.authorization, 8))
        end)
      end)

      describe("userinfo", function()
        local user_token
        local client_token
        local invalid_token

        lazy_setup(function()
          local client = helpers.proxy_client()
          local res = client:get("/", {
            headers = {
              Authorization = PASSWORD_CREDENTIALS,
            },
          })
          assert.response(res).has.status(200)
          local json = assert.response(res).has.jsonbody()
          assert.equal("Bearer", sub(json.headers.authorization, 1, 6))

          user_token = sub(json.headers.authorization, 8)

          if sub(user_token, -4) == "7oig" then
            invalid_token = sub(user_token, 1, -5) .. "cYe8"
          else
            invalid_token = sub(user_token, 1, -5) .. "7oig"
          end

          res = client:get("/", {
            headers = {
              Authorization = CLIENT_CREDENTIALS,
            },
          })
          assert.response(res).has.status(200)
          json = assert.response(res).has.jsonbody()
          assert.equal("Bearer", sub(json.headers.authorization, 1, 6))

          client_token = sub(json.headers.authorization, 8)

          client:close()
        end)

        it("is not allowed with invalid token", function()
          local res = proxy_client:get("/userinfo", {
            headers = {
              Authorization = "Bearer " .. invalid_token,
            },
          })

          assert.response(res).has.status(401)
          local json = assert.response(res).has.jsonbody()
          assert.same("Unauthorized", json.message)
          error_assert(res, "invalid_token")
        end)

        it("is allowed with valid user token", function()
          local res = proxy_client:get("/userinfo", {
            headers = {
              Authorization = "Bearer " .. user_token,
            },
          })

          assert.response(res).has.status(200)
          local json = assert.response(res).has.jsonbody()
          assert.is_not_nil(json.headers.authorization)
          assert.equal(user_token, sub(json.headers.authorization, 8))
        end)

        it("is allowed with valid client token", function()
          local res = proxy_client:get("/userinfo", {
            headers = {
              Authorization = "Bearer " .. client_token,
            },
          })

          assert.response(res).has.status(200)
          local json = assert.response(res).has.jsonbody()
          assert.is_not_nil(json.headers.authorization)
          assert.equal(client_token, sub(json.headers.authorization, 8))
        end)
      end)

      if strategy ~= "off" then
        -- disable off strategy for oauth2 tokens, they do not support db-less mode
        describe("kong oauth2", function()
          local token
          local token2
          local invalid_token


          lazy_setup(function()
            local client = helpers.proxy_ssl_client()
            local res = client:post("/auth/oauth2/token", {
              headers = {
                ["Content-Type"] = "application/x-www-form-urlencoded",
              },
              body = {
                client_id     = "client",
                client_secret = "secret",
                grant_type    = "client_credentials",
              },
            })
            assert.response(res).has.status(200)
            local json = assert.response(res).has.jsonbody()

            token = json.access_token

            if sub(token, -4) == "7oig" then
              invalid_token = sub(token, 1, -5) .. "cYe8"
            else
              invalid_token = sub(token, 1, -5) .. "7oig"
            end

            client:close()

            client = helpers.proxy_ssl_client()
            res = client:post("/auth/oauth2/token", {
              headers = {
                ["Content-Type"] = "application/x-www-form-urlencoded",
              },
              body = {
                client_id     = "client-2",
                client_secret = "secret-2",
                grant_type    = "client_credentials",
              },
            })
            assert.response(res).has.status(200)
            json = assert.response(res).has.jsonbody()

            token2 = json.access_token

            client:close()
          end)

          it("is not allowed with invalid token", function()
            local res = proxy_client:get("/kong-oauth2", {
              headers = {
                Authorization = "Bearer " .. invalid_token,
              },
            })

            assert.response(res).has.status(401)
            local json = assert.response(res).has.jsonbody()
            assert.same("Unauthorized", json.message)
            error_assert(res, "invalid_token")
          end)

          it("is allowed with valid token", function()
            local res = proxy_client:get("/kong-oauth2", {
              headers = {
                Authorization = "Bearer " .. token,
              },
            })

            assert.response(res).has.status(200)
            local json = assert.response(res).has.jsonbody()
            assert.is_not_nil(json.headers.authorization)
            assert.equal(token, sub(json.headers.authorization, 8))
            assert.equal(jane.id, json.headers["x-consumer-id"])
            assert.equal(jane.username, json.headers["x-consumer-username"])
          end)

          it("maps to correct user credentials", function()
            local res = proxy_client:get("/kong-oauth2", {
              headers = {
                Authorization = "Bearer " .. token,
              },
            })

            assert.response(res).has.status(200)
            local json = assert.response(res).has.jsonbody()
            assert.is_not_nil(json.headers.authorization)
            assert.equal(token, sub(json.headers.authorization, 8))
            assert.equal(jane.id, json.headers["x-consumer-id"])
            assert.equal(jane.username, json.headers["x-consumer-username"])

            res = proxy_client:get("/kong-oauth2", {
              headers = {
                Authorization = "Bearer " .. token2,
              },
            })

            assert.response(res).has.status(200)
            json = assert.response(res).has.jsonbody()
            assert.is_not_nil(json.headers.authorization)
            assert.equal(token2, sub(json.headers.authorization, 8))
            assert.equal(jack.id, json.headers["x-consumer-id"])
            assert.equal(jack.username, json.headers["x-consumer-username"])
          end)
        end)
      end

      describe("session", function()
        local user_session
        local client_session
        local compressed_client_session
        local redis_client_session
        local redis_client_session_acl
        local invalid_session
        local user_session_header_table = {}
        local compressed_client_session_header_table = {}
        local redis_client_session_header_table = {}
        local redis_client_session_header_table_acl = {}
        local client_session_header_table = {}
        local user_token
        local client_token
        local compressed_client_token
        local redis_client_token
        local redis_client_token_acl
        local lw_user_session_header_table = {}

        lazy_setup(function()
          local client = helpers.proxy_client()
          local res = client:get("/", {
            headers = {
              Authorization = PASSWORD_CREDENTIALS,
            },
          })
          assert.response(res).has.status(200)
          local json = assert.response(res).has.jsonbody()
          local cookies = res.headers["Set-Cookie"]
          if type(cookies) == "table" then
            -- multiple cookies can be expected
            for i, cookie in ipairs(cookies) do
              user_session = sub(cookie, 0, find(cookie, ";") -1)
              user_session_header_table[i] = user_session
            end
          else
              user_session = sub(cookies, 0, find(cookies, ";") -1)
              user_session_header_table[1] = user_session
          end

          user_token = sub(json.headers.authorization, 8, -1)

          if sub(user_session, -4) == "7oig" then
            invalid_session = sub(user_session, 1, -5) .. "cYe8"
          else
            invalid_session = sub(user_session, 1, -5) .. "7oig"
          end

          res = client:get("/", {
            headers = {
              Authorization = CLIENT_CREDENTIALS,
            },
          })
          assert.response(res).has.status(200)
          local cookiesc = res.headers["Set-Cookie"]
          local jsonc = assert.response(res).has.jsonbody()
          if type(cookiesc) == "table" then
            -- multiple cookies can be expected
            for i, cookie in ipairs(cookiesc) do
              client_session = sub(cookie, 0, find(cookie, ";") -1)
              client_session_header_table[i] = client_session
            end
          else
            client_session = sub(cookiesc, 0, find(cookiesc, ";") -1)
            client_session_header_table[1] = client_session
          end

          client_token = sub(jsonc.headers.authorization, 8, -1)

          res = client:get("/compressed-session", {
            headers = {
              Authorization = CLIENT_CREDENTIALS,
            },
          })
          assert.response(res).has.status(200)
          local cprcookies = res.headers["Set-Cookie"]
          local cprjson = assert.response(res).has.jsonbody()
          if type(cprcookies) == "table" then
            -- multiple cookies can be expected
            for i, cookie in ipairs(cprcookies) do
              compressed_client_session = sub(cookie, 0, find(cookie, ";") -1)
              compressed_client_session_header_table[i] = compressed_client_session
            end
          else
            compressed_client_session = sub(cprcookies, 0, find(cprcookies, ";") -1)
            compressed_client_session_header_table[1] = compressed_client_session
          end

          compressed_client_token = sub(cprjson.headers.authorization, 8, -1)

          res = client:get("/redis-session", {
            headers = {
              Authorization = CLIENT_CREDENTIALS,
            },
          })
          assert.response(res).has.status(200)
          local rediscookies = res.headers["Set-Cookie"]
          local redisjson = assert.response(res).has.jsonbody()
          if type(rediscookies) == "table" then
            -- multiple cookies can be expected
            for i, cookie in ipairs(rediscookies) do
              redis_client_session = sub(cookie, 0, find(cookie, ";") -1)
              redis_client_session_header_table[i] = redis_client_session
            end
          else
            redis_client_session = sub(rediscookies, 0, find(rediscookies, ";") -1)
            redis_client_session_header_table[1] = redis_client_session
          end

          redis_client_token = sub(redisjson.headers.authorization, 8, -1)

          res = client:get("/redis-session-acl", {
            headers = {
              Authorization = CLIENT_CREDENTIALS,
            },
          })
          assert.response(res).has.status(200)
          rediscookies = res.headers["Set-Cookie"]
          redisjson = assert.response(res).has.jsonbody()
          if type(rediscookies) == "table" then
            -- multiple cookies can be expected
            for i, cookie in ipairs(rediscookies) do
              redis_client_session_acl = sub(cookie, 0, find(cookie, ";") -1)
              redis_client_session_header_table_acl[i] = redis_client_session_acl
            end
          else
            redis_client_session_acl = sub(rediscookies, 0, find(rediscookies, ";") -1)
            redis_client_session_header_table_acl[1] = redis_client_session_acl
          end

          redis_client_token_acl = sub(redisjson.headers.authorization, 8, -1)
        end)

        it("refreshing a token that is not yet expired due to leeway", function()
          -- testplan:
          -- get session with refresh token
          -- configure plugin w/ route that uses leeway which forces expirey
          -- query that route with session-id
          -- expect session renewal
          -- re-query with session-id and expect session to still work (if in leeway)
          -- also, we use single-use refresh tokens. That means we can't re-re-refresh
          -- but must pass if the token is still valid (due to possible concurrent requests)
          -- use newly received session-id and expect this to also work.
          proxy_client = helpers.proxy_client()
          local res0 = proxy_client:get("/leeway-refresh", {
            headers = {
              Authorization = PASSWORD_CREDENTIALS,
            },
          })
          assert.response(res0).has.status(200)
          local leeway_cookies = res0.headers["Set-Cookie"]
          lw_user_session_header_table = extract_cookie(leeway_cookies)
          proxy_client:close()

          proxy_client = helpers.proxy_client()
          local res = proxy_client:get("/leeway-refresh", {
            headers = {
              Cookie = lw_user_session_header_table,
            },
          })
          assert.response(res).has.status(200)
          local set_cookie = res.headers["Set-Cookie"]
          -- we do not expect to receive a new `Set-Cookie` as the token is not yet expired
          assert.is_nil(set_cookie)
          proxy_client:close()

          -- wait until token is expired (according to leeway)
          -- we sleep for exp - leeway + 1 = 3 seconds
          ngx.sleep(3)
          proxy_client = helpers.proxy_client()
          local res1 = proxy_client:get("/leeway-refresh", {
            headers = {
              Cookie = lw_user_session_header_table,
            },
          })
          local set_cookie_1 = res1.headers["Set-Cookie"]
          assert.is_not_nil(set_cookie_1)
          -- now extract cookie and re-send
          local new_session_cookie = extract_cookie(set_cookie_1)
          -- we are still granted access
          assert.response(res1).has.status(200)
          -- prove that we received a new session
          assert.not_same(new_session_cookie, lw_user_session_header_table)
          proxy_client:close()

          -- we have 2 seconds here to use the new session
          proxy_client = helpers.proxy_client()
          local res2 = proxy_client:get("/leeway-refresh", {
            headers = {
              Cookie = new_session_cookie
            },
          })
          -- and expect to get access
          assert.response(res2).has.status(200)
          local new_set_cookie = res2.headers["Set-Cookie"]
          -- we should not get a new cookie this time
          assert.is_nil(new_set_cookie)
          proxy_client:close()
          -- after the configured accesss_token_lifetime, we should not be able to
          -- access the protected resource. adding tests for this would mean adding a long sleep
          -- which is undesirable for this test case.

          -- reuseing the old cookie should still work
          proxy_client = helpers.proxy_client()
          local res3 = proxy_client:get("/leeway-refresh", {
            headers = {
              Cookie = lw_user_session_header_table,
            },
          })
          assert.response(res3).has.status(200)
          local new_set_cookie_r2 = res3.headers["Set-Cookie"]
          -- we can still issue a new access_token -> expect a new cookie
          assert.is_not_nil(new_set_cookie_r2)
          proxy_client:close()

          -- the refresh should fail (see logs) now due to single-use refresh_token policy
          -- but the request will proxy (without starting the session) but we do not get a new token
          proxy_client = helpers.proxy_client()
          res = proxy_client:get("/leeway-refresh", {
            headers = {
              Cookie = lw_user_session_header_table,
            },
          })
          assert.response(res).has.status(200)
          local new_set_cookie1 = res.headers["Set-Cookie"]
          -- we should not get a new cookie this time
          assert.is_nil(new_set_cookie1)
          proxy_client:close()
        end)

        it("is not allowed with invalid session", function()
          local res = proxy_client:get("/session", {
            headers = {
              Cookie = "session=" .. invalid_session,
            },
          })

          assert.response(res).has.status(401)
          local json = assert.response(res).has.jsonbody()
          assert.same("Unauthorized", json.message)
          error_assert(res, "invalid_token")
        end)


        it("is allowed with valid user session", function()
          local res = proxy_client:get("/session", {
            headers = {
              Cookie = user_session_header_table,
            }
          })

          assert.response(res).has.status(200)
          local json = assert.response(res).has.jsonbody()
          assert.is_not_nil(json.headers.authorization)
          assert.equal(user_token, sub(json.headers.authorization, 8))
        end)

        it("is allowed with valid user session with scopes validation", function()
          local res = proxy_client:get("/session_scopes", {
            headers = {
              Cookie = user_session_header_table,
            }
          })

          assert.response(res).has.status(200)
          local json = assert.response(res).has.jsonbody()
          assert.is_not_nil(json.headers.authorization)
          assert.equal(user_token, sub(json.headers.authorization, 8))
        end)

        it("is not allowed with valid user session with invalid scopes validation", function()
          local res = proxy_client:get("/session_invalid_scopes", {
            headers = {
              Cookie = user_session_header_table,
            }
          })

          assert.response(res).has.status(403)
        end)


        it("is allowed with valid client session [redis]", function()
          local res = proxy_client:get("/redis-session", {
            headers = {
              Cookie = redis_client_session_header_table,
            },
          })

          assert.response(res).has.status(200)
          local json = assert.response(res).has.jsonbody()
          assert.is_not_nil(json.headers.authorization)
          assert.equal(redis_client_token, sub(json.headers.authorization, 8))
        end)

        it("store session data in specified Redis database", function()
          local ok, res, err

          ok, err = red:select(custom_redis_db)
          assert.is_nil(err)
          assert.is_truthy(ok)
          res, err = red:scan(0)
          assert.is_nil(err)
          assert.is_not_nil(res)
          assert.are_equal('0', res[1])
          assert.are_equal(nil, next(res[2]))

          res = assert(proxy_client:get("/redis-session-db", {
            headers = {
              Authorization = CLIENT_CREDENTIALS,
            },
          }))
          assert.response(res).has.status(200)
          -- the session 'remember' is not enabled
          local session_cookies = res.headers["Set-Cookie"]
          local session_cookies_header = { sub(session_cookies, 1, find(session_cookies, ";", 1, true) -1) }
          local json_body = assert.response(res).has.jsonbody()
          local bearer_token = sub(json_body.headers.authorization, 8)

          res = proxy_client:get("/redis-session-db", {
            headers = {
              Cookie = session_cookies_header,
            },
          })
          assert.response(res).has.status(200)
          json_body = assert.response(res).has.jsonbody()
          assert.is_not_nil(json_body.headers.authorization)
          assert.equal(bearer_token, sub(json_body.headers.authorization, 8))

          res, err = red:scan(0)
          assert.is_nil(err)
          assert.is_not_nil(res)
          assert.are_equal('0', res[1])
          assert.is_table(res[2])
          assert.matches("session:%S+", res[2][1])

          red:flushdb()
        end)

        it("is allowed with valid client session [redis] using ACL", function()
          local res = proxy_client:get("/redis-session-acl", {
            headers = {
              Cookie = redis_client_session_header_table_acl,
            },
          })

          assert.response(res).has.status(200)
          local json = assert.response(res).has.jsonbody()
          assert.is_not_nil(json.headers.authorization)
          assert.equal(redis_client_token_acl, sub(json.headers.authorization, 8))
        end)

        it("is allowed with valid client session", function()
          local res = proxy_client:get("/session", {
            headers = {
              Cookie = client_session_header_table,
            },
          })

          assert.response(res).has.status(200)
          local json = assert.response(res).has.jsonbody()
          assert.is_not_nil(json.headers.authorization)
          assert.equal(client_token, sub(json.headers.authorization, 8))
        end)


        -- to be adapted for lua-resty-session v4.0.0 once session_compression_threshold is exposed
        pending("is allowed with valid client session [compressed]", function()
          local res = proxy_client:get("/session_compressed", {
            headers = {
              Cookie = compressed_client_session_header_table,
            }
          })
          assert.response(res).has.status(200)
          local json = assert.response(res).has.jsonbody()
          assert.is_not_nil(json.headers.authorization)
          assert.equal(compressed_client_token, sub(json.headers.authorization, 8))
        end)


        it("configures cookie attributes correctly", function()
          local res = proxy_client:get("/cookie-attrs", {
            headers = {
              Authorization = PASSWORD_CREDENTIALS,
            },
          })
          local cookie = res.headers["Set-Cookie"]
          assert.does_not.match("HttpOnly", cookie)
          assert.matches("Domain=example.org", cookie)
          assert.matches("Path=/test", cookie)
          assert.matches("SameSite=Default", cookie)
        end)
      end)
    end)

    describe("authorization", function()
      local proxy_client
      lazy_setup(function()
        local bp = helpers.get_db_utils(strategy, {
          "routes",
          "services",
          "plugins",
          "consumers",
        }, {
          PLUGIN_NAME,
          "ctx-checker-last"
        })
        local service = bp.services:insert {
          name = PLUGIN_NAME,
          path = "/anything"
        }

        local scopes = bp.routes:insert {
          service = service,
          paths   = { "/scopes" },
        }

        bp.plugins:insert {
          route   = scopes,
          name    = PLUGIN_NAME,
          config  = {
            issuer    = ISSUER_URL,
            client_id = {
              KONG_CLIENT_ID,
            },
            client_secret = {
              KONG_CLIENT_SECRET,
            },
            scopes_claim = {
              "scope",
            },
            scopes_required = {
              "openid email profile",
            }
          },
        }

        local and_scopes = bp.routes:insert {
          service = service,
          paths   = { "/and_scopes" },
        }

        bp.plugins:insert {
          route   = and_scopes,
          name    = PLUGIN_NAME,
          config  = {
            issuer    = ISSUER_URL,
            client_id = {
              KONG_CLIENT_ID,
            },
            client_secret = {
              KONG_CLIENT_SECRET,
            },
            scopes_claim = {
              "scope",
            },
            scopes_required = {
              "openid email profile andsomethingthatdoesntexist",
            }
          },
        }

        local or_scopes = bp.routes:insert {
          service = service,
          paths   = { "/or_scopes" },
        }

        bp.plugins:insert {
          route   = or_scopes,
          name    = PLUGIN_NAME,
          config  = {
            issuer    = ISSUER_URL,
            client_id = {
              KONG_CLIENT_ID,
            },
            client_secret = {
              KONG_CLIENT_SECRET,
            },
            scopes_claim = {
              "scope",
            },
            scopes_required = {
              "openid",
              "somethingthatdoesntexist"
            }
          },
        }

        local badscopes = bp.routes:insert {
          service = service,
          paths   = { "/badscopes" },
        }

        bp.plugins:insert {
          route   = badscopes,
          name    = PLUGIN_NAME,
          config  = {
            issuer    = ISSUER_URL,
            client_id = {
              KONG_CLIENT_ID,
            },
            client_secret = {
              KONG_CLIENT_SECRET,
            },
            scopes_claim = {
              "scope",
            },
            scopes_required = {
              "unkownscope",
            }
          },
        }

        local claimsforbidden = bp.routes:insert {
          service = service,
          paths   = { "/claimsforbidden" },
        }

        bp.plugins:insert {
          route   = claimsforbidden,
          name    = PLUGIN_NAME,
          config  = {
            issuer    = ISSUER_URL,
            client_id = {
              KONG_CLIENT_ID,
            },
            client_secret = {
              KONG_CLIENT_SECRET,
            },
            scopes_claim = {
              "scope",
            },
            claims_forbidden = {
              "preferred_username",
            },
            display_errors = true,
          },
        }

        local falseaudience = bp.routes:insert {
          service = service,
          paths   = { "/falseaudience" },
        }

        bp.plugins:insert {
          route   = falseaudience,
          name    = PLUGIN_NAME,
          config  = {
            issuer    = ISSUER_URL,
            client_id = {
              KONG_CLIENT_ID,
            },
            client_secret = {
              KONG_CLIENT_SECRET,
            },
            audience_claim = {
              "scope",
            },
            audience_required = {
              "unkownaudience",
            }
          },
        }

        local audience = bp.routes:insert {
          service = service,
          paths   = { "/audience" },
        }

        bp.plugins:insert {
          route   = audience,
          name    = PLUGIN_NAME,
          config  = {
            issuer    = ISSUER_URL,
            client_id = {
              KONG_CLIENT_ID,
            },
            client_secret = {
              KONG_CLIENT_SECRET,
            },
            -- Types of credentials/grants to enable. Limit to introspection for this case
            audience_claim = {
              "aud",
            },
            audience_required = {
              "account",
            }
          },
        }

        local testservice = bp.services:insert {
          name = 'testservice',
          path = "/anything",
        }

        local acl_route = bp.routes:insert {
          paths   = { "/acltest" },
          service = testservice
        }
        local acl_route_fails = bp.routes:insert {
          paths   = { "/acltest_fails" },
          service = testservice
        }

        local acl_route_denies = bp.routes:insert {
          paths   = { "/acltest_denies" },
          service = testservice
        }

        bp.plugins:insert {
          service = testservice,
          name    = PLUGIN_NAME,
          config  = {
            issuer    = ISSUER_URL,
            client_id = {
              KONG_CLIENT_ID,
            },
            client_secret = {
              KONG_CLIENT_SECRET,
            },
            authenticated_groups_claim = {
              "scope",
            },
          },
        }

        -- (FTI-4250) To test the groups claim with group names with spaces
        local testservice_groups_claim = bp.services:insert {
          name = 'testservice_groups_claim',
          path = "/anything",
        }

        local acl_route_groups_claim_should_allow = bp.routes:insert {
          paths   = { "/acltest_groups_claim" },
          service = testservice_groups_claim
        }

        local acl_route_groups_claim_should_fail = bp.routes:insert {
          paths   = { "/acltest_groups_claim_fail" },
          service = testservice_groups_claim
        }

        local acl_route_groups_claim_should_deny = bp.routes:insert {
          paths   = { "/acltest_groups_claim_deny" },
          service = testservice_groups_claim
        }

        bp.plugins:insert {
          service = testservice_groups_claim,
          name    = PLUGIN_NAME,
          config  = {
            issuer    = ISSUER_URL,
            client_id = {
              KONG_CLIENT_ID,
            },
            client_secret = {
              KONG_CLIENT_SECRET,
            },
            authenticated_groups_claim = {
              "groups",
            },
          },
        }

        bp.plugins:insert {
          name = "acl",
          route = acl_route_groups_claim_should_allow,
          config = {
            allow = {"test group"}
          }
        }

        bp.plugins:insert {
          name = "acl",
          route = acl_route_groups_claim_should_fail,
          config = {
            allow = {"group_that_does_not_exist"}
          }
        }

        bp.plugins:insert {
          name = "acl",
          route = acl_route_groups_claim_should_deny,
          config = {
            deny = {"test group"}
          }
        }
        -- End of (FTI-4250)

        bp.plugins:insert {
          name = "acl",
          route = acl_route,
          config = {
            allow = {"profile"}
          }
        }

        bp.plugins:insert {
          name = "acl",
          route = acl_route_fails,
          config = {
            allow = {"non-existant-scope"}
          }
        }

        bp.plugins:insert {
          name = "acl",
          route = acl_route_denies,
          config = {
            deny = {"profile"}
          }
        }

        local consumer_route = bp.routes:insert {
          paths   = { "/consumer" },
        }

        bp.plugins:insert({
          name     = "ctx-checker-last",
          route = { id = consumer_route.id },
          config   = {
            ctx_check_field = "authenticated_consumer",
          }
        })

        bp.plugins:insert {
          route   = consumer_route,
          name    = PLUGIN_NAME,
          config  = {
            issuer    = ISSUER_URL,
            client_id = {
              KONG_CLIENT_ID,
            },
            client_secret = {
              KONG_CLIENT_SECRET,
            },
            consumer_claim = {
              "preferred_username",
            },
            consumer_by = {
              "username",
            },
          },
        }

        local consumer_ignore_username_case_route = bp.routes:insert {
          paths   = { "/consumer-ignore-username-case" },
        }

        bp.plugins:insert {
          route   = consumer_ignore_username_case_route,
          name    = PLUGIN_NAME,
          config  = {
            issuer    = ISSUER_URL,
            client_id = {
              KONG_CLIENT_ID,
            },
            client_secret = {
              KONG_CLIENT_SECRET,
            },
            consumer_claim = {
              "preferred_username",
            },
            consumer_by = {
              "username",
            },
            by_username_ignore_case = true,
          },
        }


        bp.consumers:insert {
          username = "john"
        }

        bp.consumers:insert {
          username = USERNAME2_UPPERCASE
        }

        local no_consumer_route = bp.routes:insert {
          paths   = { "/noconsumer" },
        }

        bp.plugins:insert {
          route   = no_consumer_route,
          name    = PLUGIN_NAME,
          config  = {
            issuer    = ISSUER_URL,
            client_id = {
              KONG_CLIENT_ID,
            },
            client_secret = {
              KONG_CLIENT_SECRET,
            },
            -- This field does not exist in the JWT
            consumer_claim = {
              "email",
            },
            consumer_by = {
              "username",
            },
          },
        }

        assert(helpers.start_kong({
          database   = strategy,
          nginx_conf = "spec/fixtures/custom_nginx.template",
          plugins    = "bundled,ctx-checker-last," .. PLUGIN_NAME,
        }))
      end)

      lazy_teardown(function()
        helpers.stop_kong()
      end)

      before_each(function()
        proxy_client = helpers.proxy_client()
      end)

      after_each(function()
        if proxy_client then
          proxy_client:close()
        end
      end)

      describe("[claim based]",function ()
        it("prohibits access due to mismatching scope claims", function()
          local res = proxy_client:get("/badscopes", {
            headers = {
              Authorization = PASSWORD_CREDENTIALS
            },
          })
          assert.response(res).has.status(403)
          local json = assert.response(res).has.jsonbody()
          assert.same("Forbidden", json.message)
        end)

        it("grants access for matching scope claims", function()
          local res = proxy_client:get("/scopes", {
            headers = {
              Authorization = PASSWORD_CREDENTIALS
            },
          })
          assert.response(res).has.status(200)
        end)

        it("prohibits access for partially matching [AND]scope claims", function()
          local res = proxy_client:get("/and_scopes", {
            headers = {
              Authorization = PASSWORD_CREDENTIALS
            },
          })
          assert.response(res).has.status(403)
          local json = assert.response(res).has.jsonbody()
          assert.same("Forbidden", json.message)
        end)

        it("grants access for partially matching [OR]sope claims", function()
          local res = proxy_client:get("/or_scopes", {
            headers = {
              Authorization = PASSWORD_CREDENTIALS
            },
          })
          assert.response(res).has.status(200)
          assert.response(res).has.jsonbody()
        end)

        it("prohibits access due to mismatching audience claims", function()
          local res = proxy_client:get("/falseaudience", {
            headers = {
              Authorization = PASSWORD_CREDENTIALS
            },
          })
          assert.response(res).has.status(403)
          local json = assert.response(res).has.jsonbody()
          assert.same("Forbidden", json.message)
        end)

        it("grants access for matching audience claims", function()
          local res = proxy_client:get("/audience", {
            headers = {
              Authorization = PASSWORD_CREDENTIALS
            },
          })
          assert.response(res).has.status(200)
          assert.response(res).has.jsonbody()
        end)

        it("prohibits access if a forbidden claim is present", function()
          local res = proxy_client:get("/claimsforbidden", {
            headers = {
              Authorization = PASSWORD_CREDENTIALS
            },
          })
          assert.response(res).has.status(403)
          local json = assert.response(res).has.jsonbody()
          assert.same("Forbidden (forbidden claim 'preferred_username' found in access token)", json.message)
        end)
      end)

      describe("[ACL plugin]",function ()
        it("grants access for valid <allow> fields", function ()
          local res = proxy_client:get("/acltest", {
            headers = {
              Authorization = PASSWORD_CREDENTIALS,
            },
          })
          assert.response(res).has.status(200)
          assert.response(res).has.jsonbody()
          local h1 = assert.request(res).has.header("x-authenticated-groups")
          assert.equal(h1, "openid, email, profile")
        end)


        it("prohibits access for invalid <allow> fields", function ()
          local res = proxy_client:get("/acltest_fails", {
            headers = {
              Authorization = PASSWORD_CREDENTIALS,
            },
          })
          assert.response(res).has.status(403)
          local json = assert.response(res).has.jsonbody()
          assert.same("You cannot consume this service", json.message)
        end)


        it("prohibits access for matching <deny> fields", function ()
          local res = proxy_client:get("/acltest_denies", {
            headers = {
              Authorization = PASSWORD_CREDENTIALS,
            },
          })
          assert.response(res).has.status(403)
          local json = assert.response(res).has.jsonbody()
          assert.same("You cannot consume this service", json.message)
        end)

        -- (FTI-4250) To test the groups claim with group names with spaces
        it("grants access for valid <allow> fields", function ()
          local res = proxy_client:get("/acltest_groups_claim", {
            headers = {
              Authorization = PASSWORD_CREDENTIALS,
            },
          })
          assert.response(res).has.status(200)
          assert.response(res).has.jsonbody()
          local h1 = assert.request(res).has.header("x-authenticated-groups")
          assert.equal(h1, "default:super-admin, employees, test group")
        end)

        it("prohibits access for invalid <allow> fields", function ()
          local res = proxy_client:get("/acltest_groups_claim_fail", {
            headers = {
              Authorization = PASSWORD_CREDENTIALS,
            },
          })
          assert.response(res).has.status(403)
          local json = assert.response(res).has.jsonbody()
          assert.same("You cannot consume this service", json.message)
        end)


        it("prohibits access for matching <deny> fields", function ()
          local res = proxy_client:get("/acltest_groups_claim_deny", {
            headers = {
              Authorization = PASSWORD_CREDENTIALS,
            },
          })
          assert.response(res).has.status(403)
          local json = assert.response(res).has.jsonbody()
          assert.same("You cannot consume this service", json.message)
        end)
        -- End of (FTI-4250)
      end)

      describe("[by existing Consumer]",function ()
        it("grants access for existing consumer", function ()
          local res = proxy_client:get("/consumer", {
            headers = {
              Authorization = PASSWORD_CREDENTIALS
            },
          })
          assert.response(res).has.status(200)
          local h1 = assert.request(res).has.header("x-consumer-custom-id")
          assert.request(res).has.header("x-consumer-id")
          local h2 = assert.request(res).has.header("x-consumer-username")
          assert.equals("consumer-id-1", h1)
          assert.equals("john", h2)
        end)

        it("grants access for existing consumer with consumer ctx check", function ()
          local res = proxy_client:get("/consumer", {
            headers = {
              Authorization = PASSWORD_CREDENTIALS
            },
          })
          assert.response(res).has.status(200)
          local h1 = assert.request(res).has.header("x-consumer-custom-id")
          assert.request(res).has.header("x-consumer-id")
          local h2 = assert.request(res).has.header("x-consumer-username")
          assert.equals("consumer-id-1", h1)
          assert.equals("john", h2)
          assert.not_nil(res.headers["ctx-checker-last-authenticated-consumer"])
          assert.matches("john", res.headers["ctx-checker-last-authenticated-consumer"])
        end)


        it("prohibits access for non-existant consumer-claim mapping", function ()
          local res = proxy_client:get("/noconsumer", {
            headers = {
              Authorization = PASSWORD_CREDENTIALS
            },
          })
          assert.response(res).has.status(403)
          local json = assert.response(res).has.jsonbody()
          assert.same("Forbidden", json.message)
        end)

        it("prohibits access for different text-case when by_username_ignore_case=[false]", function ()
          local res = proxy_client:get("/consumer", {
            headers = {
              Authorization = USERNAME2_PASSWORD_CREDENTIALS
            },
          })
          assert.response(res).has.status(403)
          local json = assert.response(res).has.jsonbody()
          assert.same("Forbidden", json.message)
        end)

        it("grants access for different text-case when by_username_ignore_case=[true]", function ()
          local res = proxy_client:get("/consumer-ignore-username-case", {
            headers = {
              Authorization = USERNAME2_PASSWORD_CREDENTIALS
            },
          })
          assert.response(res).has.status(200)
        end)
      end)
    end)

    describe("headers", function()
      local proxy_client
      lazy_setup(function()
        local bp = helpers.get_db_utils(strategy, {
          "routes",
          "services",
          "plugins",
        }, {
          PLUGIN_NAME
        })

        local service = bp.services:insert {
          name = PLUGIN_NAME,
          path = "/anything"
        }
        local header_route = bp.routes:insert {
          service = service,
          paths   = { "/headertest" },
        }
        local header_route_bad = bp.routes:insert {
          service = service,
          paths   = { "/headertestbad" },
        }
        bp.plugins:insert {
          route   = header_route,
          name    = PLUGIN_NAME,
          config  = {
            issuer    = ISSUER_URL,
            client_id = {
              KONG_CLIENT_ID,
            },
            client_secret = {
              KONG_CLIENT_SECRET,
            },
            auth_methods = {
              "password"
            },
            upstream_headers_claims = {
              "preferred_username"
            },
            upstream_headers_names = {
              "authenticated_user"
            },
          },
        }
        bp.plugins:insert {
          route   = header_route_bad,
          name    = PLUGIN_NAME,
          config  = {
            issuer    = ISSUER_URL,
            client_id = {
              KONG_CLIENT_ID,
            },
            client_secret = {
              KONG_CLIENT_SECRET,
            },
            auth_methods = {
              "password"
            },
            upstream_headers_claims = {
              "non-existing-claim"
            },
            upstream_headers_names = {
              "authenticated_user"
            },
          },
        }

        assert(helpers.start_kong({
          database   = strategy,
          nginx_conf = "spec/fixtures/custom_nginx.template",
          plugins    = "bundled," .. PLUGIN_NAME,
        }))
      end)

      lazy_teardown(function()
        helpers.stop_kong()
      end)

      before_each(function()
        proxy_client = helpers.proxy_client()
      end)

      after_each(function()
        if proxy_client then
          proxy_client:close()
        end
      end)

      it("annotates the upstream response with headers", function ()
          local res = proxy_client:get("/headertest", {
            headers = {
              Authorization = PASSWORD_CREDENTIALS,
            },
          })
          assert.response(res).has.status(200)
          assert.response(res).has.jsonbody()
          assert.request(res).has.header("authenticated_user")
      end)

      it("doesn't annotate the upstream response with headers for non-existant claims", function ()
          local res = proxy_client:get("/headertestbad", {
            headers = {
              Authorization = PASSWORD_CREDENTIALS,
            },
          })
          assert.response(res).has.status(200)
          assert.response(res).has.jsonbody()
          assert.request(res).has.no.header("authenticated_user")
      end)
    end)

    describe("logout", function()
      local proxy_client
      lazy_setup(function()
        local bp = helpers.get_db_utils(strategy, {
          "routes",
          "services",
          "plugins",
        }, {
          PLUGIN_NAME
        })

        local service = bp.services:insert {
          name = PLUGIN_NAME,
          path = "/anything"
        }
        local route = bp.routes:insert {
          service = service,
          paths   = { "/" },
        }
        bp.plugins:insert {
          route   = route,
          name    = PLUGIN_NAME,
          config  = {
            issuer    = ISSUER_URL,
            client_id = {
              KONG_CLIENT_ID,
            },
            client_secret = {
              KONG_CLIENT_SECRET,
            },
            auth_methods = {
              "session",
              "password"
            },
            logout_uri_suffix = "/logout",
            logout_methods = {
              "POST",
            },
            -- revocation_endpoint = ISSUER_URL .. "/protocol/openid-connect/revoke",
            logout_revoke = true,
            display_errors = true
          },
        }

        assert(helpers.start_kong({
          database   = strategy,
          nginx_conf = "spec/fixtures/custom_nginx.template",
          plugins    = "bundled," .. PLUGIN_NAME,
        }))
      end)

      lazy_teardown(function()
        helpers.stop_kong()
      end)

      before_each(function()
        proxy_client = helpers.proxy_client()
      end)

      after_each(function()
        if proxy_client then
          proxy_client:close()
        end
      end)

      describe("from session |", function ()

        local user_session
        local user_session_header_table = {}
        local user_token

        lazy_setup(function()
          local client = helpers.proxy_client()
          local res = client:get("/", {
            headers = {
              Authorization = PASSWORD_CREDENTIALS,
            },
          })
          assert.response(res).has.status(200)
          local json = assert.response(res).has.jsonbody()
          local cookies = res.headers["Set-Cookie"]
          if type(cookies) == "table" then
            -- multiple cookies can be expected
            for i, cookie in ipairs(cookies) do
              user_session = sub(cookie, 0, find(cookie, ";") -1)
              user_session_header_table[i] = user_session
            end
          else
              user_session = sub(cookies, 0, find(cookies, ";") -1)
              user_session_header_table[1] = user_session
          end

          user_token = sub(json.headers.authorization, 8, -1)
        end)

        it("validate logout", function ()
          local res = proxy_client:get("/", {
            headers = {
              Cookie = user_session_header_table
            },
          })
          -- Test that the session auth works
          assert.response(res).has.status(200)
          local json = assert.response(res).has.jsonbody()
          assert.equal(user_token, sub(json.headers.authorization, 8))
          -- logout
          local lres = proxy_client:post("/logout?query-args-wont-matter=1", {
            headers = {
              Cookie = user_session_header_table,
            },
          })
          assert.response(lres).has.status(302)
          -- test if Expires=beginningofepoch
          local cookie = lres.headers["Set-Cookie"]
          local expected_header_name = "Expires="
          -- match from Expires= until next ; divider
          local expiry_init = find(cookie, expected_header_name)
          local expiry_date = sub(cookie, expiry_init + #expected_header_name, find(cookie, ';', expiry_init)-1)
          assert(expiry_date, "Thu, 01 Jan 1970 00:00:01 GMT")
          -- follow redirect (call IDP)

          local redirect = lres.headers["Location"]
          local rres, err = request_uri(redirect)
          assert.is_nil(err)
          assert.equal(200, rres.status)
        end)
      end)
    end)

    describe("logout (specify custom token param name)", function()
      local proxy_client
      lazy_setup(function()
        local bp = helpers.get_db_utils(strategy, {
          "routes",
          "services",
          "plugins",
        }, {
          PLUGIN_NAME
        })

        local service = bp.services:insert {
          name = PLUGIN_NAME,
          path = "/anything"
        }
        local route = bp.routes:insert {
          service = service,
          paths   = { "/" },
        }
        bp.plugins:insert {
          route   = route,
          name    = PLUGIN_NAME,
          config  = {
            issuer    = MOCK_ISSUER_URL,
            client_id = {
              KONG_CLIENT_ID,
            },
            client_secret = {
              KONG_CLIENT_SECRET,
            },
            auth_methods = {
              "session",
              "password"
            },
            logout_uri_suffix = "/logout",
            logout_methods = {
              "POST",
            },
	          revocation_endpoint = MOCK_ISSUER_URL .. "/protocol/openid-connect/revoke",
            revocation_token_param_name = "mytoken",
            logout_revoke = true,
            display_errors = true
          },
        }

	      assert(mock:start())
        assert(helpers.start_kong({
          database   = strategy,
          nginx_conf = "spec/fixtures/custom_nginx.template",
          plugins    = "bundled," .. PLUGIN_NAME,
        }))
      end)

      lazy_teardown(function()
        helpers.stop_kong()
	      mock:stop()
      end)

      before_each(function()
        proxy_client = helpers.proxy_client()
      end)

      after_each(function()
        if proxy_client then
          proxy_client:close()
        end
      end)

      describe("from session |", function ()

        local user_session
        local user_session_header_table = {}
        local user_token

        lazy_setup(function()
          local client = helpers.proxy_client()
          local res = client:get("/", {
            headers = {
              Authorization = PASSWORD_CREDENTIALS,
            },
          })
          assert.response(res).has.status(200)
          local json = assert.response(res).has.jsonbody()
          local cookies = res.headers["Set-Cookie"]
          if type(cookies) == "table" then
            -- multiple cookies can be expected
            for i, cookie in ipairs(cookies) do
              user_session = sub(cookie, 0, find(cookie, ";") -1)
              user_session_header_table[i] = user_session
            end
          else
              user_session = sub(cookies, 0, find(cookies, ";") -1)
              user_session_header_table[1] = user_session
          end

          user_token = sub(json.headers.authorization, 8, -1)
        end)

        it("validate logout", function ()
          local res = proxy_client:get("/", {
            headers = {
              Cookie = user_session_header_table
            },
          })
          -- Test that the session auth works
          assert.response(res).has.status(200)
          local json = assert.response(res).has.jsonbody()
          assert.equal(user_token, sub(json.headers.authorization, 8))
          -- logout
          local lres = proxy_client:post("/logout?query-args-wont-matter=1", {
            headers = {
              Cookie = user_session_header_table,
            },
          })
          assert.response(lres).has.status(302)
          -- test if Expires=beginningofepoch
          local cookie = lres.headers["Set-Cookie"]
          local expected_header_name = "Expires="
          -- match from Expires= until next ; divider
          local expiry_init = find(cookie, expected_header_name)
          local expiry_date = sub(cookie, expiry_init + #expected_header_name, find(cookie, ';', expiry_init)-1)
          assert(expiry_date, "Thu, 01 Jan 1970 00:00:01 GMT")
          -- follow redirect
          local redirect = lres.headers["Location"]
          local rres, err = request_uri(redirect)
          assert.is_nil(err)
          assert.equal(200, rres.status)
        end)
      end)
    end)

    describe("debug", function()
      local proxy_client
      lazy_setup(function()
        local bp = helpers.get_db_utils(strategy, {
          "routes",
          "services",
          "plugins",
        }, {
          PLUGIN_NAME
        })

        local service = bp.services:insert {
          name = PLUGIN_NAME,
          path = "/anything"
        }
        local debug_route = bp.routes:insert {
          service = service,
          paths   = { "/debug" },
        }
        bp.plugins:insert {
          route   = debug_route,
          name    = PLUGIN_NAME,
          config  = {
            issuer    = ISSUER_URL,
            client_id = {
              KONG_CLIENT_ID,
            },
            client_secret = {
              KONG_CLIENT_SECRET,
            },
            auth_methods = {
              "password"
            },
            audience_required = {
              -- intentionally require unknown scope to display errors
              "foo"
            },
            display_errors = true,
            verify_nonce = false,
            verify_claims = false,
            verify_signature = false
        },
        }
        local debug_route_1 = bp.routes:insert {
          service = service,
          paths   = { "/debug_1" },
        }
        bp.plugins:insert {
          route   = debug_route_1,
          name    = PLUGIN_NAME,
          config  = {
            issuer    = ISSUER_URL,
            client_id = {
              KONG_CLIENT_ID,
            },
            client_secret = {
              KONG_CLIENT_SECRET,
            },
            auth_methods = {
              "bearer"
            },
            display_errors = true,
        },
        }

        assert(helpers.start_kong({
          database   = strategy,
          nginx_conf = "spec/fixtures/custom_nginx.template",
          plugins    = "bundled," .. PLUGIN_NAME,
        }))
      end)

      lazy_teardown(function()
        helpers.stop_kong()
      end)

      before_each(function()
        proxy_client = helpers.proxy_client()
      end)

      after_each(function()
        if proxy_client then
          proxy_client:close()
        end
      end)

      it("adds extra information to the error messages", function ()
        local res = proxy_client:get("/debug", {
          headers = {
            Authorization = PASSWORD_CREDENTIALS,
          },
        })
        assert.response(res).has.status(403)
        local json = assert.response(res).has.jsonbody()
        assert.matches("Forbidden %(required %w+ are missing. Found: %[ %w+ ]%)", json.message)
      end)

      it("invalid bearer token responds with the correct log message", function ()
        local res = proxy_client:get("/debug_1", {
          headers = {
            Authorization = "Bearer I dunno token",
          },
        })
        assert.response(res).has.status(401)
        local json = assert.response(res).has.jsonbody()
        assert.matches("Unauthorized %(invalid bearer token%)", json.message)
        error_assert(res, "invalid_token")
      end)
    end)

    describe("JSON body", function()
      local proxy_client
      lazy_setup(function()
        local bp = helpers.get_db_utils(
          strategy == "off" and "postgres" or strategy,
          {
            "routes",
            "services",
            "plugins",
          },
          {
            PLUGIN_NAME,
          }
        )

        local service = bp.services:insert {
          name = PLUGIN_NAME,
          path = "/anything"
        }

        local route = bp.routes:insert {
          service = service,
          paths   = { "/oidc" },
        }
        bp.plugins:insert {
          route   = route,
          name    = PLUGIN_NAME,
          config  = {
            issuer    = ISSUER_URL,
            client_id = {
              KONG_CLIENT_ID,
            },
            client_secret = {
              KONG_CLIENT_SECRET,
            },
            auth_methods = {
              "bearer",
            },
            bearer_token_param_type = {
              "header",
              "body",
            },
            display_errors = true,
          },
        }

        local route2 = bp.routes:insert {
          service = service,
          paths   = { "/oidc2" },
        }
        bp.plugins:insert {
          route   = route2,
          name    = PLUGIN_NAME,
          config  = {
            issuer    = ISSUER_URL,
            client_id = {
              KONG_CLIENT_ID,
              "0d0413e8-8471-4ee5-a736-692428b9eaa2",
              "68470bc0-1290-4304-ba1e-04859923ed66",
              "4f72580e-c568-4a7a-a6aa-1157d0955551"
            },
            client_secret = {
              KONG_CLIENT_SECRET,
            },
            auth_methods = {
              "bearer",
            },
            bearer_token_param_type = {
              "header",
            },
            display_errors = true,
          },
        }

        assert(helpers.start_kong({
          database   = strategy,
          nginx_conf = "spec/fixtures/custom_nginx.template",
          plugins    = PLUGIN_NAME,
          declarative_config = strategy == "off" and helpers.make_yaml_file() or nil,
          pg_host = strategy == "off" and "unknownhost.konghq.com" or nil,
          nginx_worker_processes = 1,
        }))
      end)

      lazy_teardown(function()
        helpers.stop_kong()
      end)

      before_each(function()
        proxy_client = helpers.proxy_client()
      end)

      after_each(function()
        if proxy_client then
          proxy_client:close()
        end
      end)

      it("detect JSON null on reques", function ()
        local res = proxy_client:post("/oidc", {
          headers = {
            ["Authorization"] = "Bearer ",
            ["Content-Type"] = "application/json",
          },
          body = "null",
        })
        assert.response(res).has.status(401)
        local json = assert.response(res).has.jsonbody()
        assert.are_equal("Unauthorized (no suitable authorization credentials were provided)", json.message)
      end)
      it("detect JSON null on multiple clients", function ()
        local res = proxy_client:post("/oidc2", {
          headers = {
            ["Authorization"] = "Bearer ",
            ["Content-Type"] = "application/json",
          },
          body = "null",
        })
        assert.response(res).has.status(401)
        local json = assert.response(res).has.jsonbody()
        assert.are_equal("Unauthorized (no suitable authorization credentials were provided)", json.message)
      end)
      it("detect bad JSON string", function()
        local res = proxy_client:post("/oidc", {
          headers = {
            ["Authorization"] = "Bearer ",
            ["Content-Type"] = "application/json",
          },
          body = '"null"',
        })
        assert.response(res).has.status(401)
        local json = assert.response(res).has.jsonbody()
        assert.are_equal("Unauthorized (no suitable authorization credentials were provided)", json.message)
      end)

      it("detect bad JSON number", function()
        local res = proxy_client:post("/oidc", {
          headers = {
            ["Authorization"] = "Bearer ",
            ["Content-Type"] = "application/json",
          },
          body = 5,
        })
        assert.response(res).has.status(401)
        local json = assert.response(res).has.jsonbody()
        assert.are_equal("Unauthorized (no suitable authorization credentials were provided)", json.message)
      end)

      it("detect bad JSON bool", function()
        local res = proxy_client:post("/oidc", {
          headers = {
            ["Authorization"] = "Bearer ",
            ["Content-Type"] = "application/json",
          },
          body = true,
        })
        assert.response(res).has.status(401)
        local json = assert.response(res).has.jsonbody()
        assert.are_equal("Unauthorized (no suitable authorization credentials were provided)", json.message)
      end)

      it("detect valid JSON data", function()
        local res = proxy_client:post("/oidc", {
          headers = {
            ["Authorization"] = "Bearer ",
            ["Content-Type"] = "application/json",
          },
          body = { hello = "world" },
        })
        assert.response(res).has.status(401)
        local json = assert.response(res).has.jsonbody()
        assert.are_equal("Unauthorized (no suitable authorization credentials were provided)", json.message)
      end)
    end)

    describe("FTI-2737", function()
      local proxy_client
      lazy_setup(function()
        local bp = helpers.get_db_utils(strategy, {
          "routes",
          "services",
          "plugins",
        }, {
          PLUGIN_NAME
        })

        local service = bp.services:insert {
          name = PLUGIN_NAME,
          path = "/anything"
        }
        local anon_route = bp.routes:insert {
          service = service,
          paths   = { "/anon" },
        }
        local route = bp.routes:insert {
          service = service,
          paths   = { "/non-anon" },
        }
        local anon = bp.consumers:insert {
          username = "anonymous"
        }

        bp.plugins:insert {
          route   = anon_route,
          name    = PLUGIN_NAME,
          config  = {
            issuer    = ISSUER_URL,
            client_id = {
              KONG_CLIENT_ID,
            },
            client_secret = {
              KONG_CLIENT_SECRET,
            },
            auth_methods = {
              "password"
            },
            anonymous = anon.id,
            scopes_required = {
              "non-existant-scopes"
            }
          },
        }
        bp.plugins:insert {
          route   = route,
          name    = PLUGIN_NAME,
          config  = {
            issuer    = ISSUER_URL,
            client_id = {
              KONG_CLIENT_ID,
            },
            client_secret = {
              KONG_CLIENT_SECRET,
            },
            auth_methods = {
              "password"
            },
            anonymous = anon.id,
            scopes_required = {
              "profile"
            }
          },
        }
        assert(helpers.start_kong({
          database   = strategy,
          nginx_conf = "spec/fixtures/custom_nginx.template",
          plugins    = "bundled," .. PLUGIN_NAME,
        }))
      end)

      lazy_teardown(function()
        helpers.stop_kong()
      end)

      before_each(function()
        proxy_client = helpers.proxy_client()
      end)

      after_each(function()
        if proxy_client then
          proxy_client:close()
        end
      end)

      it("scopes do not match. expect to set anonymous header", function ()
        local res = proxy_client:get("/anon", {
          headers = {
            Authorization = PASSWORD_CREDENTIALS,
          },
        })
        assert.response(res).has.status(200)
        local h1 = assert.request(res).has.header("x-anonymous-consumer")
        assert.equal(h1, "true")
        local h2 = assert.request(res).has.header("x-consumer-username")
        assert.equal(h2, "anonymous")
      end)

      it("scopes match. expect to authenticate", function ()
        local res = proxy_client:get("/non-anon", {
          headers = {
            Authorization = PASSWORD_CREDENTIALS,
          },
        })
        assert.response(res).has.status(200)
        assert.request(res).has.no.header("x-anonymous-consumer")
        assert.request(res).has.no.header("x-consumer-username")
      end)
    end)

    describe("FTI-2774", function()
      local proxy_client
      lazy_setup(function()
        local bp = helpers.get_db_utils(strategy, {
          "routes",
          "services",
          "plugins",
        }, {
          PLUGIN_NAME
        })

        local service = bp.services:insert {
          name = PLUGIN_NAME,
          path = "/anything"
        }
        local route = bp.routes:insert {
          service = service,
          paths   = { "/" },
        }

        bp.plugins:insert {
          route   = route,
          name    = PLUGIN_NAME,
          config  = {
            issuer    = ISSUER_URL,
            client_id = {
              KONG_CLIENT_ID,
            },
            client_secret = {
              KONG_CLIENT_SECRET,
            },
            auth_methods = {
              "authorization_code",
            },
            authorization_query_args_client = {
              "test-query",
            }
          },
        }

        assert(helpers.start_kong({
          database   = strategy,
          nginx_conf = "spec/fixtures/custom_nginx.template",
          plugins    = "bundled," .. PLUGIN_NAME,
        }))
      end)

      lazy_teardown(function()
        helpers.stop_kong()
      end)

      before_each(function()
        proxy_client = helpers.proxy_client()
      end)

      after_each(function()
        if proxy_client then
          proxy_client:close()
        end
      end)

      it("authorization query args from the client are always passed to authorization endpoint", function ()
          local res = proxy_client:get("/", {
            headers = {
              ["Host"] = KONG_HOST,
            }
          })
          assert.response(res).has.status(302)
          local location1 = res.headers["Location"]

          local auth_cookie = res.headers["Set-Cookie"]
          local auth_cookie_cleaned = sub(auth_cookie, 0, find(auth_cookie, ";") -1)

          res = proxy_client:get("/", {
            headers = {
              ["Host"] = KONG_HOST,
              Cookie = auth_cookie_cleaned
            }
          })

          assert.response(res).has.status(302)
          local location2 = res.headers["Location"]

          assert.equal(location1, location2)

          res = proxy_client:get("/", {
            query = {
              ["test-query"] = "test",
            },
            headers = {
              ["Host"] = KONG_HOST,
              Cookie = auth_cookie_cleaned,
            }
          })
          assert.response(res).has.status(302)
          local location3 = res.headers["Location"]

          local auth_cookie2 = res.headers["Set-Cookie"]
          local auth_cookie_cleaned2 = sub(auth_cookie2, 0, find(auth_cookie2, ";") -1)

          assert.not_equal(location1, location3)

          local query = sub(location3, find(location3, "?", 1, true) + 1)
          local args = ngx.decode_args(query)

          assert.equal("test", args["test-query"])

          res = proxy_client:get("/", {
            headers = {
              ["Host"] = KONG_HOST,
              Cookie = auth_cookie_cleaned2,
            }
          })

          local location4 = res.headers["Location"]
          assert.equal(location4, location1)

          res = proxy_client:get("/", {
            query = {
              ["test-query"] = "test2",
            },
            headers = {
              ["Host"] = KONG_HOST,
              Cookie = auth_cookie_cleaned2,
            }
          })

          local location5 = res.headers["Location"]
          assert.not_equal(location5, location1)
          assert.not_equal(location5, location2)
          assert.not_equal(location5, location3)
          assert.not_equal(location5, location4)

          local query2 = sub(location5, find(location5, "?", 1, true) + 1)
          local args2 = ngx.decode_args(query2)

          assert.equal("test2", args2["test-query"])
      end)
    end)

    describe("FTI-3305", function()
      local proxy_client

      lazy_setup(function()
        local bp = helpers.get_db_utils(strategy, {
          "routes",
          "services",
          "plugins",
        }, {
          PLUGIN_NAME
        })

        local service = bp.services:insert {
          name = PLUGIN_NAME,
          path = "/anything"
        }
        local route = bp.routes:insert {
          service = service,
          paths   = { "/" },
        }

        bp.plugins:insert {
          route   = route,
          name    = PLUGIN_NAME,
          config  = {
            issuer    = ISSUER_URL,
            auth_methods = {
              "authorization_code",
              "session",
            },
            client_id = {
              KONG_CLIENT_ID,
            },
            client_secret = {
              KONG_CLIENT_SECRET,
            },
            session_secret = "kong",
            session_storage = "redis",
            session_redis_host = REDIS_HOST,
            session_redis_port = REDIS_PORT_ERR,
            session_redis_username = "default",
            session_redis_password = os.getenv("REDIS_PASSWORD") or nil,
            login_action = "redirect",
            login_tokens = {},
            preserve_query_args = true,
          },
        }

        assert(helpers.start_kong({
          database   = strategy,
          nginx_conf = "spec/fixtures/custom_nginx.template",
          plugins    = "bundled," .. PLUGIN_NAME,
        }))
      end)

      lazy_teardown(function()
        helpers.stop_kong()
      end)

      before_each(function()
        proxy_client = helpers.proxy_client()
      end)

      after_each(function()
        if proxy_client then
          proxy_client:close()
        end
      end)

      it("returns 500 upon session storage error", function()
        local res = proxy_client:get("/", {
          headers = {
            ["Host"] = "kong"
          }
        })
        assert.response(res).has.status(500)

        local raw_body = res:read_body()
        local json_body = cjson.decode(raw_body)
        assert.equal(json_body.message, "An unexpected error occurred")
      end)
    end)

    describe("FTI-4684 specify anonymous by name and uuid", function()
      local proxy_client, user_by_id, user_by_name
      lazy_setup(function()
        local bp = helpers.get_db_utils(strategy, {
          "routes",
          "services",
          "plugins",
        }, {
          PLUGIN_NAME
        })

        local service = bp.services:insert {
          name = PLUGIN_NAME,
          path = "/anything"
        }
        local anon_by_id_route = bp.routes:insert {
          service = service,
          paths   = { "/anon-by-uuid" },
        }
        local anon_by_name_route = bp.routes:insert {
          service = service,
          paths   = { "/anon-by-name" },
        }
        user_by_id = bp.consumers:insert {
          username = "anon"
        }
        user_by_name = bp.consumers:insert {
          username = "guyfawkes"
        }
        bp.plugins:insert {
          route   = anon_by_id_route,
          name    = PLUGIN_NAME,
          config  = {
            issuer    = ISSUER_URL,
            client_id = {
              KONG_CLIENT_ID,
            },
            client_secret = {
              KONG_CLIENT_SECRET,
            },
            auth_methods = {
              "password"
            },
            anonymous = user_by_id.id,
          },
        }
        bp.plugins:insert {
          route   = anon_by_name_route,
          name    = PLUGIN_NAME,
          config  = {
            issuer    = ISSUER_URL,
            client_id = {
              KONG_CLIENT_ID,
            },
            client_secret = {
              KONG_CLIENT_SECRET,
            },
            auth_methods = {
              "password"
            },
            anonymous = user_by_name.username,
          },
        }
        assert(helpers.start_kong({
          database   = strategy,
          nginx_conf = "spec/fixtures/custom_nginx.template",
          plugins    = "bundled," .. PLUGIN_NAME,
        }))
      end)

      lazy_teardown(function()
        helpers.stop_kong()
      end)

      before_each(function()
        proxy_client = helpers.proxy_client()
      end)

      after_each(function()
        if proxy_client then
          proxy_client:close()
        end
      end)

      it("expect anonymous user to be set correctly when defined by uuid", function ()
        local res = proxy_client:get("/anon-by-uuid", {
          headers = {
            Authorization = "incorrectpw",
          },
        })
        assert.response(res).has.status(200)
        local anon_consumer = assert.request(res).has.header("x-anonymous-consumer")
        assert.is_same(anon_consumer, "true")
        local id = assert.request(res).has.header("x-consumer-id")
        assert.equal(id, user_by_id.id)
      end)

      it("expect anonymous user to be set correctly when defined by name", function ()
        local res = proxy_client:get("/anon-by-name", {
          headers = {
            Authorization = "incorrectpw",
          },
        })
        assert.response(res).has.status(200)
        local anon_consumer = assert.request(res).has.header("x-anonymous-consumer")
        assert.is_same(anon_consumer, "true")
        local id = assert.request(res).has.header("x-consumer-id")
        assert.equal(id, user_by_name.id)
      end)
    end)

    describe("FTI-5861 existing anonymous consumer should not be cached to nil", function()
      local proxy_client, anonymous_test
      lazy_setup(function()
        local bp = helpers.get_db_utils(strategy, {
          "routes",
          "services",
          "plugins",
        }, {
          PLUGIN_NAME, "key-auth"
        })

        local service = bp.services:insert {
          path = "/anything"
        }
        local oidc_route = bp.routes:insert {
          service = service,
          paths   = { "/oidc-test" },
        }
        local keyauth_route = bp.routes:insert {
          service = service,
          paths   = { "/keyauth-test" },
        }
        anonymous_test = bp.consumers:insert {
          username = "anonymous_test"
        }
        bp.plugins:insert {
          route   = oidc_route,
          name    = PLUGIN_NAME,
          config  = {
            issuer    = ISSUER_URL,
            client_id = {
              KONG_CLIENT_ID,
            },
            client_secret = {
              KONG_CLIENT_SECRET,
            },
            auth_methods = {
              "password"
            },
            anonymous = anonymous_test.username,
          },
        }
        bp.plugins:insert {
          route   = keyauth_route,
          name    = "key-auth",
          config  = {
            anonymous = anonymous_test.username,
          },
        }
        assert(helpers.start_kong({
          database   = strategy,
          nginx_conf = "spec/fixtures/custom_nginx.template",
          plugins    = "bundled," .. PLUGIN_NAME,
        }))
      end)

      lazy_teardown(function()
        helpers.stop_kong()
      end)

      before_each(function()
        proxy_client = helpers.proxy_client()
      end)

      after_each(function()
        if proxy_client then
          proxy_client:close()
        end
      end)

      it("key-auth plugin should pass after call oidc first", function ()
        local res = proxy_client:get("/oidc-test", {
          headers = {
            Authorization = "incorrectpw",
          },
        })
        assert.response(res).has.status(200)
        local anon_consumer = assert.request(res).has.header("x-anonymous-consumer")
        assert.is_same(anon_consumer, "true")
        local id = assert.request(res).has.header("x-consumer-id")
        assert.equal(id, anonymous_test.id)

        res = proxy_client:get("/keyauth-test")
        assert.response(res).has.status(200)
      end)
    end)

    for _, c in ipairs({
      {
        alg = "ES256",
        id = "kong-es256-client",
        secret = "efd3cccb-bc98-421b-9db8-eaa15ba85e29"
      },{
        alg = "ES384",
        id = "kong-es384-client",
        secret = "ea7da3fc-cd2a-4901-a263-1155a3a58d86"
      },{
        alg = "ES512",
        id = "kong-es512-client",
        secret = "06a20403-1428-42dc-a72e-c9e7f7db1ad3"
      }
    }) do
      describe("FTI-4877 tokens with ECDSA " .. c.alg .. " alg", function()
        local proxy_client
        lazy_setup(function()
          local bp = helpers.get_db_utils(strategy, {
            "routes",
            "services",
            "plugins",
          }, {
            PLUGIN_NAME
          })

          local service = bp.services:insert {
            name = PLUGIN_NAME,
            path = "/anything"
          }
          local ecdsa_route = bp.routes:insert {
            service = service,
            paths   = { "/ecdsa" },
          }
          bp.plugins:insert {
            route   = ecdsa_route,
            name    = PLUGIN_NAME,
            config  = {
              issuer = ISSUER_URL,
              client_id = {
                c.id,
              },
              client_secret = {
                c.secret,
              },
              auth_methods = {
                "password",
                "bearer"
              },
              client_alg = {
                "ES256",
                "ES384",
                "ES512",
              },
              scopes = {
                "openid",
              },
              rediscovery_lifetime = 0,
            },
          }
          assert(helpers.start_kong({
            database   = strategy,
            nginx_conf = "spec/fixtures/custom_nginx.template",
            plugins    = "bundled," .. PLUGIN_NAME,
          }))
        end)

        lazy_teardown(function()
          helpers.stop_kong()
        end)

        before_each(function()
          proxy_client = helpers.proxy_client()
        end)

        after_each(function()
          if proxy_client then
            proxy_client:close()
          end
        end)

        it("verification passes and request is authorized", function()
          local res = proxy_client:get("/ecdsa", {
            headers = {
              Authorization = PASSWORD_CREDENTIALS,
            },
          })
          assert.response(res).has.status(200)
          local json = assert.response(res).has.jsonbody()
          local bearer_token = json.headers.authorization
          assert.is_not_nil(bearer_token)
          assert.equal("Bearer", sub(bearer_token, 1, 6))

          res = proxy_client:get("/ecdsa", {
            headers = {
              Authorization = bearer_token,
            },
          })
          assert.response(res).has.status(200)
        end)
      end)
    end

    describe("#configure tests", function()
      local proxy_client
      for _, include_scope in ipairs{false, true} do
        describe("token_cache_key_include_scope=" .. tostring(include_scope), function()
          describe("configuring scopes via config.token_post_args_*", function()
            lazy_setup(function()
              local bp = helpers.get_db_utils(strategy, {
                "routes",
                "services",
                "plugins",
              }, {
                PLUGIN_NAME
              })

              local service = bp.services:insert {
                name = PLUGIN_NAME,
                path = "/anything"
              }
              local scope1_route = bp.routes:insert {
                service = service,
                paths   = { "/scope1" },
              }
              local scope2_route = bp.routes:insert {
                service = service,
                paths   = { "/scope2" },
              }

              local config = {
                issuer    = ISSUER_URL,
                client_id = {
                  KONG_CLIENT_ID,
                },
                client_secret = {
                  KONG_CLIENT_SECRET,
                },
                auth_methods = {
                  "session",
                  "password"
                },
                logout_uri_suffix = "/logout",
                logout_methods = {
                  "POST",
                },
                logout_revoke = true,
                display_errors = true,
                preserve_query_args = true,
                token_cache_key_include_scope = include_scope,
                cache_tokens_salt = "same",
                scopes_required = { "address" },
                token_post_args_names = { "scope" },
                token_post_args_values = { "address" },
              }

              bp.plugins:insert {
                route   = scope1_route,
                name    = PLUGIN_NAME,
                config  = config,
              }

              config.token_post_args_values = { "phone" }

              bp.plugins:insert {
                route   = scope2_route,
                name    = PLUGIN_NAME,
                config  = config,
              }

              assert(helpers.start_kong({
                database   = strategy,
                nginx_conf = "spec/fixtures/custom_nginx.template",
                plugins    = "bundled," .. PLUGIN_NAME,
              }))
            end)

            lazy_teardown(function()
              helpers.stop_kong(nil, true)
            end)

            before_each(function()
              proxy_client = helpers.proxy_client()
            end)

            after_each(function()
              if proxy_client then
                proxy_client:close()
              end
            end)

            it("works", function()
              local res = assert(proxy_client:send({
                method = "GET",
                path = "/scope1",
                headers = {
                  ["Host"] = KONG_HOST,
                  ["Authorization"] = PASSWORD_CREDENTIALS,
                }
              }))
              assert.response(res).has.status(200)

              res = assert(proxy_client:send({
                method = "GET",
                path = "/scope2",
                headers = {
                  ["Host"] = KONG_HOST,
                  ["Authorization"] = PASSWORD_CREDENTIALS,
                }
              }))

              -- with scope the token is considered different.
              -- the second request will get a new token with scope phone
              -- and thus cannot pass the scope check
              if include_scope then
                assert.response(res).has.status(403)
              else
                -- but if the option is disabled, it will use the same token
                -- which has scope address, thus pass the scope check
                assert.response(res).has.status(200)
              end
            end)
          end)

          describe("configuring scopes via config.scopes", function()
            lazy_setup(function()
              local bp = helpers.get_db_utils(strategy, {
                "routes",
                "services",
                "plugins",
              }, {
                PLUGIN_NAME
              })

              local service = bp.services:insert {
                name = PLUGIN_NAME,
                path = "/anything"
              }
              local scope1_route = bp.routes:insert {
                service = service,
                paths   = { "/scope1" },
              }
              local scope2_route = bp.routes:insert {
                service = service,
                paths   = { "/scope2" },
              }

              local config = {
                issuer    = ISSUER_URL,
                client_id = {
                  KONG_CLIENT_ID,
                },
                client_secret = {
                  KONG_CLIENT_SECRET,
                },
                auth_methods = {
                  "session",
                  "password"
                },
                logout_uri_suffix = "/logout",
                logout_methods = {
                  "POST",
                },
                logout_revoke = true,
                display_errors = true,
                preserve_query_args = true,
                token_cache_key_include_scope = include_scope,
                cache_tokens_salt = "same",
                scopes_required = { "address" },
                scopes = {
                  "address",
                },
              }

              bp.plugins:insert {
                route   = scope1_route,
                name    = PLUGIN_NAME,
                config  = config,
              }

              config.scopes = { "phone" }

              bp.plugins:insert {
                route   = scope2_route,
                name    = PLUGIN_NAME,
                config  = config,
              }

              assert(helpers.start_kong({
                database   = strategy,
                nginx_conf = "spec/fixtures/custom_nginx.template",
                plugins    = "bundled," .. PLUGIN_NAME,
              }))
            end)

            lazy_teardown(function()
              helpers.stop_kong()
            end)

            before_each(function()
              proxy_client = helpers.proxy_client()
            end)

            after_each(function()
              if proxy_client then
                proxy_client:close()
              end
            end)

            it("works", function()
              local res = assert(proxy_client:send({
                method = "GET",
                path = "/scope1",
                headers = {
                  ["Host"] = KONG_HOST,
                  ["Authorization"] = PASSWORD_CREDENTIALS,
                }
              }))
              assert.response(res).has.status(200)

              res = assert(proxy_client:send({
                method = "GET",
                path = "/scope2",
                headers = {
                  ["Host"] = KONG_HOST,
                  ["Authorization"] = PASSWORD_CREDENTIALS,
                }
              }))

              -- with scope the token is considered different.
              -- the second request will get a new token with scope phone
              -- and thus cannot pass the scope check
              if include_scope then
                assert.response(res).has.status(403)
              else
                -- but if the option is disabled, it will use the same token
                -- which has scope address, thus pass the scope check
                assert.response(res).has.status(200)
              end
            end)
          end)

          describe("configuring scopes from the client's request", function()
            lazy_setup(function()
              local bp = helpers.get_db_utils(strategy, {
                "routes",
                "services",
                "plugins",
              }, {
                PLUGIN_NAME
              })

              local service = bp.services:insert {
                name = PLUGIN_NAME,
                path = "/anything"
              }
              local scope1_route = bp.routes:insert {
                service = service,
                paths   = { "/scope1" },
              }
              local scope2_route = bp.routes:insert {
                service = service,
                paths   = { "/scope2" },
              }

              local config = {
                issuer    = ISSUER_URL,
                client_id = {
                  KONG_CLIENT_ID,
                },
                client_secret = {
                  KONG_CLIENT_SECRET,
                },
                auth_methods = {
                  "session",
                  "password"
                },
                logout_uri_suffix = "/logout",
                logout_methods = {
                  "POST",
                },
                logout_revoke = true,
                display_errors = true,
                preserve_query_args = true,
                token_cache_key_include_scope = include_scope,
                cache_tokens_salt = "same",
                scopes_required = { "address" },
                token_post_args_client = {
                  "scope",
                }
              }

              bp.plugins:insert {
                route   = scope1_route,
                name    = PLUGIN_NAME,
                config  = config,
              }

              bp.plugins:insert {
                route   = scope2_route,
                name    = PLUGIN_NAME,
                config  = config,
              }

              assert(helpers.start_kong({
                database   = strategy,
                nginx_conf = "spec/fixtures/custom_nginx.template",
                plugins    = "bundled," .. PLUGIN_NAME,
              }))
            end)

            lazy_teardown(function()
              helpers.stop_kong()
            end)

            before_each(function()
              proxy_client = helpers.proxy_client()
            end)

            after_each(function()
              if proxy_client then
                proxy_client:close()
              end
            end)

            it("works", function()
              local res = assert(proxy_client:get("/scope1", {
                query = {
                  scope = "address",
                },
                headers = {
                  ["Host"] = KONG_HOST,
                  ["Authorization"] = PASSWORD_CREDENTIALS,
                },
              }))
              assert.response(res).has.status(200)

              res = assert(proxy_client:get("/scope2", {
                query = {
                  scope = "phone",
                },
                headers = {
                  ["Host"] = KONG_HOST,
                  ["Authorization"] = PASSWORD_CREDENTIALS,
                },
              }))

              -- with scope the token is considered different.
              -- the second request will get a new token with scope phone
              -- and thus cannot pass the scope check
              if include_scope then
                assert.response(res).has.status(403)
              else
                -- but if the option is disabled, it will use the same token
                -- which has scope address, thus pass the scope check
                assert.response(res).has.status(200)
              end
            end)
          end)
        end)
      end

      for _, using_pseudo_issuer in ipairs{false, true} do
        describe("using_pseudo_issuer=" .. tostring(using_pseudo_issuer), function()
          local plugin, db
          lazy_setup(function()
            mock:start()

            local bp
            -- clear all tables to purge OIDC discovery cache
            bp, db = helpers.get_db_utils(strategy, nil, {
              PLUGIN_NAME
            })

            local service = bp.services:insert {
              name = PLUGIN_NAME,
              path = "/"
            }

            local route = bp.routes:insert {
              service = service,
              paths   = { "/" },
            }

            plugin = bp.plugins:insert {
              route   = route,
              name    = PLUGIN_NAME,
              config  = {
                issuer    = MOCK_ISSUER_URL,
                using_pseudo_issuer = using_pseudo_issuer,
              },
            }

            assert(helpers.start_kong({
              database   = strategy,
              nginx_conf = "spec/fixtures/custom_nginx.template",
              plugins    = "bundled," .. PLUGIN_NAME,
            }))
          end)

          lazy_teardown(function()
            helpers.stop_kong()
            mock:stop()
            -- clear tables to avoid conflicts with other tests
            assert(db:truncate())
          end)

          it("works", function()
            -- trigger discovery
            local client = helpers.proxy_client()
            assert(client:send({
              method = "GET",
              path = "/",
              headers = {
                ["Host"] = KONG_HOST,
                ["Authorization"] = PASSWORD_CREDENTIALS,
              }
            }))

            if using_pseudo_issuer then
              mock.eventually:has_no_request()
            else
              mock.eventually:has_request()
            end

            local admin_client = assert(helpers.admin_client())
            assert(admin_client:send{
              method = "PATCH",
              path = "/plugins/" .. plugin.id,
              body = {
                config = {
                  rediscovery_lifetime = 100,
                }
              },
              headers = {
                ["Content-Type"] = "application/json"
              }
            })

            -- either way the plugin should not make a request
            -- if it successfully cached the discovery document it should not
            -- if it's using the pseudo issuer it should not
            mock.eventually:has_no_request()
          end)
        end)
      end

      describe("unauthorized_destroy_session", function()
        lazy_setup(function ()
          local bp = helpers.get_db_utils(strategy, {
            "routes",
            "services",
            "plugins",
          }, {
            PLUGIN_NAME
          })

          local service = bp.services:insert {
            name = "service1",
            path = "/anything"
          }
          local route1 = bp.routes:insert {
            service = service,
            paths   = { "/true" },
          }

          local config = {
            issuer    = ISSUER_URL,
            client_id = {
              KONG_CLIENT_ID,
            },
            client_secret = {
              KONG_CLIENT_SECRET,
            },
            auth_methods = {
              "session",
              "password",
            },
            logout_uri_suffix = "/logout",
            logout_methods = {
              "POST",
            },
            scopes = {
              "openid",
            },
            logout_revoke = true,
            display_errors = true,
            preserve_query_args = true,
            cache_tokens_salt = "same",
            unauthorized_destroy_session = true,
            refresh_tokens = true,
            upstream_refresh_token_header = "refresh_token",
            refresh_token_param_name      = "refresh_token",
          }

          bp.plugins:insert {
            route   = route1,
            name    = PLUGIN_NAME,
            config  = config,
          }

          local route2 = bp.routes:insert {
            service = service,
            paths   = { "/false" },
          }

          config.unauthorized_destroy_session = false

          bp.plugins:insert {
            route   = route2,
            name    = PLUGIN_NAME,
            config  = config,
          }

          local route3 = bp.routes:insert {
            service = service,
            paths   = { "/nil" },
          }

          config.unauthorized_destroy_session = nil

          bp.plugins:insert {
            route   = route3,
            name    = PLUGIN_NAME,
            config  = config,
          }

          -- can't update 'plugins' entities in DBless mode
          -- so use different plugin instances to construct 401 responses
          config.issuers_allowed = { "http://invalid/", }

          config.unauthorized_destroy_session = true

          local route4 = bp.routes:insert {
            service = service,
            paths   = { "/true_invalid" },
          }

          bp.plugins:insert {
            route   = route4,
            name    = PLUGIN_NAME,
            config  = config,
          }

          config.unauthorized_destroy_session = false

          local route5 = bp.routes:insert {
            service = service,
            paths   = { "/false_invalid" },
          }

          bp.plugins:insert {
            route   = route5,
            name    = PLUGIN_NAME,
            config  = config,
          }

          config.unauthorized_destroy_session = nil

          local route6 = bp.routes:insert {
            service = service,
            paths   = { "/nil_invalid" },
          }

          bp.plugins:insert {
            route   = route6,
            name    = PLUGIN_NAME,
            config  = config,
          }

          assert(helpers.start_kong({
            database   = strategy,
            nginx_conf = "spec/fixtures/custom_nginx.template",
            plugins    = "bundled," .. PLUGIN_NAME,
          }))
        end)
        lazy_teardown(function()
          helpers.stop_kong()
        end)

        before_each(function()
          proxy_client = helpers.proxy_client()
        end)

        local cases = { "true" , "false", "nil", }
        local invalids = { "true_invalid" , "false_invalid", "nil_invalid", }
        for i, v in ipairs(cases) do
          it("=" .. v, function()
            local res = assert(proxy_client:send({
              method = "GET",
              path = "/" .. v,
              headers = {
                ["Host"] = KONG_HOST,
                ["Authorization"] = PASSWORD_CREDENTIALS,
              }
            }))
            assert.response(res).has.status(200)
            local cookies = res.headers["Set-Cookie"]
            local valid_session = sub(cookies, 0, find(cookies, ";") -1)

            res = assert(proxy_client:send({
              method = "GET",
              path = "/" .. invalids[i],
              headers = {
                ["Host"] = KONG_HOST,
                ["Cookie"] = valid_session,
              }
            }))
            assert.response(res).has.status(401)

            if v == "true" or v == "nil" then
              assert.response(res).has.header("set-cookie")
              assert.match("session=;", res.headers["set-cookie"], nil, true)
            else
              assert.response(res).has.no.header("set-cookie")
            end
          end)
        end
      end)
    end)

    describe("FTI-5247 public client support", function()
      lazy_setup(function()
        local bp = helpers.get_db_utils(strategy,{
          "routes",
            "services",
            "plugins",
        }, {
          PLUGIN_NAME,
        })

        local service = bp.services:insert {
          name = "FTI-5247",
          path = "/anything"
        }

        local route_1 = bp.routes:insert {
          service = service,
          paths   = { "/FTI-5247-1" },
        }

        bp.plugins:insert {
          route   = route_1,
          name    = PLUGIN_NAME,
          config  = {
            display_errors = true,
            issuer = ISSUER_URL,
            auth_methods = {
              "password",
            },
            password_param_type = {
              "body",
            },
            client_id = {
              PUBLIC_CLIENT_ID,
            },
            client_auth = {
              "none"
            },
          },
        }

        local route_2 = bp.routes:insert {
          service = service,
          paths   = { "/FTI-5247-2" },
        }

        bp.plugins:insert {
          route   = route_2,
          name    = PLUGIN_NAME,
          config  = {
            display_errors = true,
            issuer = ISSUER_URL,
            auth_methods = {
              "password",
            },
            password_param_type = {
              "body",
            },
            client_id = {
              PUBLIC_CLIENT_ID,
            },
            token_endpoint_auth_method  = "none",
          },
        }

        local route_3 = bp.routes:insert {
          service = service,
          paths   = { "/FTI-5247-3" },
        }

        bp.plugins:insert {
          route   = route_3,
          name    = PLUGIN_NAME,
          config  = {
            display_errors = true,
            issuer = ISSUER_URL,
            auth_methods = {
              "password",
            },
            password_param_type = {
              "body",
            },
            client_id = {
              PUBLIC_CLIENT_ID,
            },
          },
        }

        assert(helpers.start_kong({
          database   = strategy,
          nginx_conf = "spec/fixtures/custom_nginx.template",
          plugins    = "bundled," .. PLUGIN_NAME,
        }))
      end)

      lazy_teardown(function()
        helpers.stop_kong()
      end)

      it("works when client_auth is 'none'", function()
        assert
        .with_timeout(15)
        .with_max_tries(10)
        .with_step(0.05)
        .ignore_exceptions(true)
        .eventually(function()
          local proxy_client = helpers.proxy_client()

          local res = proxy_client:post("/FTI-5247-1", {
            headers = {
              ["Content-Type"] = "application/x-www-form-urlencoded",
            },
            body = {
              username = USERNAME,
              password = PASSWORD,
            },
          })

          local body = assert.res_status(200, res)
          local json_body = cjson.decode(body)

          assert.is_not_nil(json_body.headers.authorization)
          assert.equal("Bearer", sub(json_body.headers.authorization, 1, 6))

          proxy_client:close()
        end)
        .has_no_error("invalid status code received from the token endpoint (401)")
      end)

      it("works when token_endpoint_auth_method is 'none'", function()
        local proxy_client = helpers.proxy_client()
        local res = proxy_client:post("/FTI-5247-2", {
          headers = {
            ["Content-Type"] = "application/x-www-form-urlencoded",
          },
          body = {
            username = USERNAME,
            password = PASSWORD,
          },
        })

        local body = assert.res_status(200, res)
        local json_body = cjson.decode(body)

        assert.is_not_nil(json_body.headers.authorization)
        assert.equal("Bearer", sub(json_body.headers.authorization, 1, 6))

        proxy_client:close()
      end)

      it("error when neither client_auth nor token_endpoint_auth_method is 'none'", function()
        local proxy_client = helpers.proxy_client()
        local res = proxy_client:post("/FTI-5247-3", {
          headers = {
            ["Content-Type"] = "application/x-www-form-urlencoded",
          },
          body = {
            username = USERNAME,
            password = PASSWORD,
          },
        })

        local body = assert.res_status(401, res)
        local json_body = cjson.decode(body)
        assert.matches('Unauthorized %(failed to get from node cache: invalid status code received from the token endpoint %(400%)%)', json_body.message)
        error_assert(res, "invalid_token")

        proxy_client:close()
      end)

    end)

    describe("token_post_args_client", function()
      local proxy_client
      lazy_setup(function()
        local bp = helpers.get_db_utils(strategy, {
          "routes",
          "services",
          "plugins",
        }, {
          PLUGIN_NAME
        })

        local service = bp.services:insert {
          name = PLUGIN_NAME,
          path = "/anything"
        }
        local route = bp.routes:insert {
          service = service,
          paths   = { "/test" },
        }

        local config = {
          issuer    = ISSUER_URL,
          client_id = {
            KONG_CLIENT_ID,
          },
          client_secret = {
            KONG_CLIENT_SECRET,
          },
          auth_methods = {
            "password"
          },
          logout_uri_suffix = "/logout",
          logout_methods = {
            "POST",
          },
          logout_revoke = true,
          display_errors = true,
          preserve_query_args = true,
          cache_tokens_salt = "same",
          scopes = { "default-to-invalid" },
          scopes_required = { "openid" },
          token_post_args_client = { "scope" },
        }

        bp.plugins:insert {
          route   = route,
          name    = PLUGIN_NAME,
          config  = config,
        }

        assert(helpers.start_kong({
          database   = strategy,
          nginx_conf = "spec/fixtures/custom_nginx.template",
          plugins    = "bundled," .. PLUGIN_NAME,
        }))
      end)

      lazy_teardown(function()
        helpers.stop_kong(nil, true)
      end)

      before_each(function()
        proxy_client = helpers.proxy_client()
      end)

      after_each(function()
        if proxy_client then
          proxy_client:close()
        end
      end)

      it("should fail without the required scope", function()
        local res = assert(proxy_client:send({
          method = "GET",
          path = "/test",
          headers = {
            ["Host"] = KONG_HOST,
            ["Authorization"] = PASSWORD_CREDENTIALS,
          }
        }))
        assert.response(res).has.status(401)
      end)

      it("take scope from the uri arg", function()
        local res = assert(proxy_client:send({
          method = "GET",
          path = "/test?scope=openid",
          headers = {
            ["Host"] = KONG_HOST,
            ["Authorization"] = PASSWORD_CREDENTIALS,
          }
        }))
        assert.response(res).has.status(200)
      end)

      it("take scope from the body arg", function()
        local res = assert(proxy_client:send({
          method = "GET",
          path = "/test",
          headers = {
            ["Host"] = KONG_HOST,
            ["Authorization"] = PASSWORD_CREDENTIALS,
            ["Content-Type"] = "application/x-www-form-urlencoded",
          },
          body = { scope = "openid" },
        }))
        assert.response(res).has.status(200)
      end)

      it("take scope from the header", function()
        local res = assert(proxy_client:send({
          method = "GET",
          path = "/test",
          headers = {
            ["Host"] = KONG_HOST,
            ["Authorization"] = PASSWORD_CREDENTIALS,
            ["Scope"] = "openid",
          }
        }))
        assert.response(res).has.status(200)
      end)
    end)

    for _, enabled in ipairs{true, false} do
      describe("introspection cache, cluster_cache = " .. tostring(enabled), function()
        local is_introspecting, proxy_client, proxy_client2
        lazy_setup(function()
          local bp = helpers.get_db_utils(strategy, {
            "routes",
            "services",
            "plugins",
          }, {
            PLUGIN_NAME
          })

          local service = bp.services:insert {
            path = "/anything"
          }
          local route_get = bp.routes:insert {
            service = service,
            paths   = { "/get" },
          }
          local route = bp.routes:insert {
            service = service,
            paths   = { "/test" },
          }

          local config = {
            issuer = MOCK_ISSUER_URL,
            introspection_endpoint = MOCK_ISSUER_URL .. "/protocol/openid-connect/token/introspect",
            client_id = {
              KONG_CLIENT_ID,
            },
            client_secret = {
              KONG_CLIENT_SECRET,
            },
            auth_methods = {
              "password"
            },
            cluster_cache_strategy   = enabled and "redis" or "off",
            cluster_cache_redis = {
              host = REDIS_HOST,
              port = REDIS_PORT,
            },
          }

          bp.plugins:insert {
            route   = route_get,
            name    = PLUGIN_NAME,
            config  = config,
          }

          config.auth_methods = {
            "introspection",
          }

          bp.plugins:insert {
            route   = route,
            name    = PLUGIN_NAME,
            config  = config,
          }

          local route_wrong_redis = bp.routes:insert {
            service = service,
            paths   = { "/wrong-redis" },
          }

          config.cluster_cache_redis = {
            host = REDIS_HOST,
            port = REDIS_PORT + 1,
          }

          bp.plugins:insert {
            route   = route_wrong_redis,
            name    = PLUGIN_NAME,
            config  = config,
          }

          assert(mock:start())

          assert(helpers.start_kong({
            database                 = strategy,
            nginx_conf               = "spec/fixtures/custom_nginx.template",
            plugins                  = "bundled," .. PLUGIN_NAME,
            admin_listen             = "off"
          }))

          assert(helpers.start_kong({
            database                 = strategy,
            nginx_conf               = "spec/fixtures/custom_nginx.template",
            plugins                  = "bundled," .. PLUGIN_NAME,
            prefix                   = "servroot2",
            proxy_listen             = "0.0.0.0:" .. NODE2PORT,
            admin_listen             = "off"
          }))

          function is_introspecting(token)
            return function(req)
              assert.same("POST", req.method)
              assert.same(REALM_PATH .. "/protocol/openid-connect/token/introspect", req.uri)
              assert.matches("token=" .. token, req.body, nil, true)
            end
          end

          proxy_client = assert(helpers.proxy_client())
          proxy_client2 = assert(helpers.proxy_client(nil, NODE2PORT))
        end)

        lazy_teardown(function()
          helpers.stop_kong()
          helpers.stop_kong("servroot2")
          mock:stop()
          proxy_client:close()
        end)

        it("should cache in redis", function()
          -- get a token from node a
          local res = assert(proxy_client:send({
            method = "GET",
            path = "/get",
            headers = {
              ["Host"] = KONG_HOST,
              ["Authorization"] = PASSWORD_CREDENTIALS,
            }
          }))
          assert.response(res).has.status(200)

          local json = assert.response(res).has.jsonbody()
          assert.equal("Bearer", sub(json.headers.authorization, 1, 6))
          local token = sub(json.headers.authorization, 8)
          assert.is_not_nil(token)

          -- should introspect
          local res2 = assert(proxy_client:send({
            method = "GET",
            path = "/test",
            headers = {
              ["Host"] = KONG_HOST,
              ["Authorization"] = "Bearer " .. token,
            }
          }))
          assert.response(res2).has.status(200)

          mock.eventually:has_request_satisfy(is_introspecting(token))

          -- should have already been cached
          local res3 = assert(proxy_client:send({
            method = "GET",
            path = "/test",
            headers = {
              ["Host"] = KONG_HOST,
              ["Authorization"] = "Bearer " .. token,
            }
          }))
          assert.response(res3).has.status(200)
          -- no new introspection request as it should be cached
          mock.eventually:has_no_request_satisfy(is_introspecting(token))

          -- should be fetchable in the other node as well if cluster_cache is enabled
          local res4 = assert(proxy_client2:send({
            method = "GET",
            path = "/test",
            headers = {
              ["Host"] = KONG_HOST,
              ["Authorization"] = "Bearer " .. token,
            }
          }))
          assert.response(res4).has.status(200)

          if enabled then
            -- no new introspection request as it should be cached in redis
            mock.eventually:has_no_request_satisfy(is_introspecting(token))
          else
            -- new introspection request as it should not be cached in redis
            mock.eventually:has_request_satisfy(is_introspecting(token))
          end

          -- should not be fail the request when redis cache fails
          local res5 = assert(proxy_client:send({
            method = "GET",
            path = "/wrong-redis",
            headers = {
              ["Host"] = KONG_HOST,
              ["Authorization"] = "Bearer " .. token,
            }
          }))
          assert.response(res5).has.status(200)
        end)
      end)
    end
  end)
end
