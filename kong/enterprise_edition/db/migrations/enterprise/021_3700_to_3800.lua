-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local fmt = string.format

local WS_ROLES = {
  default = { workspace = "*", roles = { "admin" } },
  non_default = { workspace = nil, roles = { "workspace-admin", "workspace-portal-admin" } }
}

local GROUPS_ENDPOINTS = {
  {
    endpoint = "/groups",
    actions = 15,
    negative = true,
  },
  {
    endpoint = "/groups/*",
    actions = 15,
    negative = true,
  },
}

local function is_not_exist_endpoint(connector, role_id, workspace, endpoint)
  local rbac_role_endpoint = assert(connector:query(fmt(
    "SELECT * FROM rbac_role_endpoints WHERE role_id='%s' and workspace='%s' and endpoint='%s'",
    role_id, workspace, endpoint)))
  return not rbac_role_endpoint[1]
end

local function add_rbac_role_endpoints(connector, workspace, role_id)
  for _, endpoint in ipairs(GROUPS_ENDPOINTS) do
    if is_not_exist_endpoint(connector, role_id, workspace, endpoint.endpoint) then
      assert(connector:query(fmt(
        "INSERT INTO rbac_role_endpoints(role_id, workspace, endpoint, actions, negative) VALUES ('%s', '%s', '%s', %d, %s);",
        role_id, workspace, endpoint.endpoint, endpoint.actions, tostring(endpoint.negative))))
    end
  end
end

return {
  postgres = {
    up = [[
      DO $$
        BEGIN
          ALTER TABLE IF EXISTS ONLY "login_attempts" ADD COLUMN "attempt_type" TEXT DEFAULT 'login';
          ALTER TABLE login_attempts DROP CONSTRAINT login_attempts_pkey;
          ALTER TABLE login_attempts ADD PRIMARY KEY(consumer_id, attempt_type);
        EXCEPTION WHEN UNDEFINED_COLUMN OR DUPLICATE_COLUMN THEN
          -- do nothing, accept existing state
      END$$;
    ]],
    teardown = function(connector)
      -- retrieve all workspace
      local workspaces = assert(connector:query("SELECT * FROM workspaces;"))
      for _, workspace in ipairs(workspaces) do
        local ws_role = WS_ROLES[workspace.name == "default" and "default" or "non_default"]

        for _, role in pairs(ws_role.roles) do
          -- retrieve the role of the workspace
          local admin_role = assert(connector:query(fmt("SELECT * FROM rbac_roles WHERE name='%s' and ws_id='%s';",
            role, workspace.id)))
          -- insert the endpoints of the role.
          if admin_role[1] then
            add_rbac_role_endpoints(connector, ws_role.workspace or workspace.name, admin_role[1].id)
          end
        end
      end
    end,
  }
}
