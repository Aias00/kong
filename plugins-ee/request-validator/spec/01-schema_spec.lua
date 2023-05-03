-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local request_validator_schema = require "kong.plugins.request-validator.schema"
local v = require("spec.helpers").validate_plugin_config_schema


describe("request-validator schema", function()
  it("requires either a body_schema or parameter_schema", function()
    local ok, err = v({}, request_validator_schema)
    assert.is_nil(ok)
    assert.same("at least one of these fields must be non-empty: 'body_schema', " ..
                "'parameter_schema'", err.config["@entity"][1])
  end)

  describe("[Kong-schema]", function()
    it("accepts a valid body_schema", function()
      local ok, err = v({
        version = "kong",
        body_schema = '[{"name": {"type": "string"}}]'
      }, request_validator_schema)
      assert.is_truthy(ok)
      assert.is_nil(err)
    end)

    it("errors with an invalid body_schema json", function()
      local ok, err = v({
        version = "kong",
        body_schema = '[{"name": {"type": "string}}'
      }, request_validator_schema)
      assert.is_nil(ok)
      assert.same("failed decoding schema: Expected value but found unexpected " ..
                  "end of string at character 29", err["@entity"][1])
    end)

    it("errors with an invalid schema", function()
      local ok, err = v({
        version = "kong",
        body_schema = '[{"name": {"type": "string", "non_existing_field": "bar"}}]'
      }, request_validator_schema)
      assert.is_nil(ok)
      assert.same("schema violation", err["@entity"][1].name)
    end)

    it("errors with an fields specification", function()
      local ok, err = v({
        version = "kong",
        body_schema = '{"name": {"type": "string", "non_existing_field": "bar"}}'
      }, request_validator_schema)
      assert.is_nil(ok)
      assert.same("schema violation", err["@entity"][1].name)
    end)
  end)

  describe("[draft4-schema]", function()
    it("accepts a valid body_schema", function()
      local ok, err = v({
        version = "draft4",
        body_schema = '{"name": {"type": "string"}}'
      }, request_validator_schema)
      assert.is_nil(err)
      assert.is_truthy(ok)
    end)

    it("errors with an invalid body_schema json", function()
      local ok, err = v({
        version = "draft4",
        body_schema = '{"name": {"type": "string}' -- closing bracket missing
      }, request_validator_schema)
      assert.same("failed decoding schema: Expected value but found unexpected " ..
                  "end of string at character 27", err["@entity"][1])
      assert.is_nil(ok)
    end)

    it("errors with an invalid schema", function()
      -- the metaschema references itself, and hence cannot be loaded
      -- to be fixed in ljsonschema lib first
      local ok, err = v({
        version = "draft4",
        body_schema = [[{
            "type": "object",
            "definitions": [ "should have been an object" ]
        }]]
      }, request_validator_schema)
      assert.same("not a valid JSONschema draft 4 schema: property " ..
        "definitions validation failed: wrong type: " ..
        "expected object, got table", err["@entity"][1])
      assert.is_nil(ok)
    end)

    it("accepts allowed_content_type", function()
      local ok, err = v({
        version = "kong",
        allowed_content_types = {
          "*/*",
          "application/xml",
          "application/json",
          "application/xml;charset=ISO-8859-1",
          "application/json; charset=UTF-8",
          "application/x-msgpack",
          "application/x-msgpack; charset=UTF-8",
        },
        body_schema = '[{"name": {"type": "string"}}]'
      }, request_validator_schema)
      assert.is_nil(err)
      assert.is_truthy(ok)
    end)

    it("does not accepts bad allowed_content_type", function()
      local ok, err = v({
        version = "kong",
        allowed_content_types = {"application/ xml"},
        body_schema = '[{"name": {"type": "string"}}]',
      }, request_validator_schema)
      assert.same("invalid value: application/ xml",
                  err.config.allowed_content_types[1])
      assert.is_nil(ok)

      local ok, err = v({
        version = "kong",
        allowed_content_types = {"application/json; charset"},
        body_schema = '[{"name": {"type": "string"}}]',
      }, request_validator_schema)
      assert.same("invalid value: application/json; charset",
        err.config.allowed_content_types[1])
      assert.is_nil(ok)
    end)
  end)

  it("does not accepts bad allowed_content_type with multiple parameters", function()
    local ok, err = v({
      version = "kong",
      allowed_content_types = { "application/json; charset=utf-8; param1=value1" },
      body_schema = '[{"name": {"type": "string"}}]',
    }, request_validator_schema)
    assert.same("does not support multiple parameters: application/json; charset=utf-8; param1=value1",
      err.config.allowed_content_types[1])
    assert.is_nil(ok)
  end)

  describe("[parameter-schema]", function()
    it("accepts a valid parameter definition ", function()
      local ok, err = v({
        version = "draft4",
        body_schema = '{"name": {"type": "string"}}',
        parameter_schema = {
          {
            name = "x-kong-name",
            ["in"] = "header",
            required = true,
            schema = '{"type": "array", "items": {"type": "string"}}',
            style = "simple",
            explode = false,
          }
        }
      }, request_validator_schema)
      assert.is_nil(err)
      assert.is_truthy(ok)
    end)

    it("accepts a valid parameter definition that is a reference", function()
      local ok, err = v({
        version = "draft4",
        body_schema = '{"name": {"type": "string"}}',
        parameter_schema = {
          {
            name = "x-kong-name",
            ["in"] = "header",
            required = true,
            schema = '{"$ref":"#/definitions/TrackId","definitions":{"TrackId":{"type":"string"}}}',
            style = "simple",
            explode = false,
          }
        }
      }, request_validator_schema)
      assert.is_nil(err)
      assert.is_truthy(ok)
    end)

    it("accepts a valid param_schema with type object", function()
      local ok, err = v({
        version = "draft4",
        body_schema = '{"name": {"type": "string"}}',
        parameter_schema = {
          {
            name = "x-kong-name",
            ["in"] = "header",
            required = true,
            schema = '{"type": "object", "additionalProperties": {"type": "integer"}}',
            style = "simple",
            explode = false,
          }
        }
      }, request_validator_schema)
      assert.is_nil(err)
      assert.is_truthy(ok)
    end)

    it("errors with invalid param_schema", function()
      local ok, err = v({
        version = "draft4",
        body_schema = '{"name": {"type": "string"}}',
        parameter_schema = {
          {
            name = "x-kong-name",
            ["in"] = "header",
            required = true,
            schema = '{"type": "object", "additionalProperties": {"type": "integer"}}',
            style = "simple",
            explode = false,
          },
          {
            name = "x-kong-name",
            ["in"] = "header",
            required = true,
            -- wrong type
            schema = '{"type": "objects", "additionalProperties": {"type": "integer"}}',
            style = "simple",
            explode = false,
          }
        }
      }, request_validator_schema)

      assert.is_truthy(string.match(err.config.parameter_schema[2].schema,
                                    "not a valid JSONschema draft 4 schema: property type validation failed:"))
      assert.is_nil(ok)
    end)

    it("errors with invalid style", function()
      local ok, err = v({
        version = "draft4",
        body_schema = '{"name": {"type": "string"}}',
        parameter_schema = {
          {
            name = "x-kong-name",
            ["in"] = "header",
            required = true,
            schema = '{"type": "object", "additionalProperties": {"type": "integer"}}',
            style = "form",
            explode = false,
          },
        }
      }, request_validator_schema)
      assert.same("style 'form' not supported 'header' parameter", err.config.parameter_schema[1]["@entity"][1])
      assert.is_nil(ok)
    end)

    it("errors with style present but schema missing", function()
      local ok, err = v({
        version = "draft4",
        body_schema = '{"name": {"type": "string"}}',
        parameter_schema = {
          {
            name = "x-kong-name",
            ["in"] = "header",
            required = true,
            --schema = '{"type": "object", "additionalProperties": {"type": "integer"}}',
            style = "form",
            explode = false,
          },
        }
      }, request_validator_schema)
      assert.same({
        [1] = "all or none of these fields must be set: 'style', 'explode', 'schema'",
        [2] = "style 'form' not supported 'header' parameter",
      }, err.config.parameter_schema[1]["@entity"])
      assert.is_nil(ok)
    end)

    it("allow without style, schema and explode", function()
      local ok, err = v({
        version = "draft4",
        body_schema = '{"name": {"type": "string"}}',
        parameter_schema = {
          {
            name = "x-kong-name",
            ["in"] = "header",
            required = true,
            --schema = '{"type": "object", "additionalProperties": {"type": "integer"}}',
            --style = "form",
            --explode = false,
          },
        }
      }, request_validator_schema)
      assert.is_nil(err)
      assert.is_truthy(ok)
    end)

    it("errors without a parameter type specified", function()
      local ok, err = v({
        version = "draft4",
        body_schema = nil,
        parameter_schema = {
          {
            name = "kpiId",
            ["in"] = "query",
            required = false,
            -- this schema defines a top-level "AnyOf", which specifies either
            -- a "string" or an "array", but then the validator doesn't know
            -- how to deserialize the value
            schema = [[{
                        "anyOf": [
                          {
                            "maxLength": 5000,
                            "minLength": 0,
                            "pattern": "^[\\w\\.\\-]{1,256}$",
                            "type": "string"
                          },
                          {
                            "maxItems": 10000,
                            "type": "array",
                            "items": {
                              "maxLength": 5000,
                              "minLength": 0,
                              "pattern": "^[\\w\\.\\-]{1,256}$",
                              "type": "string"
                            }
                          }
                        ]
                      }]],
            style = "form",
            explode = false,
          },
        }
      }, request_validator_schema)
      assert.same("the JSONschema is missing a top-level 'type' property",
                  err.config.parameter_schema[1].schema)
      assert.is_nil(ok)
    end)
  end)

end)
