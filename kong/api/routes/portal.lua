local crud        = require "kong.api.crud_helpers"
local singletons  = require "kong.singletons"
local enums       = require "kong.enterprise_edition.dao.enums"
local utils       = require "kong.portal.utils"
local cjson       = require "cjson"


--- Allowed auth plugins
-- Table containing allowed auth plugins that the developer portal api
-- can create credentials for.
--
--["<route>"]:     {  name = "<name>",    dao = "<dao_collection>" }
local auth_plugins = {
  ["basic-auth"] = { name = "basic-auth", dao = "basicauth_credentials", },
  ["acls"] =       { name = "acl",        dao = "acls" },
  ["oauth2"] =     { name = "oauth2",     dao = "oauth2_credentials" },
  ["hmac-auth"] =  { name = "hmac-auth",  dao = "hmacauth_credentials" },
  ["jwt"] =        { name = "jwt",        dao = "jwt_secrets" },
  ["key-auth"] =   { name = "key-auth",   dao = "keyauth_credentials" },
}


-- Disable API when Developer Portal is not enabled
if not singletons.configuration.portal then
  return {}
end


return {
  ["/files"] = {
    -- List all files stored in the portal file system
    GET = function(self, dao_factory, helpers)
      crud.paginated_set(self, dao_factory.portal_files)
    end,

    -- Create or Update a file in the portal file system
    POST = function(self, dao_factory, helpers)
      crud.post(self.params, dao_factory.portal_files)
    end
  },

  ["/files/*"] = {
    -- Process request prior to handling the method
    before = function(self, dao_factory, helpers)
      local dao = dao_factory.portal_files
      local identifier = self.params.splat

      -- Find a file by id or field "name"
      local rows, err = crud.find_by_id_or_field(dao, {}, identifier, "name")
      if err then
        return helpers.yield_error(err)
      end

      -- Since we know both the name and id of portal_files are unique
      self.params.splat = nil
      self.portal_file = rows[1]
      if not self.portal_file then
        return helpers.responses.send_HTTP_NOT_FOUND(
          "No file found by name or id '" .. identifier .. "'"
        )
      end
    end,

    -- Retrieve an individual file from the portal file system
    GET = function(self, dao_factory, helpers)
      return helpers.responses.send_HTTP_OK(self.portal_file)
    end,

    PATCH = function(self, dao_factory)
      crud.patch(self.params, dao_factory.portal_files, self.portal_file)
    end,

    -- Delete a file in the portal file system that has
    -- been created outside of migrations
    DELETE = function(self, dao_factory, helpers)
      crud.delete(self.portal_file, dao_factory.portal_files)
    end
  },

  ["/portal/developers"] = {
    before = function(self, dao_factory)
      self.params.type = enums.CONSUMERS.TYPE.DEVELOPER
      self.params.status = tonumber(self.params.status)
    end,

    GET = function(self, dao_factory)
      crud.paginated_set(self, dao_factory.consumers)
    end,

    PATCH = function(self, dao_factory)
      crud.patch(self.params, dao_factory.consumers)
    end,

    POST = function(self, dao_factory)
      crud.post(self.params, dao_factory.consumers)
    end
  },

  ["/portal/developers/:email_or_id"] = {
    before = function(self, dao_factory, helpers)
      self.params.email_or_id = ngx.unescape_uri(self.params.email_or_id)
      self.params.status = tonumber(self.params.status)
      crud.find_consumer_by_email_or_id(self, dao_factory, helpers)
    end,

    GET = function(self, dao_factory, helpers)
      return helpers.responses.send_HTTP_OK(self.consumer)
    end,

    PATCH = function(self, dao_factory)
      crud.patch(self.params, dao_factory.consumers, self.consumer)
    end,

    DELETE = function(self, dao_factory)
      crud.delete(self.consumer, dao_factory.consumers)
    end
  },

  ["/portal/developers/:email_or_id/password"] = {
    before = function(self, dao_factory, helpers)
      -- auth required
      if not singletons.configuration.portal_auth then
        return helpers.responses.send_HTTP_NOT_FOUND()
      end

      self.params.email_or_id = ngx.unescape_uri(self.params.email_or_id)
      crud.find_consumer_by_email_or_id(self, dao_factory, helpers)

      self.portal_auth = singletons.configuration.portal_auth

      local plugin = auth_plugins[self.portal_auth]
      if not plugin then
        return helpers.responses.send_HTTP_NOT_FOUND()
      end

      self.collection = dao_factory[plugin.dao]

      local credentials, err = dao_factory.credentials:find_all({
        consumer_id = self.consumer.id,
        consumer_type = enums.CONSUMERS.TYPE.DEVELOPER,
        plugin = self.portal_auth,
      })

      if err then
        return helpers.yield_error(err)
      end

      if next(credentials) == nil then
        return helpers.responses.send_HTTP_NOT_FOUND()
      end

      self.credential = credentials[1]
    end,

    PATCH = function(self, dao_factory, helpers)
      if not self.params.password then
        return helpers.responses.send_HTTP_BAD_REQUEST("Password is required")
      end

      local cred_params = {
        password = self.params.password,
      }

      self.params.password = nil

      local filter = {
        consumer_id = self.consumer.id,
        id = self.credential.id,
      }

      local ok, err = crud.portal_crud.update_login_credential(cred_params, self.collection, filter)

      if err then
        return helpers.yield_error(err)
      end

      if not ok then
        return helpers.responses.send_HTTP_NOT_FOUND()
      end

      return helpers.responses.send_HTTP_NO_CONTENT()
    end,
  },

  ["/portal/developers/:email_or_id/email"] = {
    before = function(self, dao_factory, helpers)
      -- auth required
      if not singletons.configuration.portal_auth then
        return helpers.responses.send_HTTP_NOT_FOUND()
      end

      self.params.email_or_id = ngx.unescape_uri(self.params.email_or_id)
      crud.find_consumer_by_email_or_id(self, dao_factory, helpers)

      self.portal_auth = singletons.configuration.portal_auth

      local plugin = auth_plugins[self.portal_auth]
      if not plugin then
        return helpers.responses.send_HTTP_NOT_FOUND()
      end

      self.collection = dao_factory[plugin.dao]

      local credentials, err = dao_factory.credentials:find_all({
        consumer_id = self.consumer.id,
        consumer_type = enums.CONSUMERS.TYPE.DEVELOPER,
        plugin = self.portal_auth,
      })

      if err then
        return helpers.yield_error(err)
      end

      if next(credentials) == nil then
        return helpers.responses.send_HTTP_NOT_FOUND()
      end

      self.credential = credentials[1]
    end,

    PATCH = function(self, dao_factory, helpers)
      if utils.validate_email(self.params.email) == nil then
        return helpers.responses.send_HTTP_BAD_REQUEST("Invalid email")
      end

      local cred_params = {
        username = self.params.email,
      }

      local filter = {
        consumer_id = self.consumer.id,
        id = self.credential.id,
      }

      local ok, err = crud.portal_crud.update_login_credential(cred_params, self.collection, filter)

      if err then
        return helpers.yield_error(err)
      end

      if not ok then
        return helpers.responses.send_HTTP_NOT_FOUND()
      end

      local dev_params = {
        username = self.params.email,
        email = self.params.email,
      }

      local ok, err = singletons.dao.consumers:update(dev_params, {
        id = self.consumer.id,
      })

      if err then
        return helpers.yield_error(err)
      end

      if not ok then
        return helpers.responses.send_HTTP_NOT_FOUND()
      end

      return helpers.responses.send_HTTP_NO_CONTENT()
    end,
  },

  ["/portal/developers/:email_or_id/meta"] = {
    before = function(self, dao_factory, helpers)
      -- auth required
      if not singletons.configuration.portal_auth then
        return helpers.responses.send_HTTP_NOT_FOUND()
      end

      self.params.email_or_id = ngx.unescape_uri(self.params.email_or_id)

      crud.find_consumer_by_email_or_id(self, dao_factory, helpers)
    end,

    PATCH = function(self, dao_factory, helpers)
      local meta_params = self.params.meta and cjson.decode(self.params.meta)

      if not meta_params then
        return helpers.responses.send_HTTP_BAD_REQUEST("meta required")
      end

      local current_dev_meta = self.consumer.meta and cjson.decode(self.consumer.meta)

      if not current_dev_meta then
        return helpers.responses.send_HTTP_NOT_FOUND()
      end

      -- Iterate over meta update params and assign them to current meta
      for k, v in pairs(meta_params) do
        -- Only assign values that are already in the current meta
        if current_dev_meta[k] then
          current_dev_meta[k] = v
        end
      end

      -- Encode full meta (current and new) and assign it to update params
      local dev_params = {
        meta = cjson.encode(current_dev_meta),
      }

      local ok, err = singletons.dao.consumers:update(dev_params, {
        id = self.consumer.id,
      })

      if err then
        return helpers.yield_error(err)
      end

      if not ok then
        return helpers.responses.send_HTTP_NOT_FOUND()
      end

      return helpers.responses.send_HTTP_NO_CONTENT()
    end,
  },
}
