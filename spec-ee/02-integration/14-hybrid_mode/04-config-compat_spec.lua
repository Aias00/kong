-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local helpers = require "spec.helpers"
local utils = require "kong.tools.utils"
local cjson = require "cjson"
local STATUS = require("kong.constants").CLUSTERING_SYNC_STATUS
local FIELDS = require("kong.clustering.compat.removed_fields")
local CHECKERS = require("kong.clustering.compat.checkers")
local version = require("kong.clustering.compat.version")
local tablex = require "pl.tablex"

local admin = require "spec.fixtures.admin_api"

local fmt = string.format
local version_num = version.string_to_number

local CP_HOST = "127.0.0.1"
local CP_PORT = 9005

local PLUGIN_LIST

local EMPTY = {}


local function cluster_client(opts)
  opts = opts or {}

  local _, res = pcall(helpers.clustering_client, {
    host = CP_HOST,
    port = CP_PORT,
    cert = "spec/fixtures/kong_clustering.crt",
    cert_key = "spec/fixtures/kong_clustering.key",
    node_hostname = opts.hostname or "test",
    node_id = opts.id or utils.uuid(),
    node_version = opts.version,
    node_plugins_list = PLUGIN_LIST,
  })

  return res
end

local function get_sync_status(id)
  local status
  local admin_client = helpers.admin_client()

  helpers.wait_until(function()
    local res = admin_client:get("/clustering/data-planes")
    local body = assert.res_status(200, res)

    local json = cjson.decode(body)

    for _, v in pairs(json.data) do
      if v.id == id then
        status = v.sync_status
        return true
      end
    end
  end, 5, 0.5)

  admin_client:close()

  return status
end


local function get_plugin(node_id, node_version, name)
  local res = cluster_client({ id = node_id, version = node_version })

  local plugin
  if ((res or EMPTY).config_table or EMPTY).plugins then
    for _, p in ipairs(res.config_table.plugins) do
      if p.name == name then
        plugin = p.config
        break
      end
    end
    assert.not_nil(plugin, "plugin " .. name .. " not found in config")
  end

  return plugin, get_sync_status(node_id)
end


local function get(t, field)
  local parts = utils.split(field, ".")
  local ref = t

  for i = 1, #parts do
    if type(ref) ~= "table" then
      return
    end

    ref = ref[parts[i]]
  end

  return ref
end


for _, strategy in helpers.each_strategy() do

