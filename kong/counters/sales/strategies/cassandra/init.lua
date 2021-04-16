-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local cassandra = require "cassandra"
local split     = require "kong.tools.utils".split


local log = ngx.log
local ERR = ngx.ERR


local UPDATE_STATEMENT = [[
    UPDATE license_data SET
      req_cnt = req_cnt + ?
    WHERE
      node_id = ? AND
      license_creation_date = ?
  ]]

local SELECT_DATA = [[
  select * from license_data
]]


local _M = {}
local mt = { __index = _M }


function _M:new(db)
  local self = {
    connector = db.connector,
    cluster   = db.connector.cluster,
  }

  return setmetatable(self, mt)
end


function _M:flush_data(data)
  local date_split = split(data.license_creation_date, "-")
  local timestamp = os.time({
    year = date_split[1],
    month = date_split[2],
    day = date_split[3],
  })

  local values = {
    cassandra.counter(data.request_count),
    cassandra.uuid(data.node_id),
    cassandra.timestamp(timestamp * 1000),
  }

  local QUERY_OPTIONS = {
    prepared = true,
  }

  local _, err = self.cluster:execute(UPDATE_STATEMENT, values, QUERY_OPTIONS)

  if err then
    log(ERR, "error occurred during counters data flush: ", err)
  end
end


function _M:pull_data()
  local QUERY_OPTIONS = {
    prepared = true,
  }

  local res, err = self.cluster:execute(SELECT_DATA, QUERY_OPTIONS)
  if err then
    log(ERR, "error occurred during data pull: ", err)
    return nil
  end

  return res
end


return _M
