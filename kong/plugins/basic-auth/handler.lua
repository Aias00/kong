-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

-- Copyright (C) Kong Inc.
local access = require "kong.plugins.basic-auth.access"


local BasicAuthHandler = {}


function BasicAuthHandler:access(conf, exit_handler)
  ---EE [[
  return access.execute(conf, exit_handler)
  --]] EE
end


BasicAuthHandler.PRIORITY = 1001
BasicAuthHandler.VERSION = "2.1.0"


return BasicAuthHandler
