local helpers = require "spec.helpers"
local singletons = require "kong.singletons"
local enums = require "kong.enterprise_edition.dao.enums"


for _, strategy in helpers.each_strategy() do
  local db, dao, admins, _

  local function truncate_tables()
    db:truncate("consumers")
    db:truncate("rbac_user_roles")
    db:truncate("rbac_roles")
    db:truncate("rbac_users")
    db:truncate("admins")
  end

  describe("admins dao with #" .. strategy, function()

    lazy_setup(function()
      _, db, dao = helpers.get_db_utils(strategy)

      singletons.db = db
      singletons.dao = dao
      admins = db.admins

      -- consumers are workspaceable, so we need a workspace context
      -- TODO: do admins need to be workspaceable? Preferably not.
      local default_ws = assert(db.workspaces:select_by_name("default"))
      ngx.ctx.workspace = default_ws.id
    end)

    lazy_teardown(function()
      truncate_tables()
      ngx.shared.kong_cassandra:flush_expired()
    end)

    describe("insert()", function()
      local snapshot

      before_each(function()
        truncate_tables()
        snapshot = assert:snapshot()
      end)

      after_each(function()
        snapshot:revert()
      end)

      it("inserts a valid admin", function()
        local admin_params = {
          username = "admin-1",
          custom_id = "admin-1-custom-id",
          email = "admin-1@konghq.com",
          status = enums.CONSUMERS.STATUS.APPROVED,
        }

        local admin, err = admins:insert(admin_params)
        assert.is_nil(err)
        assert.is_table(admin)
        assert.same(admin_params.email, admin.email)
        assert.same(admin_params.status, admin.status)
        assert.not_nil(admin.consumer)
        assert.not_nil(admin.rbac_user)
      end)

      it("defaults to INVITED", function()
        local admin_params = {
          username = "admin-1",
          custom_id = "admin-1-custom-id",
          email = "admin-1@konghq.com",
        }

        local admin, err = admins:insert(admin_params)
        assert.is_nil(err)
        assert.is_table(admin)
        assert.same(enums.CONSUMERS.STATUS.INVITED, admin.status)
      end)

      it("sets consumer username and custom_id same as admin's", function()
        local admin_params = {
          username = "admin-2",
          custom_id = "admin-2-custom-id",
          email = "admin-2@konghq.com",
          status = enums.CONSUMERS.STATUS.APPROVED,
        }

        local admin, err = admins:insert(admin_params)
        assert.is_nil(err)
        assert.same(admin.username, admin.consumer.username)
        assert.same(admin.custom_id, admin.consumer.custom_id)
      end)

      it("generates unique rbac_user.name", function()
        -- we aren't keeping this in sync with admin name, so it needs
        -- to be unique. That way if you create an admin 'kinman' and change
        -- the name to 'karen' and back to 'kinman' you don't get a warning
        -- that 'kinman' already exists.
        local admin_params = {
          username = "admin-1",
          email = "admin-1@konghq.com",
          status = enums.CONSUMERS.STATUS.APPROVED,
        }

        local admin, err = admins:insert(admin_params)
        assert.is_nil(err)
        assert.same(admin.username, admin.consumer.username)
        assert.not_same(admin.username, admin.rbac_user.name)
      end)

      it("validates user input - invalid fields", function()
        -- "user" is not a valid field
        local admin_params = {
          user = "admin-1",
          username = "admin-user",
          email = "admin-1@konghq.com",
          status = enums.CONSUMERS.STATUS.APPROVED,
        }

        local _, err, err_t = admins:insert(admin_params)
        local expected_t = {
          code = 2,
          fields = {
            user = "unknown field"
          },
          message = "schema violation (user: unknown field)",
          name = "schema violation",
          strategy = strategy,
        }
        assert.same(expected_t, err_t)

        local expected_m = "[" .. strategy .. "] schema violation (user: unknown field)"
        assert.same(expected_m, err)
      end)

      it("validates user input - username is required", function()
        local admin_params = {
          custom_id = "admin-no-username",
          email = "admin-no-username@konghq.com",
          status = enums.CONSUMERS.STATUS.APPROVED,
        }

        local _, err, err_t = admins:insert(admin_params)
        local expected_t = {
          code = 2,
          fields = {
            username = "required field missing",
          },
          message = "schema violation (username: required field missing)",
          name = "schema violation",
          strategy = strategy,
        }
        assert.same(expected_t, err_t)

        assert.same("[" .. strategy .. "] schema violation (username: required field missing)", err)
      end)

      it("rolls back the rbac_user if we can't create the consumer", function()
        stub(db.consumers, "insert").returns(nil, "failed!")

        local admin_params = {
          username = "admin-1",
          custom_id = "admin-1-custom-id",
          email = "admin-1@konghq.com",
          status = enums.CONSUMERS.STATUS.APPROVED,
        }

        local _, err = admins:insert(admin_params)
        assert.same(err, "failed!")

        -- leave no trace
        assert.same(nil, kong.db.consumers:select_by_username("gruce"))
        assert.same(nil, kong.db.rbac_users:select_by_name("gruce"))
      end)

      it("rolls back the rbac_user and consumer if we can't create the admin", function()
        stub(db.admins, "insert").returns(nil, "failed!")

        local admin_params = {
          username = "admin-1",
          custom_id = "admin-1-custom-id",
          email = "admin-1@konghq.com",
          status = enums.CONSUMERS.STATUS.APPROVED,
        }

        local _, err = admins:insert(admin_params)
        assert.same(err, "failed!")

        -- leave no trace
        assert.same(nil, kong.db.consumers:select_by_username("gruce"))
        assert.same(nil, kong.db.rbac_users:select_by_name("gruce"))
      end)
    end)
  end)
end
