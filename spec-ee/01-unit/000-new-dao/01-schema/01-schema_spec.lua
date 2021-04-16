-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local Schema = require "kong.db.schema"

describe("schema", function()
  describe("process_auto_fields", function()
    it("sets 'read_before_write' to true when updating field type record", function()
      local Test = Schema.new({
        name = "test",
        fields = {
          { config = { type = "record", fields = { foo = { type = "string" } } } },
        }
      })

      for _, operation in pairs{ "insert", "update", "select", "delete" } do
        local assertion = assert.falsy

        if operation == "update" then
          assertion = assert.truthy
        end

        local _, _, process_auto_fields = Test:process_auto_fields({
          config = {
            foo = "dog"
          }
        }, operation)

        assertion(process_auto_fields)
      end
    end)

    it("sets 'read_before_write' to false when not updating field type record", function()
      local Test = Schema.new({
        name = "test",
        fields = {
          { config = { type = "record", fields = { foo = { type = "string" } } } },
          { name = { type = "string" } }
        }
      })

      for _, operation in pairs{ "insert", "update", "select", "delete" } do
        local assertion = assert.falsy

        local _, _, process_auto_fields = Test:process_auto_fields({
          name = "cat"
        }, operation)

        assertion(process_auto_fields)
      end
    end)
  end)

  describe("merge_values", function()
    it("should correctly merge records", function()
      local Test = Schema.new({
        name = "test", fields = {
          { config = {
              type = "record",
              fields = {
                foo = { type = "string" },
                bar = { type = "string" }
              }
            }
          },
          { name = { type = "string" }
        }}
      })

      local old_values = {
        name = "test",
        config = { foo = "dog", bar = "cat" },
      }

      local new_values = {
        name = "test",
        config = { foo = "pig" },
      }

      local expected_values = {
        name = "test",
        config = { foo = "pig", bar = "cat" }
      }

      local values = Test:merge_values(new_values, old_values)

      assert.equals(values.config.foo, expected_values.config.foo)
      assert.equals(values.config.bar, expected_values.config.bar)
    end)
  end)

  describe("post_process_fields", function()
    describe("should call the post process function accordingly for", function()
      describe("encrypt = true", function()
        local ref, Test, Test_Arrays
        local MOCK_ENC = "mock encrypted"
        local MOCK_DEC = "mock decrypted"

        setup(function()
          ref = package.loaded["kong.keyring"]
          package.loaded["kong.keyring"] = {
            encrypt = function()
              return MOCK_ENC
            end,

            decrypt = function()
              return MOCK_DEC
            end,
          }

          package.loaded["kong.db.schema"] = nil
          Schema = require "kong.db.schema"

          Test = Schema.new({
            name = "test",
            fields = {
              { foo = { type = "string" } },
              { bar = { type = "string", encrypted = true } },
            }
          })

          Test_Arrays = Schema.new({
            name = "test_arrays",
            fields = {
              {
                foo = {
                  type = "string",
                  encrypted = true,
                }
              },
              {
                bar = {
                  type = "array",
                  elements = {
                    type = "string",
                    encrypted = true,
                  }
                }
              },
              {
                three = {
                  type = "array",
                  encrypted = true,
                  elements = {
                    type = "string",
                  }
                }
              },
              {
                four = {
                  type = "array",
                  encrypted = true,
                  elements = {
                    type = "string",
                    encrypted = true,
                    random_field = true,
                  }
                }
              },
            }
          })
        end)

        teardown(function()
          package.loaded["kong.keyring"] = ref
        end)

        for _, operation in ipairs({ "insert", "upsert", "update" }) do
          it("on " .. operation, function()
            local obj = Test:post_process_fields({
              foo = "foo",
              bar = "bar",
            }, operation)

            assert.same(obj.bar, MOCK_ENC)

            obj = Test_Arrays:post_process_fields({
              foo = "foo",
              bar = { "bar", "bar2" },
              three = { "one", "two" },
              four = { "one", "two" }
            }, operation)

            assert.same(obj.foo, MOCK_ENC)
            assert.same(obj.bar[1], "bar")
            assert.same(obj.bar[2], "bar2")
            assert.same(obj.three[2], MOCK_ENC)
            assert.same(obj.three[1], MOCK_ENC)
            assert.same(obj.four[1], MOCK_ENC)
            assert.same(obj.four[2], MOCK_ENC)
          end)
        end

        it("on select", function()
          local obj = Test:post_process_fields({
            foo = "foo",
            bar = "bar",
          }, "select")

          assert.same(obj.bar, MOCK_DEC)

          obj = Test_Arrays:post_process_fields({
            foo = "foo",
            bar = { "bar", "bar2" },
            three = { "one", "two" },
            four = { "one", "two" }
          }, "select")

          assert.same(obj.foo, MOCK_DEC)
          assert.same(obj.bar[1], "bar")
          assert.same(obj.bar[2], "bar2")
          assert.same(obj.three[1], MOCK_DEC)
          assert.same(obj.three[2], MOCK_DEC)
          assert.same(obj.four[1], MOCK_DEC)
          assert.same(obj.four[2], MOCK_DEC)
        end)
      end)
    end)
  end)
end)
