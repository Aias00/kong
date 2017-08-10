local cassandra_strategy = require "kong.tools.public.rate-limiting.strategies.cassandra"
local dao_helpers        = require "spec.02-integration.03-dao.helpers"
local dao_factory        = require "kong.dao.factory"


do
  local say      = require "say"
  local luassert = require "luassert"

  local function has(state, args)
    local fixture, t = args[1], args[2]
    local has

    for i = 1, #t do
      local ok = pcall(assert.same, fixture, t[i])
      if ok then
        has = true
        break
      end
    end

    return has
  end

  say:set("assertion.has.positive",
          "Expected array to hold value but it did not\n" ..
          "Expected to have:\n%s\n"                       ..
          "But contained only:\n%s")
  say:set("assertion.has.negative",
          "Expected array to not hold value but it did\n" ..
          "Expected to not have:\n%s\n"                   ..
          "But array was:\n%s")
  luassert:register("assertion", "has", has,
                    "assertion.has.positive",
                    "assertion.has.negative")
end


dao_helpers.for_each_dao(function(kong_conf)

if kong_conf.database == "postgres" then
  return
end

describe("rate-limiting: Cassadra strategy", function()
  local strategy
  local dao
  local cluster

  setup(function()
    dao      = assert(dao_factory.new(kong_conf))
    strategy = cassandra_strategy.new(dao)
    cluster  = dao.db.cluster
  end)

  teardown(function()
    cluster:execute("TRUNCATE rl_counters")
  end)

  local diffs = {
    {
      key     = "foo",
      windows = {
        {
          namespace = "my_namespace",
          window    = 1502496000,
          size      = 10,
          diff      = 5,
        },
        {
          namespace = "my_namespace",
          window    = 1502496000,
          size      = 5,
          diff      = 2,
        },
      }
    },
    {
      key     = "1.2.3.4",
      windows = {
        {
          namespace = "my_namespace",
          window    = 1502496000,
          size      = 10,
          diff      = 5,
        },
        {
          namespace = "my_namespace",
          window    = 1502496000,
          size      = 5,
          diff      = 1,
        },
      }
    },
  }

  local expected_rows = {
    {
      count        = 5,
      key          = "1.2.3.4",
      namespace    = "my_namespace",
      window_size  = 10,
      window_start = 1502496000,
    },
    {
      count        = 5,
      key          = "foo",
      namespace    = "my_namespace",
      window_size  = 10,
      window_start = 1502496000,
    },
    {
      count        = 1,
      key          = "1.2.3.4",
      namespace    = "my_namespace",
      window_size  = 5,
      window_start = 1502496000,
    },
    {
      count        = 2,
      key          = "foo",
      namespace    = "my_namespace",
      window_size  = 5,
      window_start = 1502496000,
    },
    meta = {
      has_more_pages = false
    },
    type = "ROWS",
  }

  describe(":push_diffs()", function()
    it("pushes a diffs structure to the counters column_family", function()

      -- no return values
      strategy:push_diffs(diffs)

      -- check
      local rows = assert(cluster:execute("SELECT * FROM rl_counters"))
      assert.same(expected_rows, rows)
    end)
  end)

  describe(":get_window()", function()
    it("retrieves the counter for a given window", function()
      local count = assert(strategy:get_window("1.2.3.4", "my_namespace", 1502496000, 5))
      assert.equal(1, count)

      count = assert(strategy:get_window("1.2.3.4", "my_namespace", 1502496000, 10))
      assert.equal(5, count)

      count = assert(strategy:get_window("foo", "my_namespace", 1502496000, 5))
      assert.equal(2, count)

      count = assert(strategy:get_window("foo", "my_namespace", 1502496000, 10))
      assert.equal(5, count)
    end)
  end)

  describe(":get_counters()", function()
    local MIDNIGHT = 684288000

    local fixture_windows = {
      {
        key     = "1.2.3.4",
        windows = {
          {
            namespace = "namespace_1",
            window    = MIDNIGHT - 5,
            size      = 5,
            diff      = 1,
          },
          {
            namespace = "namespace_1",
            window    = MIDNIGHT,
            size      = 5,
            diff      = 1,
          },
          {
            namespace = "namespace_2",
            window    = MIDNIGHT,
            size      = 5,
            diff      = 1,
          }
        },
      },
    }

    setup(function()
      strategy:push_diffs(fixture_windows)
    end)

    it("yields all counters from windows inside a namespace", function()
      local counters = {}
      for row in strategy:get_counters("namespace_1", { 5, 10 }, MIDNIGHT) do
        table.insert(counters, row)
      end
      assert.equal(2, #counters)

      counters = {}
      for row in strategy:get_counters("namespace_2", { 5, 10 }, MIDNIGHT) do
        table.insert(counters, row)
      end
      assert.equal(1, #counters)
    end)

    it("yields counters from the current and previous windows", function()
      local counters = {}
      for row in strategy:get_counters("namespace_1", { 5 }, MIDNIGHT + 1) do
        table.insert(counters, row)
      end
      assert.equal(2, #counters)
      assert.has({
        key          = "1.2.3.4",
        namespace    = "namespace_1",
        window_size  = 5,
        window_start = MIDNIGHT,
        count        = 1
      }, counters)
      assert.has({
        key          = "1.2.3.4",
        namespace    = "namespace_1",
        window_size  = 5,
        window_start = MIDNIGHT - 5,
        count        = 1
      }, counters)
    end)
  end)
end)

end)
