-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local constants    = require "kong.constants"
local openssl_x509 = require "resty.openssl.x509"
local chain_lib    = require "resty.openssl.x509.chain"

local _M = {}

local kong = kong
local null = ngx.null
local ipairs = ipairs
local new_tab = require("table.new")

local TTL_FOREVER = { ttl = 0 }

local ca_cert_cache_opts = {
  l1_serializer = function(ca)
    local x509, err = openssl_x509.new(ca.cert, "PEM")
    if err then
      return nil, err
    end

    return x509
  end
}


-- make the table out side of function to reuse table
local key = new_tab(1, 0)

local function load_ca(ca_id)
  kong.log.debug("cache miss for CA Cert")

  key.id = ca_id
  local ca, err = kong.db.ca_certificates:select(key)
  if not ca then
    if err then
      return nil, err
    end

    return nil, "CA Certificate '" .. tostring(ca_id) .. "' does not exist"
  end

  return ca
end

local function merge_ca_ids(sni, ca_ids)
  sni.ca_ids = sni.ca_ids or {}
  local sni_ca_ids = sni.ca_ids

  for _, ca_id in ipairs(ca_ids) do
    if not sni_ca_ids[ca_id] then
      sni_ca_ids[ca_id] = true
    end
  end
end

local function ca_cert_cache_key(ca_id)
  return "mtls:cacert:" .. ca_id
end

local function load_routes_from_db(db, route_id, options)
  kong.log.debug("cache miss for route id: " .. route_id.id)
  local routes, err = db.routes:select(route_id, options)
  if routes == nil then
    -- the third value means "do not cache"
    return nil, err, -1
  end

  return routes
end


local function build_snis_for_route(route, snis, send_ca_dn, ca_ids)
  -- every route should have SNI or ask cert on all requests
  if not route.snis or #route.snis == 0 then
    snis["*"] = snis["*"] or {}

    if send_ca_dn then
      merge_ca_ids(snis["*"], ca_ids)
    end

  else
    for _, sni in ipairs(route.snis) do
      snis[sni] = snis[sni] or {}

      if send_ca_dn then
        merge_ca_ids(snis[sni], ca_ids)
      end
    end
  end
end


local function get_snis_for_plugin(db, plugin, snis, options)
  -- plugin applied on service
  local service_pk = plugin.service
  local send_ca_dn = plugin.config.send_ca_dn
  local ca_ids = plugin.config.ca_certificates

  if service_pk then
    for route, err in db.routes:each_for_service(service_pk, nil, options) do
      if err then
        return err
      end

      -- XXX: strictly speaking, if a mtls plugin is also applied on the route,
      -- then we should skip the plugin applied on the corresponding service,
      -- as the plugin on route has a higher priority.
      -- But this requires a plugin iteration on every route.
      -- For performance considerations, we choose to continue.
      -- Sending a few more ca dn is not a big deal, since we are already doing
      -- this by merging the ca dn of mtls plugins with the same sni.
      -- After all, sending some extra ca dn is better than sending nothing.
      build_snis_for_route(route, snis, send_ca_dn, ca_ids)
    end

    return
  end

  -- plugin applied on route
  local route_pk = plugin.route
  if route_pk then
    local cache_key = db.routes:cache_key(route_pk.id)
    local cache_obj = kong[constants.ENTITY_CACHE_STORE.routes]
    local route, err = cache_obj:get(cache_key, TTL_FOREVER,
                                      load_routes_from_db, db,
                                      route_pk, options)

    if err then
      return err
    end

    build_snis_for_route(route, snis, send_ca_dn, ca_ids)

    return
  end

  -- plugin applied on global scope
  snis["*"] = snis["*"] or {}
  if send_ca_dn then
    merge_ca_ids(snis["*"], ca_ids)
  end
end

-- build ca_cert_chain from ca_ids
local function build_ca_cert_chain(ca_ids)
  local chain, err = chain_lib.new()
  if err then
    return nil, err
  end

  for ca_id, _ in pairs(ca_ids) do
    local x509, err = kong.cache:get(ca_cert_cache_key(ca_id), ca_cert_cache_opts,
                                   load_ca, ca_id)
    if err then
      return nil, err
    end

    local _
    _, err = chain:add(x509)

    if err then
      return nil, err
    end
  end

  return chain
end

-- build ca_cert_chain for every sni
function _M.sni_cache_l1_serializer(snis)
  for sni, v in pairs(snis) do
    if v.ca_ids then
      local chain, err = build_ca_cert_chain(v.ca_ids)

      if err then
        return nil, err
      end

      v.ca_cert_chain = chain
    end
  end

  return snis
end

local function each_enabled_plugin(entity, plugin_name)
  local options = {
    -- show_ws_id = true,
    workspace = null,
    search_fields = {
      name = plugin_name,
      enabled = true
    }
  }

  local iter = entity:each(1000, options)
  local function iterator()
    local element, err = iter()
    if err then return nil, err end
    if element == nil then return end
    -- XXX
    -- `search_fields` is PostgreSQL-backed instances only.
    -- We also need a backstop here for Cassandra or DBless.
    if element.name == plugin_name and element.enabled then return element, nil end
    return iterator()
  end

  return iterator
end

function _M.build_ssl_route_filter_set(plugin_name)
  kong.log.debug("building ssl route filter set for plugin name " .. plugin_name)
  local db = kong.db
  local snis = {}

  local options = { workspace = null }
  for plugin, err in each_enabled_plugin(db.plugins, plugin_name) do
    if err then
      return nil, "could not load plugins: " .. err
    end

    local err = get_snis_for_plugin(db, plugin, snis, options)
    if err then
      return nil, err
    end
  end

  return snis
end


return _M
