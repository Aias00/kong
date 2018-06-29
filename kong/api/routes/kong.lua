local utils = require "kong.tools.utils"
local singletons = require "kong.singletons"
local public = require "kong.tools.public"
local conf_loader = require "kong.conf_loader"
local cjson = require "cjson"
local ee_api = require "kong.enterprise_edition.api_helpers"
local crud = require "kong.api.crud_helpers"

local sub = string.sub
local find = string.find
local ipairs = ipairs
local select = select
local tonumber = tonumber

local tagline = "Welcome to " .. _KONG._NAME
local version = _KONG._VERSION
local lua_version = jit and jit.version or _VERSION

return {
  ["/"] = {
    GET = function(self, dao, helpers)
      local distinct_plugins = setmetatable({}, cjson.empty_array_mt)
      local prng_seeds = {}

      do
        local rows, err = dao.plugins:find_all()
        if err then
          return helpers.responses.send_HTTP_INTERNAL_SERVER_ERROR(err)
        end

        local map = {}
        for _, row in ipairs(rows) do
          if not map[row.name] then
            distinct_plugins[#distinct_plugins+1] = row.name
          end
          map[row.name] = true
        end

        singletons.internal_proxies:add_internal_plugins(distinct_plugins, map)
      end

      do
        local kong_shm = ngx.shared.kong
        local shm_prefix = "pid: "
        local keys, err = kong_shm:get_keys()
        if not keys then
          ngx.log(ngx.ERR, "could not get kong shm keys: ", err)
        else
          for i = 1, #keys do
            if sub(keys[i], 1, #shm_prefix) == shm_prefix then
              prng_seeds[keys[i]], err = kong_shm:get(keys[i])
              if err then
                ngx.log(ngx.ERR, "could not get PRNG seed from kong shm")
              end
            end
          end
        end
      end

      local license
      if singletons.license then
        license = utils.deep_copy(singletons.license).license.payload
        license.license_key = nil
      end

      local node_id, err = public.get_node_id()
      if node_id == nil then
        ngx.log(ngx.ERR, "could not get node id: ", err)
      end

      return helpers.responses.send_HTTP_OK {
        tagline = tagline,
        version = version,
        hostname = utils.get_hostname(),
        node_id = node_id,
        timers = {
          running = ngx.timer.running_count(),
          pending = ngx.timer.pending_count()
        },
        plugins = {
          available_on_server = singletons.configuration.plugins,
          enabled_in_cluster = distinct_plugins
        },
        lua_version = lua_version,
        configuration = conf_loader.remove_sensitive(singletons.configuration),
        prng_seeds = prng_seeds,
        license = license,
      }
    end
  },
  ["/status"] = {
    GET = function(self, dao, helpers)
      local r = ngx.location.capture "/nginx_status"
      if r.status ~= 200 then
        return helpers.responses.send_HTTP_INTERNAL_SERVER_ERROR(r.body)
      end

      local var = ngx.var
      local accepted, handled, total = select(3, find(r.body, "accepts handled requests\n (%d*) (%d*) (%d*)"))

      local status_response = {
        server = {
          connections_active = tonumber(var.connections_active),
          connections_reading = tonumber(var.connections_reading),
          connections_writing = tonumber(var.connections_writing),
          connections_waiting = tonumber(var.connections_waiting),
          connections_accepted = tonumber(accepted),
          connections_handled = tonumber(handled),
          total_requests = tonumber(total)
        },
        database = {
          reachable = false,
        },
      }

      local ok, err = dao.db:reachable()
      if not ok then
        ngx.log(ngx.ERR, "failed to reach database as part of ",
                         "/status endpoint: ", err)

      else
        status_response.database.reachable = true
      end

      return helpers.responses.send_HTTP_OK(status_response)
    end
  },

  --- Retrieves current consumer and/or RBAC user
  -- This route is whitelisted from RBAC validation. It requires that a consumer
  -- is set on the headers, but should only work for a consumer that is set
  -- when an authentication plugin has set the consumer-id header.
  -- See for reference: kong.rbac.authorize_request_endpoint()
  ["/userinfo"] = {
    before = function(self, dao_factory, helpers)
      self.params.username_or_id = ee_api.get_consumer_id_from_headers()

      local admin_auth = singletons.configuration.admin_gui_auth

      if admin_auth and not self.params.username_or_id then
        return helpers.responses.send_HTTP_UNAUTHORIZED()
      end

      if not admin_auth then
        return helpers.responses.send_HTTP_NOT_FOUND()
      end

      crud.find_consumer_by_username_or_id(self, dao_factory, helpers)

      local rbac = singletons.configuration.rbac
      if rbac == "on" or rbac == "both" then
        local user_consumer = dao_factory.consumers_rbac_users_map:find_all({
          consumer_id = self.consumer.id,
        })

        if user_consumer and user_consumer[1].user_id then
          self.params.name_or_id = user_consumer[1].user_id
          crud.find_rbac_user_by_name_or_id(self, dao_factory, helpers)

          if not self.rbac_user then
            return helpers.responses.send_HTTP_UNAUTHORIZED('user not found')
          end
        end
      end
    end,

    GET = function(self, dao_factory, helpers)
      return helpers.responses.send_HTTP_OK({
        rbac_user = self.rbac_user,
        consumer = self.consumer,
      })
    end,
  },
}
