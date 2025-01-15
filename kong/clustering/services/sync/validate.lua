local declarative = require("kong.db.declarative")
local declarative_config = require("kong.db.schema.others.declarative_config")


local null = ngx.null
local tb_insert = table.insert
local validate = declarative_config.validate
local pk_string = declarative_config.pk_string
local validate_references_sync = declarative_config.validate_references_sync
local pretty_print_error = declarative.pretty_print_error


local function validate_deltas(deltas, is_full_sync)

  -- generate deltas table mapping primary key string to entity item
  local deltas_map = {}

  -- generate declarative config table
  local dc_table = { _format_version = "3.0", }

  local db = kong.db

  for _, delta in ipairs(deltas) do
    local delta_type = delta.type
    local delta_entity = delta.entity

    if delta_entity ~= nil and delta_entity ~= null then
      dc_table[delta_type] = dc_table[delta_type] or {}

      tb_insert(dc_table[delta_type], delta_entity)

      -- table: primary key string -> entity
      local schema = db[delta_type].schema
      local pk = schema:extract_pk_values(delta_entity)
      local pks = pk_string(schema, pk)

      deltas_map[pks] = delta_entity
    end
  end

  -- validate schema
  local dc_schema = db.declarative_config.schema

  local ok, err_t = validate(dc_schema, dc_table)
  if not ok then
    return nil, pretty_print_error(err_t)
  end

  -- validate references
  local ok, err_t = validate_references_sync(deltas, deltas_map, is_full_sync)
  if not ok then
    return nil, pretty_print_error(err_t)
  end

  return true
end


return {
  validate_deltas = validate_deltas,
}
