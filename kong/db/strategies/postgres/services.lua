local workspaces = require "kong.workspaces"
local rbac       = require "kong.rbac"


local fmt = string.format


local _Services_ee = {}


local function validate_access(self, table_name, service_id, constraints)
  local select_q = fmt("SELECT * FROM %s WHERE service_id = '%s'",
                       table_name, service_id)
  local res   = {}
  local count = 0

  for row, err in self.connector:iterate(select_q) do
    if err then
      return nil,
      self.errors:database_error(
        fmt("could not fetch %s for Service: %s", table_name, err))
    end

    if not rbac.validate_entity_operation(row, constraints) then
      -- todo return correct error
      return nil, self.errors:unauthorized_operation("cascading delete")
    end

    count = count + 1
    res[count] = row
  end

  return res
end


local function delete_cascade_ws(entities, table_name, errors, ws)
  if not ws then
    return
  end

  for i = 1, #entities do
    local err = workspaces.delete_entity_relation(table_name, entities[i])
    if err then
      return nil, errors:database_error("could not delete " .. table_name ..
        " relationship with Workspace: " .. err)
    end
  end

  return true
end


function _Services_ee:delete(primary_key)
  local ws          = workspaces.get_workspaces()[1]
  local constraints = workspaces.get_workspaceable_relations()[self.schema.name]
  local service_id  = primary_key.id
  local errors      = self.errors

  -- fetch all child entities
  local plugin_list, err1 = validate_access(self, "plugins", service_id, constraints)
  local oauth2_tokens_list, err2 = validate_access(self, "oauth2_tokens", service_id, constraints)
  local oauth2_codes_list, err3 = validate_access(self, "oauth2_authorization_codes", service_id, constraints)
  if err1 or err2 or err3 then
    return nil, err1 or err2 or err3
  end

  if not rbac.validate_entity_operation(primary_key, constraints) then
    -- todo return correct error
    return nil, self.errors:unauthorized_operation("delete")
  end

  -- delete parent, also deletes child entities
  local ok, err_t = self.super.delete(self, primary_key)
  if not ok then
    return nil, err_t
  end

  -- delete child workspace relationship
  local ok1, err1 = delete_cascade_ws(plugin_list, "plugins", errors, ws)
  local ok2, err2 = delete_cascade_ws(oauth2_tokens_list, "oauth2_tokens", errors, ws)
  local ok3, err3 = delete_cascade_ws(oauth2_codes_list, "oauth2_authorization_codes", errors, ws)

  if err1 or err2 or err3 then
    return false, err1 or err2 or err3
  end

  -- delete workspace relationship
  if ok and ws then
    local err = workspaces.delete_entity_relation("services", primary_key)
    if err then
      return nil, self.errors:database_error("could not delete Route relationship " ..
                                             "with Workspace: " .. err)
    end
  end

  return true
end


return _Services_ee
