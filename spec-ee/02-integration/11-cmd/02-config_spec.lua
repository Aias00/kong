-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local helpers = require "spec.helpers"

describe("kong config", function()

  lazy_setup(function()
    helpers.get_db_utils(nil, {}) -- runs migrations
  end)
  after_each(function()
    helpers.kill_all()
  end)
  lazy_teardown(function()
    helpers.clean_prefix()
  end)

  it("#db config imports a yaml with custom workspace", function()
    local filename = helpers.make_yaml_file([[
      _format_version: "1.1"
      _workspace: foo
    ]])

    assert(helpers.kong_exec("config db_import " .. filename, {
      prefix = helpers.test_conf.prefix,
    }))

    end)
end)
