-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]


local helpers = require "spec.helpers"
local cjson = require "cjson.safe"


local encode_base64 = ngx.encode_base64
local sub = string.sub
local find = string.find


local PLUGIN_NAME = "openid-connect"
local KEYCLOAK_HOST = "keycloak"
local KEYCLOAK_PORT = 8080
local KEYCLOAK_SSL_PORT = 8443
local REALM_PATH = "/auth/realms/demo"
local DISCOVERY_PATH = "/.well-known/openid-configuration"
local ISSUER_URL = "http://" .. KEYCLOAK_HOST .. ":" .. KEYCLOAK_PORT .. REALM_PATH
local ISSUER_SSL_URL = "https://" .. KEYCLOAK_HOST .. ":" .. KEYCLOAK_SSL_PORT .. REALM_PATH

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

local KONG_CLIENT_ID = "kong-client-secret"
local KONG_CLIENT_SECRET = "38beb963-2786-42b8-8e14-a5f391b4ba93"


for _, strategy in helpers.all_strategies() do
  describe(PLUGIN_NAME .. ": (keycloak) with strategy: " .. strategy .. " ->", function()
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

        local code_flow_route = bp.routes:insert {
          service = service,
          paths   = { "/code-flow" },
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
            session_redis_host = "redis",
          },
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
          hash_secret   = true,
          consumer      = jane
        }

        jack = bp.consumers:insert {
          username = "jack",
        }

        bp.oauth2_credentials:insert {
          name          = "demo-2",
          client_id     = "client-2",
          client_secret = "secret-2",
          hash_secret   = true,
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

      describe("authorization code flow", function()
        it("initial request, expect redirect to login page", function()
          local res = proxy_client:get("/code-flow", {
            headers = {
              ["Host"] = "kong"
            }
          })
          assert.response(res).has.status(302)
          local redirect = res.headers["Location"]
          -- get authorization=...; cookie
          local auth_cookie = res.headers["Set-Cookie"]
          local auth_cookie_cleaned = sub(auth_cookie, 0, find(auth_cookie, ";") -1)
          local http = require "resty.http".new()
          local rres, err = http:request_uri(redirect, {
            headers = {
              -- impersonate as browser
              ["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/93.0.4577.63 Safari/537.36", -- luacheck: ignore
              ["Host"] = "keycloak:8080",
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
              ["Host"] = "keycloak:8080",
              -- due to form_data
              ["Content-Type"] = "application/x-www-form-urlencoded",
              Cookie = user_session_header_table,
          }}
          local loginres
          loginres, err = http:request_uri(login_button_url, opts)
          assert.is_nil(err)
          assert.equal(302, loginres.status)

          -- after sending login data to the login action page, expect a redirect
          local upstream_url = loginres.headers["Location"]
          local ures
          ures, err = http:request_uri(upstream_url, {
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
            client_session_header_table[i] = client_session
          end
          local ures_final
          ures_final, err = http:request_uri(final_url, {
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
        end)

        it("post wrong login credentials", function()
          local res = proxy_client:get("/code-flow", {
            headers = {
              ["Host"] = "kong"
            }
          })
          assert.response(res).has.status(302)

          local redirect = res.headers["Location"]
          -- get authorization=...; cookie
          local auth_cookie = res.headers["Set-Cookie"]
          local auth_cookie_cleaned = sub(auth_cookie, 0, find(auth_cookie, ";") -1)
          local http = require "resty.http".new()
          local rres, err = http:request_uri(redirect, {
            headers = {
              -- impersonate as browser
              ["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/93.0.4577.63 Safari/537.36", --luacheck: ignore
              ["Host"] = "keycloak:8080",
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
              ["Host"] = "keycloak:8080",
              -- due to form_data
              ["Content-Type"] = "application/x-www-form-urlencoded",
              Cookie = user_session_header_table,
          }}
          local loginres
          loginres, err = http:request_uri(login_button_url, opts)
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
              ["Host"] = "kong",
            }
          })
          assert.response(res).has.status(302)
          local redirect = res.headers["Location"]
          -- get authorization=...; cookie
          local auth_cookie = res.headers["Set-Cookie"]
          local auth_cookie_cleaned = sub(auth_cookie, 0, find(auth_cookie, ";") -1)
          local http = require "resty.http".new()
          local rres, err = http:request_uri(redirect, {
            headers = {
              -- impersonate as browser
              ["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/93.0.4577.63 Safari/537.36", -- luacheck: ignore
              ["Host"] = "keycloak:8080",
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
              ["Host"] = "keycloak:8080",
              -- due to form_data
              ["Content-Type"] = "application/x-www-form-urlencoded",
              Cookie = user_session_header_table,
          }}
          local loginres
          loginres, err = http:request_uri(login_button_url, opts)
          assert.is_nil(err)
          assert.equal(302, loginres.status)

          -- after sending login data to the login action page, expect a redirect
          local upstream_url = loginres.headers["Location"]
          local ures
          ures, err = http:request_uri(upstream_url, {
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
          ures_final, err = http:request_uri(final_url, {
            headers = {
              -- send session cookie
              Cookie = client_session_header_table
            }
          })

          assert.is_nil(err)
          assert.equal(302, ures_final.status)
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
          local invalid_token2


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

            local client = helpers.proxy_ssl_client()
            local res = client:post("/auth/oauth2/token", {
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
            local json = assert.response(res).has.jsonbody()

            token2 = json.access_token

            if sub(token, -4) == "7oig" then
              invalid_token2 = sub(token, 1, -5) .. "cYe8"
            else
              invalid_token2 = sub(token, 1, -5) .. "7oig"
            end

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
            assert.equal(jane.id, json.headers["X-Consumer-Id"])
            assert.equal(jane.username, json.headers["X-Consumer-Username"])
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
            assert.equal(jane.id, json.headers["X-Consumer-Id"])
            assert.equal(jane.username, json.headers["X-Consumer-Username"])

            local res = proxy_client:get("/kong-oauth2", {
              headers = {
                Authorization = "Bearer " .. token2,
              },
            })

            assert.response(res).has.status(200)
            local json = assert.response(res).has.jsonbody()
            assert.is_not_nil(json.headers.authorization)
            assert.equal(token, sub(json.headers.authorization, 8))
            assert.equal(jack.id, json.headers["X-Consumer-Id"])
            assert.equal(jack.username, json.headers["X-Consumer-Username"])
          end)
        end)
      end

      describe("session", function()
        local user_session
        local client_session
        local compressed_client_session
        local redis_client_session
        local invalid_session
        local user_session_header_table = {}
        local compressed_client_session_header_table = {}
        local redis_client_session_header_table = {}
        local client_session_header_table = {}
        local user_token
        local client_token
        local compressed_client_token
        local redis_client_token

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

          client:close()
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


        it("is allowed with valid client session [compressed]", function()
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
          PLUGIN_NAME
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
          local lres = proxy_client:post("/logout", {
            headers = {
              Cookie = user_session_header_table,
            },
          })
          assert.response(lres).has.status(302)
          -- test if Expires=beginningofepoch
          local cookie_after_logout = lres.headers["Set-Cookie"]
          local expected_header_name = "Expires="
          for _, cookie in ipairs(cookie_after_logout) do
            -- match from Expires= until next ; divider
            local expiry_init = find(cookie, expected_header_name)
            local expiry_date = sub(cookie, expiry_init + #expected_header_name, find(cookie, ';', expiry_init)-1)
            assert(expiry_date, "Thu, 01 Jan 1970 00:00:01 GMT")
          end
          -- follow redirect
          local redirect = lres.headers["Location"]
          local rres = proxy_client:post(redirect, {
            headers = {
              Cookie = user_session_header_table,
            },
          })
          assert.response(rres).has.status(200)
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
        assert.matches("Forbidden *", json.message)
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
              ["Host"] = "kong",
            }
          })
          assert.response(res).has.status(302)
          local location1 = res.headers["Location"]

          local auth_cookie = res.headers["Set-Cookie"]
          local auth_cookie_cleaned = sub(auth_cookie, 0, find(auth_cookie, ";") -1)

          res = proxy_client:get("/", {
            headers = {
              ["Host"] = "kong",
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
              ["Host"] = "kong",
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
              ["Host"] = "kong",
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
              ["Host"] = "kong",
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
  end)
end
