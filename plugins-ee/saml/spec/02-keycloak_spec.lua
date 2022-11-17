-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local xmlua   = require "xmlua"
local redis   = require "resty.redis"
local http    = require "resty.http"
local xpath   = require "kong.plugins.saml.utils.xpath"

local version = require "version"
local helpers = require "spec.helpers"


local sub               = string.sub
local find              = string.find

local PLUGIN_NAME        = "saml"
local USERNAME           = "samluser1"
local PASSWORD           = "pass1234#"
local KEYCLOAK_HOST      = "keycloak"
local KEYCLOAK_PORT      = 8080
local REALM_PATH         = "/auth/realms/demo"

local IDP_DESCRIPTOR_URL = "http://" .. KEYCLOAK_HOST .. ":" .. KEYCLOAK_PORT .. REALM_PATH .. "/protocol/saml/descriptor"
local IDP_SSO_URL        = "http://" .. KEYCLOAK_HOST .. ":" .. KEYCLOAK_PORT .. REALM_PATH .. "/protocol/saml"

local ISSUER_URL         = "http://keycloaksamldemo"

local REDIS_HOST         = helpers.redis_host
local REDIS_PORT         = 6379
local REDIS_USER_VALID   = "saml-user"
local REDIS_PASSWORD     = "secret"


local function extract_cookie(cookies)
  local client_session
  local client_session_header_table = {}
  -- extract session cookies
  for i, cookie in ipairs(cookies) do
    client_session = sub(cookie, 0, find(cookie, ";") -1)
    -- making session cookie invalid
    client_session = client_session .. "invalid"
    client_session_header_table[i] = client_session
  end
  return client_session_header_table
end


local function re_first_group(text, re)
  local match = ngx.re.match(text, re)
  if match then
    return match[1]
  end
end


local function redis_connect()
  local redis = redis:new()
  redis:set_timeout(2000)
  assert(redis:connect(REDIS_HOST, REDIS_PORT))
  local redis_password = os.getenv("REDIS_PASSWORD") or nil -- This will allow for testing with a secured redis instance
  if redis_password then
    assert(redis:auth(redis_password))
  end
  local redis_version = string.match(redis:info(), 'redis_version:([%g]+)\r\n')
  return redis, assert(version(redis_version))
end


local function add_redis_user(redis, redis_version)
  if redis_version >= version("6.0.0") then
    assert(redis:acl(
        "setuser",
        REDIS_USER_VALID,
        "on", "allkeys", "+incrby", "+select", "+info", "+expire", "+get", "+exists",
        ">" .. REDIS_PASSWORD
    ))
  end
end


local function remove_redis_user(redis, redis_version)
  if redis_version >= version("6.0.0") then
    assert(redis:acl("deluser", REDIS_USER_VALID))
  end
end


local ENTITIES = {
  lt = "<",
  gt = ">",
  amp = "&",
  quot = '"',
  apos = "'",
}

local function decode_html_entities(string)
  return ngx.re.gsub(string, "&([a-z]+);", function(match) return ENTITIES[match[1]] or "" end)
end


local function extract_from_html(html, re)
  return decode_html_entities(re_first_group(html, re))
end


local function find_form_field_value(html, field_name)
  return extract_from_html(html, 'name="' .. field_name .. '" value="(.*?)"')
end


local function find_form_action(html)
  return extract_from_html(html, [[action="(.*?)"]])
end