describe("CP/DP config compat #" .. strategy, function()
  local db

  local function do_assert(case, dp_version)
    assert(db:truncate("plugins"))
    assert(db:truncate("clustering_data_planes"))

    local plugin = admin.plugins:insert({
      name = case.plugin,
      config = case.config,
    })

    local id = utils.uuid()

    local conf, status
    helpers.wait_until(function()
      conf, status = get_plugin(id, dp_version, case.plugin)
      return status == case.status
    end, 5, 0.25)

    assert.equals(case.status, status)

    if case.status == STATUS.NORMAL then
      for _, chkrs in pairs(case.checker or EMPTY) do
        local ver = chkrs[1]
        local fn = chkrs[2]
        if ver == version_num(dp_version) then
          local plugins_table = { plugins = {{ config = conf, name = plugin.name }}}
          fn(plugins_table, dp_version, "")
        end
      end
      for _, field in ipairs(case.removed or {}) do
        assert.not_nil(get(plugin.config, field),
                        "field '" .. field .. "' is missing from the " ..
                        "configured plugin")

        assert.is_nil(get(conf, field),
                      "field '" .. field .. "' was not removed from the " ..
                      "data plane copy of the plugin config")
      end
    else
      assert.is_nil(conf, "expected config sync to fail")
    end

    if case.validator then
      assert(case.validator(conf), "unexpected config received")
    end
  end

  lazy_setup(function()
    local bp
    bp, db = helpers.get_db_utils(strategy, {
      "routes",
      "services",
      "plugins",
      "clustering_data_planes",
    }, {'graphql-rate-limiting-advanced', 'rate-limiting-advanced', 'openid-connect'})

    PLUGIN_LIST = helpers.get_plugins_list()

    bp.routes:insert {
      name = "compat.test",
      hosts = { "compat.test" },
      service = bp.services:insert {
        name = "compat.test",
      }
    }

    assert(helpers.start_kong({
      role = "control_plane",
      cluster_cert = "spec/fixtures/kong_clustering.crt",
      cluster_cert_key = "spec/fixtures/kong_clustering.key",
      database = strategy,
      db_update_frequency = 0.1,
      cluster_listen = CP_HOST .. ":" .. CP_PORT,
      nginx_conf = "spec/fixtures/custom_nginx.template",
      plugins = "bundled,graphql-rate-limiting-advanced,rate-limiting-advanced,openid-connect",
    }))
  end)

  lazy_teardown(function()
    helpers.stop_kong(nil, true)
  end)

  describe("3.4.x.y", function()
    local CASES = {
      {
        plugin = "opentelemetry",
        label = "w/ header_type datadog unsupported",
        pending = false,
        config = {
          endpoint = "http://1.1.1.1:12345/v1/trace",
          header_type = "datadog"
        },
        status = STATUS.NORMAL,
        validator = function(config)
          return config.header_type == 'preserve'
        end
      }
    }

    for _, case in ipairs(CASES) do
      local test = case.pending and pending or it

      test(fmt("%s - %s", case.plugin, case.label), function()
        do_assert(case, "3.4.0.0")
      end)
    end
  end)

  describe("3.5.x.y", function()
    local CASES = {
      {
        plugin = "acl",
        label = "w/ include_consumer_groups is unsupported",
        pending = false,
        config = {
          include_consumer_groups = true,
          allow = {"foo"}
        },
        status = STATUS.NORMAL,
        removed = FIELDS[3006000000].acl,
        validator = function(config)
          return config.include_consumer_groups == nil
        end
      }
    }

    for _, case in ipairs(CASES) do
      local test = case.pending and pending or it

      test(fmt("%s - %s", case.plugin, case.label), function()
        do_assert(case, "3.5.0.0")
      end)
    end
  end)

  describe("3.6.x.y", function()
    local CASES = {
      {
        plugin = "rate-limiting-advanced",
        label = "w/ identifier consumer-group unsupported",
        pending = false,
        config = {
          limit = {1},
          window_size = {2},
          identifier = "consumer-group",
        },
        status = STATUS.NORMAL,
        checker = CHECKERS,
        validator = function(config)
          return config.identifier == 'consumer'
        end
      },
      {
        plugin = "rate-limiting",
        label = "w/ limit_by consumer-group unsupported",
        pending = false,
        config = {
          second = 1,
          limit_by = "consumer-group"
        },
        status = STATUS.NORMAL,
        checker = CHECKERS,
        validator = function(config)
          return config.limit_by == 'consumer'
        end
      },
      {
        plugin = "openid-connect",
        label = "w/ unsupported client auth methods",
        pending = false,
        config = {
          issuer = "https://test.test",
          client_auth = {
            "client_secret_post",
            "client_secret_basic",
            "tls_client_auth",
            "self_signed_tls_client_auth"
          },
          tls_client_auth_cert_id            = "821a7065-ebce-43a2-adb6-2dcb1a3d6ef9",
          token_endpoint_auth_method         = "tls_client_auth",
          introspection_endpoint_auth_method = "self_signed_tls_client_auth",
          revocation_endpoint_auth_method    = "self_signed_tls_client_auth"
        },
        status = STATUS.NORMAL,
        checker = CHECKERS,
        validator = function(config)
          return tablex.compare({ "client_secret_post", "client_secret_basic" }, config.client_auth, "==") and
          config.token_endpoint_auth_method         == nil and
          config.introspection_endpoint_auth_method == nil and
          config.revocation_endpoint_auth_method    == nil
        end
      }
    }

    for _, case in ipairs(CASES) do
      local test = case.pending and pending or it

      test(fmt("%s - %s", case.plugin, case.label), function()
        do_assert(case, "3.6.0.0")
      end)
    end
  end)
end)

end -- each strategy
