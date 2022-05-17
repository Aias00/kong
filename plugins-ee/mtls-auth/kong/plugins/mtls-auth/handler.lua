-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

--- Copyright 2019 Kong Inc.

-- In http subsystem we don't have functions like ngx.ocsp and
-- get full client chain working. Masking this plugin as a noop
-- plugin so it will not error out.
if ngx.config.subsystem ~= "http" then
    return {}
end

local ngx = ngx
local mtls_cache = require("kong.plugins.mtls-auth.cache")
local access = require("kong.plugins.mtls-auth.access")
local certificate = require("kong.enterprise_edition.tls.plugins.certificate")
local sni_filter = require("kong.enterprise_edition.tls.plugins.sni_filter")
local kong_global = require("kong.global")
local PHASES = kong_global.phases

local TTL_FOREVER = { ttl = 0 }
local SNI_CACHE_KEY = require("kong.plugins.mtls-auth.cache").SNI_CACHE_KEY


local MtlsAuthHandler = {
  PRIORITY = 1006,
  VERSION = "0.3.5"
}

local plugin_name = "mtls-auth"


function MtlsAuthHandler:access(conf)
  access.execute(conf)
end


function MtlsAuthHandler:init_worker()
  -- TODO: remove nasty hacks once we have singleton phases support in core

  local orig_ssl_certificate = Kong.ssl_certificate   -- luacheck: ignore
  Kong.ssl_certificate = function()                   -- luacheck: ignore
    orig_ssl_certificate()

    local ctx = ngx.ctx
    -- ensure phases are set
    ctx.KONG_PHASE = PHASES.certificate

    kong_global.set_namespaced_log(kong, plugin_name)

    local snis_set, err = kong.cache:get(SNI_CACHE_KEY, TTL_FOREVER,
      sni_filter.build_ssl_route_filter_set, plugin_name)

    if err then
    kong.log.err("unable to request client to present its certificate: ",
          err)
    return ngx.exit(ngx.ERROR)
    end

    certificate.execute(snis_set)
    kong_global.reset_log(kong)
  end

  mtls_cache.init_worker()
end


return MtlsAuthHandler