local function sp_init_flow(res, username, password) 
  local body = res:read_body()
  assert.equal(200, res.status)
  assert.is_not_nil(body)
  local sso_url = find_form_action(body)
  local saml_assertion = find_form_field_value(body, "SAMLRequest")
  local relay_state = find_form_field_value(body, "RelayState")
  local client = http.new()
  local login_page, err = client:request_uri(sso_url, {
      method  = "POST",
      headers = {
        -- impersonate as browser
        ["Content-Type"] = "application/x-www-form-urlencoded",
        ["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/93.0.4577.63 Safari/537.36", -- luacheck: ignore
        ["Host"] = "keycloak:8080",
      },
      body = "SAMLRequest=" .. ngx.escape_uri(saml_assertion) .. "&RelayState=" .. ngx.escape_uri(relay_state),
  })
  assert.is_nil(err)
  assert.equal(302, login_page.status)

  -- after sending login data to the login action page, expect a redirect
  local upstream_url = login_page.headers["Location"]
  local login_page_redirect, err = client:request_uri(upstream_url, {
      headers = {
        -- send session cookie
        Cookie = extract_cookie(login_page.headers["Set-Cookie"])
      }
  })
  assert.is_nil(err)
  assert.equal(200, login_page_redirect.status)
  assert.is_not_nil(login_page_redirect.body)

  body = login_page_redirect.body
  local login_url = find_form_action(body)
  local login_res, err = client:request_uri(login_url, {
      method = "POST",
      headers = {
        -- impersonate as browser
        ["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/93.0.4577.63 Safari/537.36", --luacheck: ignore
        -- due to form_data
        ["Content-Type"] = "application/x-www-form-urlencoded",
        -- send session cookie
        Cookie = extract_cookie(login_page_redirect.headers["Set-Cookie"])
      },
      body = "username=" .. username .. "&password=" .. password,
  })
  assert.is_nil(err)
  assert.equal(200, login_res.status)
  assert.is_not_nil(login_res.body)

  return find_form_field_value(login_res.body, "SAMLResponse"), find_form_field_value(login_res.body, "RelayState")
end


local function retrieve_cert_from_idp()
  local client = http.new()
  local res, err = client:request_uri(IDP_DESCRIPTOR_URL, { method = "GET" })
  assert.is_nil(err)
  assert.equal(200, res.status)
  local body = xmlua.XML.parse(res.body)
  local cert = xpath.evaluate(body, "/md:EntityDescriptor/md:IDPSSODescriptor/md:KeyDescriptor/dsig:KeyInfo/dsig:X509Data/dsig:X509Certificate/text()")
  assert.is_truthy(cert)
  return cert
end


for _, strategy in helpers.all_strategies() do
  if strategy ~= "cassandra" then
    for _, session_storage in ipairs {"memcache", "redis", "cookie"} do
      describe(PLUGIN_NAME .. ": #" .. strategy .. "_" .. session_storage, function()
          local redis
          local redis_version

          setup(function()
              redis, redis_version = redis_connect()
              add_redis_user(redis, redis_version)

          end)

          teardown(function()
              remove_redis_user(redis, redis_version)
          end)

          local proxy_client

          lazy_setup(function()
              local db_strategy = strategy ~= "off" and strategy or nil
              local bp = helpers.get_db_utils(db_strategy, {
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

              local anon = bp.consumers:insert {
                username = "anonymous"
              }

              bp.consumers:insert {
                username = "samluser1",
              }

              local route_anon = bp.routes:insert {
                service = service,
                paths   = { "/anon" },
              }

              local route_non_anon = bp.routes:insert {
                service = service,
                paths   = { "/non-anon" },
              }

              local idp_cert = retrieve_cert_from_idp()

              bp.plugins:insert {
                route   = route_anon,
                name    = PLUGIN_NAME,
                config  = {
                  issuer    = ISSUER_URL,
                  assertion_consumer_path = "/consume",
                  idp_sso_url = IDP_SSO_URL,
                  nameid_format = "EmailAddress",
                  idp_certificate = idp_cert,
                  session_storage = session_storage,
                  validate_assertion_signature = false,
                  anonymous = anon.id,
                },
              }

              bp.plugins:insert {
                route   = route_non_anon,
                name    = PLUGIN_NAME,
                config  = {
                  issuer    = ISSUER_URL,
                  assertion_consumer_path = "/consume",
                  idp_sso_url = IDP_SSO_URL,
                  nameid_format = "EmailAddress",
                  idp_certificate = idp_cert,
                  session_storage = session_storage,
                  validate_assertion_signature = false,
                },
              }

              assert(helpers.start_kong({
                    database   = db_strategy,
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

          it("SP request with anonymous consumer is successful", function()
              local res = proxy_client:get("/anon", {
                  headers = {
                    ["Host"] = "kong",
                    ["Accept"] = "text/html",
                  }
              })
              local saml_response, relay_state = sp_init_flow(res, USERNAME, PASSWORD)
              local response, err = proxy_client:post("/anon/consume", {
                  headers = {
                    ["Host"] = "kong",
                    ["Content-Type"] = "application/x-www-form-urlencoded",
                  },
                  body = "SAMLResponse=" .. ngx.escape_uri(saml_response) .. "&RelayState=" .. ngx.escape_uri(relay_state),
              })
              assert.is_nil(err)
              assert.equal(302, response.status)

          end)

          it("SP request with consumer is successful", function()
              local res = proxy_client:get("/non-anon", {
                  headers = {
                    ["Host"] = "kong",
                    ["Accept"] = "text/html",
                  }
              })
              local saml_response, relay_state = sp_init_flow(res, USERNAME, PASSWORD)
              local response, err = proxy_client:post("/non-anon/consume", {
                  headers = {
                    ["Host"] = "kong",
                    ["Content-Type"] = "application/x-www-form-urlencoded",
                  },
                  body = "SAMLResponse=" .. ngx.escape_uri(saml_response) .. "&RelayState=" .. ngx.escape_uri(relay_state),
              })
              assert.is_nil(err)
              assert.equal(302, response.status)

          end)

          it("invalid SAMLResponse posted to /consume callback results in 400 error", function()
              local response, err = proxy_client:post("/anon/consume", {
                  headers = {
                    ["Content-Type"] = "application/x-www-form-urlencoded",
                  },
                  body = "SAMLResponse=not_valid",
              })
              assert.is_nil(err)
              assert.equal(400, response.status)

          end)

          it("SP request with missing consumer is rejected", function()
              local res = proxy_client:get("/non-anon", {
                  headers = {
                    ["Host"] = "kong",
                    ["Accept"] = "text/html",
                  }
              })
              local saml_response, relay_state = sp_init_flow(res, "samluser2", "pass1234#")
              local response, err = proxy_client:post("/non-anon/consume", {
                  headers = {
                    ["Content-Type"] = "application/x-www-form-urlencoded",
                  },
                  body = "SAMLResponse=" .. ngx.escape_uri(saml_response) .. "&RelayState=" .. ngx.escape_uri(relay_state),
              })

              assert.is_nil(err)
              assert.equal(302, response.status)
          end)

          it("POST data is preserved during IdP interaction", function()
              local res = proxy_client:post("/non-anon", {
                  headers = {
                    ["Host"] = "kong",
                    ["Accept"] = "text/html",
                    ["Content-type"] = "application/x-www-form-urlencoded",
                  },
                  body = {
                    this = "is",
                    some = "body",
                  },
              })
              local saml_response, relay_state = sp_init_flow(res, "samluser2", "pass1234#")
              local res, err = proxy_client:post("/non-anon/consume", {
                  headers = {
                    ["Content-Type"] = "application/x-www-form-urlencoded",
                  },
                  body = "SAMLResponse=" .. ngx.escape_uri(saml_response) .. "&RelayState=" .. ngx.escape_uri(relay_state),
              })

              assert.is_nil(err)
              assert.equal(200, res.status)
              local body = res:read_body()
              assert.equal("is", find_form_field_value(body, "this"))
              assert.equal("body", find_form_field_value(body, "some"))
          end)

          it("POST request with unsupported encoding is rejected", function()
              local res = proxy_client:post("/non-anon", {
                  headers = {
                    ["Host"] = "kong",
                    ["Accept"] = "text/html",
                    ["Content-type"] = "multipart/form-data",
                  },
                  body = {
                    this = "is",
                    some = "body",
                  },
              })
              assert.equal(415, res.status)
          end)

          it("API request with no session is rejected as unauthorized", function()
              local res = proxy_client:get("/non-anon", {
                  headers = {
                    ["Host"] = "kong",
                    ["Accept"] = "application/json",
                  }
              })
              assert.equal(401, res.status)
          end)
      end)
    end
  end
end
