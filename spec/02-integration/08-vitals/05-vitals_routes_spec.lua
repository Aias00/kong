local helpers     = require "spec.helpers"
local dao_helpers = require "spec.02-integration.03-dao.helpers"
local utils       = require "kong.tools.utils"
local cassandra   = require "kong.vitals.cassandra.strategy"
local postgres    = require "kong.vitals.postgres.strategy"
local cjson       = require "cjson"
local time        = ngx.time
local fmt         = string.format

dao_helpers.for_each_dao(function(kong_conf)

  describe("Admin API Vitals with " .. kong_conf.database, function()
    local client, dao, strategy, bp, _

    local minute_start_at = time() - ( time() % 60 )
    local node_1 = "20426633-55dc-4050-89ef-2382c95a611e"
    local node_2 = "8374682f-17fd-42cb-b1dc-7694d6f65ba0"
    local node_3 = "20478633-55dc-4050-89ef-2382c95a611f"

    local stat_labels = {
      "cache_datastore_hits_total",
      "cache_datastore_misses_total",
      "latency_proxy_request_min_ms",
      "latency_proxy_request_max_ms",
      "latency_upstream_min_ms",
      "latency_upstream_max_ms",
      "requests_proxy_total",
      "latency_proxy_request_avg_ms",
      "latency_upstream_avg_ms",
    }

    local consumer_stat_labels = {
      "requests_consumer_total",
    }

    describe("when vitals is enabled", function()
      setup(function()

        -- TODO: when this file is refactored to use the new dao, this line should
        -- return `bp, db, dao` and not just bp (there will be lint issues if
        -- doing so currently).
        bp, _, dao = helpers.get_db_utils(kong_conf.database)


        -- to insert test data
        if dao.db_type == "postgres" then
          strategy = postgres.new(dao)
          local q = "create table if not exists " .. strategy:current_table_name() ..
              "(LIKE vitals_stats_seconds INCLUDING defaults INCLUDING constraints INCLUDING indexes)"
          assert(dao.db:query(q))

          local node_q = "insert into vitals_node_meta(node_id, hostname) values('%s', '%s')"
          local nodes = { node_1, node_2, node_3 }

          for i, node in ipairs(nodes) do
            assert(dao.db:query(fmt(node_q, node, "testhostname" .. i)))
          end
        else
          strategy = cassandra.new(dao)

          local node_q = "insert into vitals_node_meta(node_id, hostname) values("
          local nodes = { node_1, node_2, node_3 }

          for i, node in ipairs(nodes) do
            assert(dao.db.cluster:execute(node_q .. node .. ", '" .. "testhostname" .. i .. "')"))
          end
        end

        local test_data_1 = {
          { minute_start_at, 0, 0, nil, nil, nil, nil, 0, 1, 10, 1, 10 },
          { minute_start_at + 1, 0, 3, 0, 11, 193, 212, 1, 1, 10, 1, 10 },
          { minute_start_at + 2, 3, 4, 1, 8, 60, 9182, 4, 1, 10, 1, 10 },
        }

        local test_data_2 = {
          { minute_start_at + 1, 1, 5, 0, 99, 25, 144, 9, 1, 10, 1, 10 },
          { minute_start_at + 2, 1, 7, 0, 0, 13, 19, 8, 1, 10, 1, 10 },
        }

        assert(strategy:insert_stats(test_data_1, node_1))
        assert(strategy:insert_stats(test_data_2, node_2))

        assert(helpers.start_kong({
          database = kong_conf.database,
          vitals   = true,
        }))

        client = helpers.admin_client()
      end)

      teardown(function()
        if client then
          client:close()
        end

        helpers.stop_kong()
      end)

      describe("/vitals", function()
        describe("GET", function()
          it("returns data about vitals configuration", function()
            local res = assert(client:send {
              methd = "GET",
              path = "/vitals"
            })
            res = assert.res_status(200, res)
            local json = cjson.decode(res)

            local expected = {
              stats = {
                cache_datastore_hits_total = {
                  levels = {
                    cluster = {
                      intervals = {
                        seconds = { retention_period_seconds = 3600 },
                        minutes = { retention_period_seconds = 90000 },
                      },
                    },
                    nodes = {
                      intervals = {
                        seconds = { retention_period_seconds = 3600 },
                        minutes = { retention_period_seconds = 90000 },
                      },
                    },
                  }
                },
                cache_datastore_misses_total = {
                  levels = {
                    cluster = {
                      intervals = {
                        seconds = { retention_period_seconds = 3600 },
                        minutes = { retention_period_seconds = 90000 },
                      },
                    },
                    nodes = {
                      intervals = {
                        seconds = { retention_period_seconds = 3600 },
                        minutes = { retention_period_seconds = 90000 },
                      },
                    },
                  }
                },
                latency_proxy_request_min_ms = {
                  levels = {
                    cluster = {
                      intervals = {
                        seconds = { retention_period_seconds = 3600 },
                        minutes = { retention_period_seconds = 90000 },
                      },
                    },
                    nodes = {
                      intervals = {
                        seconds = { retention_period_seconds = 3600 },
                        minutes = { retention_period_seconds = 90000 },
                      },
                    },
                  }
                },
                latency_proxy_request_max_ms = {
                  levels = {
                    cluster = {
                      intervals = {
                        seconds = { retention_period_seconds = 3600 },
                        minutes = { retention_period_seconds = 90000 },
                      },
                    },
                    nodes = {
                      intervals = {
                        seconds = { retention_period_seconds = 3600 },
                        minutes = { retention_period_seconds = 90000 },
                      },
                    },
                  }
                },
                latency_upstream_min_ms = {
                  levels = {
                    cluster = {
                      intervals = {
                        seconds = { retention_period_seconds = 3600 },
                        minutes = { retention_period_seconds = 90000 },
                      },
                    },
                    nodes = {
                      intervals = {
                        seconds = { retention_period_seconds = 3600 },
                        minutes = { retention_period_seconds = 90000 },
                      },
                    },
                  }
                },
                latency_upstream_max_ms = {
                  levels = {
                    cluster = {
                      intervals = {
                        seconds = { retention_period_seconds = 3600 },
                        minutes = { retention_period_seconds = 90000 },
                      },
                    },
                    nodes = {
                      intervals = {
                        seconds = { retention_period_seconds = 3600 },
                        minutes = { retention_period_seconds = 90000 },
                      },
                    },
                  }
                },
                requests_proxy_total = {
                  levels = {
                    cluster = {
                      intervals = {
                        seconds = { retention_period_seconds = 3600 },
                        minutes = { retention_period_seconds = 90000 },
                      },
                    },
                    nodes = {
                      intervals = {
                        seconds = { retention_period_seconds = 3600 },
                        minutes = { retention_period_seconds = 90000 },
                      },
                    },
                  }
                },
                requests_consumer_total = {
                  levels = {
                    cluster = {
                      intervals = {
                        seconds = { retention_period_seconds = 3600 },
                        minutes = { retention_period_seconds = 90000 },
                      },
                    },
                    nodes = {
                      intervals = {
                        seconds = { retention_period_seconds = 3600 },
                        minutes = { retention_period_seconds = 90000 },
                      },
                    },
                  }
                },
                latency_proxy_request_avg_ms = {
                  levels = {
                    cluster = {
                      intervals = {
                        seconds = { retention_period_seconds = 3600 },
                        minutes = { retention_period_seconds = 90000 },
                      },
                    },
                    nodes = {
                      intervals = {
                        seconds = { retention_period_seconds = 3600 },
                        minutes = { retention_period_seconds = 90000 },
                      },
                    },
                  }
                },
                latency_upstream_avg_ms = {
                  levels = {
                    cluster = {
                      intervals = {
                        seconds = { retention_period_seconds = 3600 },
                        minutes = { retention_period_seconds = 90000 },
                      },
                    },
                    nodes = {
                      intervals = {
                        seconds = { retention_period_seconds = 3600 },
                        minutes = { retention_period_seconds = 90000 },
                      },
                    },
                  }
                },
                status_code_classes_total = {
                  levels = {
                    cluster = {
                      intervals = {
                        seconds = { retention_period_seconds = 3600 },
                        minutes = { retention_period_seconds = 90000 },
                      },
                    },
                  }
                },
                status_codes_per_consumer_route_total = {
                  levels = {
                    cluster = {
                      intervals = {
                        seconds = { retention_period_seconds = 3600 },
                        minutes = { retention_period_seconds = 90000 },
                      },
                    },
                  }
                },
                status_codes_per_consumer_total = {
                  levels = {
                    cluster = {
                      intervals = {
                        seconds = { retention_period_seconds = 3600 },
                        minutes = { retention_period_seconds = 90000 },
                      },
                    },
                  }
                },
                status_codes_per_service_total = {
                  levels = {
                    cluster = {
                      intervals = {
                        seconds = { retention_period_seconds = 3600 },
                        minutes = { retention_period_seconds = 90000 },
                      },
                    },
                  }
                },
                status_codes_per_route_total = {
                  levels = {
                    cluster = {
                      intervals = {
                        seconds = { retention_period_seconds = 3600 },
                        minutes = { retention_period_seconds = 90000 },
                      },
                    },
                  }
                },
              }
            }

            assert.same(expected, json)
          end)
        end)
      end)

      describe("/vitals/cluster", function()
        describe("GET", function()
          it("retrieves the vitals seconds cluster data", function()
            local res = assert(client:send {
              methd = "GET",
              path = "/vitals/cluster",
              query = {
                interval = "seconds"
              }
            })
            res = assert.res_status(200, res)
            local json = cjson.decode(res)

            local expected = {
              meta = {
                level = "cluster",
                interval = "seconds",
                interval_width = 1,
                earliest_ts = minute_start_at,
                latest_ts = minute_start_at + 2,
                stat_labels = stat_labels,
              },
              stats = {
                cluster = {
                  [tostring(minute_start_at)] = { 0, 0, cjson.null, cjson.null, cjson.null, cjson.null, 0, 10, 10 },
                  [tostring(minute_start_at + 1)] = { 1, 8, 0, 99, 25, 212, 10, 10, 10 },
                  [tostring(minute_start_at + 2)] = { 4, 11, 0, 8, 13, 9182, 12, 10, 10 }
                }
              }
            }

            assert.same(expected, json)
          end)

          it("retrieves the vitals minutes cluster data", function()
            local res = assert(client:send {
              methd = "GET",
              path = "/vitals/cluster",
              query = {
                interval = "minutes"
              }
            })
            res = assert.res_status(200, res)
            local json = cjson.decode(res)

            local expected = {
              meta = {
                level = "cluster",
                interval = "minutes",
                interval_width = 60,
                earliest_ts = minute_start_at,
                latest_ts = minute_start_at,
                stat_labels = stat_labels,
              },
              stats = {
                cluster = {
                  [tostring(minute_start_at)] = { 5, 19, 0, 99, 13, 9182, 22, 10, 10 }
                }
              }
            }

            assert.same(expected, json)
          end)

          it("returns a 400 if called with invalid interval", function()
            local res = assert(client:send {
              methd = "GET",
              path = "/vitals/cluster",
              query = {
                interval = "so-wrong"
              }
            })
            res = assert.res_status(400, res)
            local json = cjson.decode(res)

            assert.same("Invalid query params: interval must be 'minutes' or 'seconds'", json.message)
          end)

          it("returns a 400 if called with invalid start_ts", function()
            local res = assert(client:send {
              methd = "GET",
              path = "/vitals/cluster",
              query = {
                interval = "minutes",
                start_ts = "foo",
              }
            })
            res = assert.res_status(400, res)
            local json = cjson.decode(res)

            assert.same("Invalid query params: start_ts must be a number", json.message)
          end)
        end)
      end)

      describe("/vitals/cluster/status_codes", function()
        before_each(function()
          dao.db:truncate_table("vitals_code_classes_by_cluster")
        end)

        describe("GET", function()
          it("retrieves the seconds-level response code data for the cluster", function()
            local now = time()

            local test_status_code_class_data = {
              { 4, now - 1, 1, 10 },
              { 4, now, 1, 15 },
              { 5, now, 1, 20 },
            }

            assert(strategy:insert_status_code_classes(test_status_code_class_data))

            local res = assert(client:send {
              methd = "GET",
              path = "/vitals/cluster/status_codes",
              query = {
                interval = "seconds",
              }
            })
            res = assert.res_status(200, res)
            local json = cjson.decode(res)

            local expected = {
              meta = {
                earliest_ts = now - 1,
                interval    = "seconds",
                latest_ts   = now,
                level       = "cluster",
                entity_type = "cluster",
                stat_labels = {
                  "status_code_classes_total",
                },
              },
              stats = {
                cluster = {
                  [tostring(now - 1)] = {
                    ["4xx"] = 10,
                  },
                  [tostring(now)] = {
                    ["4xx"] = 15,
                    ["5xx"] = 20,
                  },
                }
              }
            }

            assert.same(expected, json)
          end)

          it("retrieves the minutes-level response code data for the cluster", function()
            local minute_start_at = time() - (time() % 60)

            local test_status_code_class_data = {
              { 4, minute_start_at - 60, 60, 10 },
              { 4, minute_start_at, 60, 25 },
              { 5, minute_start_at, 60, 20 },
            }

            assert(strategy:insert_status_code_classes(test_status_code_class_data))

            local res = assert(client:send {
              methd = "GET",
              path = "/vitals/cluster/status_codes",
              query = {
                interval = "minutes",
              }
            })
            res = assert.res_status(200, res)
            local json = cjson.decode(res)

            local expected = {
              meta = {
                earliest_ts = minute_start_at - 60,
                interval    = "minutes",
                latest_ts   = minute_start_at,
                level       = "cluster",
                entity_type = "cluster",
                stat_labels = {
                  "status_code_classes_total",
                },
              },
              stats = {
                cluster = {
                  [tostring(minute_start_at - 60)] = {
                    ["4xx"] = 10,
                  },
                  [tostring(minute_start_at)] = {
                    ["4xx"] = 25,
                    ["5xx"] = 20,
                  },
                }
              }
            }

            assert.same(expected, json)
          end)

          it("returns a 400 if called with invalid interval", function()
            local res = assert(client:send {
              methd = "GET",
              path = "/vitals/cluster/status_codes",
              query = {
                interval = "so-wrong",
              }
            })
            res = assert.res_status(400, res)
            local json = cjson.decode(res)

            assert.same("Invalid query params: interval must be 'minutes' or 'seconds'", json.message)
          end)

          it("returns a 400 if called with invalid start_ts", function()
            local res = assert(client:send {
              methd = "GET",
              path = "/vitals/cluster/status_codes",
              query = {
                interval = "minutes",
                start_ts = "foo",
              }
            })
            res = assert.res_status(400, res)
            local json = cjson.decode(res)

            assert.same("Invalid query params: start_ts must be a number", json.message)
          end)
        end)
      end)

      describe("/vitals/status_codes/by_service", function()
        local service, service_id

        before_each(function()
          dao.db:truncate_table("vitals_codes_by_service")
          dao.db:truncate_table("services")

          helpers.with_current_ws(nil, function()
          service    = bp.services:insert()
          end, dao)
          service_id = service.id
        end)

        describe("GET", function()
          it("retrieves the seconds-level response code data for a given service", function()
            local now = time()

            if dao.db_type == "cassandra" then
              assert(strategy:insert_status_codes_by_service({
                { service_id, 404, now, 1, 101},
                { service_id, 200, now - 1, 1, 205},
                { service_id, 500, now - 1, 1, 6},
              }))
            else
              assert(strategy:insert_status_codes_by_route({
                { utils.uuid(), service_id, "404", now, 1, 101 },
                { utils.uuid(), service_id, "200", now - 1, 1, 205 },
                { utils.uuid(), service_id, "500", now - 1, 1, 6 },
              }))
            end

            local res = assert(client:send {
              methd = "GET",
              path = "/vitals/status_codes/by_service",
              query = {
                interval   = "seconds",
                service_id = service_id,
              }
            })

            res = assert.res_status(200, res)
            local json = cjson.decode(res)

            local expected = {
              meta = {
                entity_type = "service",
                entity_id   = service_id,
                earliest_ts = now - 1,
                interval    = "seconds",
                latest_ts   = now,
                level       = "cluster",
                stat_labels = {
                  "status_codes_per_service_total",
                },
              },
              stats = {
                cluster = {
                  [tostring(now - 1)] = {
                    ["200"] = 205,
                    ["500"] = 6,
                  },
                  [tostring(now)] = {
                    ["404"] = 101,
                  },
                }
              }
            }

            assert.same(expected, json)
          end)

          it("retrieves the minutes-level response code data for a given service", function()
            local minute_start_at = time() - (time() % 60)

            if dao.db_type == "cassandra" then
              assert(strategy:insert_status_codes_by_service({
                { service_id, 404, minute_start_at, 60, 101},
                { service_id, 200, minute_start_at - 60, 60, 205},
                { service_id, 500, minute_start_at - 60, 60, 6},
              }))
            else
              assert(strategy:insert_status_codes_by_route({
                { utils.uuid(), service_id, "404", minute_start_at, 60, 101 },
                { utils.uuid(), service_id, "200", minute_start_at - 60, 60, 205 },
                { utils.uuid(), service_id, "500", minute_start_at - 60, 60, 6 },
              }))
            end

            local res = assert(client:send {
              methd = "GET",
              path = "/vitals/status_codes/by_service",
              query = {
                interval   = "minutes",
                service_id = service_id,
              }
            })
            res = assert.res_status(200, res)
            local json = cjson.decode(res)

            local expected = {
              meta = {
                entity_type = "service",
                entity_id   = service_id,
                earliest_ts = minute_start_at - 60,
                interval    = "minutes",
                latest_ts   = minute_start_at,
                level       = "cluster",
                stat_labels = {
                  "status_codes_per_service_total",
                },
              },
              stats = {
                cluster = {
                  [tostring(minute_start_at - 60)] = {
                    ["200"] = 205,
                    ["500"] = 6,
                  },
                  [tostring(minute_start_at)] = {
                    ["404"] = 101,
                  },
                }
              }
            }

            assert.same(expected, json)
          end)

          it("returns a 400 if called with invalid interval", function()
            local res = assert(client:send {
              methd = "GET",
              path = "/vitals/status_codes/by_service",
              query = {
                interval   = "so-wrong",
                service_id = service_id,
              }
            })
            res = assert.res_status(400, res)
            local json = cjson.decode(res)

            assert.same("Invalid query params: interval must be 'minutes' or 'seconds'", json.message)
          end)

          it("returns a 400 if called with invalid service_id", function()
            local service_id = "shh.. I'm not a real service id"
            local res = assert(client:send {
              methd = "GET",
              path = "/vitals/status_codes/by_service",
              query = {
                interval   = "minutes",
                service_id = service_id,
              }
            })
            res = assert.res_status(400, res)
            local json = cjson.decode(res)

            assert.same("Invalid query params: service_id is invalid", json.message)
          end)

          it("returns a 400 if called with invalid start_ts", function()
            local res = assert(client:send {
              methd = "GET",
              path = "/vitals/status_codes/by_service",
              query = {
                interval   = "seconds",
                service_id = service_id,
                start_ts   = "foo",
              }
            })
            res = assert.res_status(400, res)
            local json = cjson.decode(res)

            assert.same("Invalid query params: start_ts must be a number", json.message)
          end)

          it("returns a 404 if called with a service_id that doesn't exist", function()
            local service_id = "20426633-55dc-4050-89ef-2382c95a611e"
            local res = assert(client:send {
              methd = "GET",
              path = "/vitals/status_codes/by_service",
              query = {
                interval   = "minutes",
                service_id = service_id,
              }
            })
            res = assert.res_status(404, res)
            local json = cjson.decode(res)

            assert.same("Not found", json.message)
          end)
        end)
      end)

      describe("/vitals/status_codes/by_route", function()
        local route, route_id

        before_each(function()
          dao.db:truncate_table("vitals_codes_by_route")
          dao.db:truncate_table("routes")

          helpers.with_current_ws(nil, function()
          route    = bp.routes:insert({ paths = { "/my-route" } })
          end, dao)
          route_id = route.id
        end)

        describe("GET", function()
          it("retrieves the seconds-level response code data for a given route", function()
            local now = time()
            local service_id = utils.uuid()

            local test_status_code_data = {
              { route_id, service_id, "404", tostring(now), "1", 101},
              { route_id, service_id, "200", tostring(now - 1), "1", 205},
              { route_id, service_id, "500", tostring(now - 1), "1", 6},
            }

            assert(strategy:insert_status_codes_by_route(test_status_code_data))

            local res = assert(client:send {
              methd = "GET",
              path = "/vitals/status_codes/by_route",
              query = {
                interval = "seconds",
                route_id = route_id,
              }
            })

            res = assert.res_status(200, res)
            local json = cjson.decode(res)

            local expected = {
              meta = {
                entity_type = "route",
                entity_id   = route_id,
                earliest_ts = now - 1,
                interval    = "seconds",
                latest_ts   = now,
                level       = "cluster",
                stat_labels = {
                  "status_codes_per_route_total",
                },
              },
              stats = {
                cluster = {
                  [tostring(now - 1)] = {
                    ["200"] = 205,
                    ["500"] = 6,
                  },
                  [tostring(now)] = {
                    ["404"] = 101,
                  },
                }
              }
            }

            assert.same(expected, json)
          end)

          it("retrieves the minutes-level response code data for a given route", function()
            local minute_start_at = time() - (time() % 60)
            local service_id = utils.uuid()

            local test_status_code_data = {
              { route_id, service_id, "404", tostring(minute_start_at), "60", 101},
              { route_id, service_id, "200", tostring(minute_start_at - 60), "60", 205},
              { route_id, service_id, "500", tostring(minute_start_at - 60), "60", 6},
            }

            assert(strategy:insert_status_codes_by_route(test_status_code_data))

            local res = assert(client:send {
              methd = "GET",
              path = "/vitals/status_codes/by_route",
              query = {
                interval = "minutes",
                route_id = route_id,
              }
            })
            res = assert.res_status(200, res)
            local json = cjson.decode(res)

            local expected = {
              meta = {
                entity_type = "route",
                entity_id   = route_id,
                earliest_ts = minute_start_at - 60,
                interval    = "minutes",
                latest_ts   = minute_start_at,
                level       = "cluster",
                stat_labels = {
                  "status_codes_per_route_total",
                },
              },
              stats = {
                cluster = {
                  [tostring(minute_start_at - 60)] = {
                    ["200"] = 205,
                    ["500"] = 6,
                  },
                  [tostring(minute_start_at)] = {
                    ["404"] = 101,
                  },
                }
              }
            }

            assert.same(expected, json)
          end)

          it("returns a 400 if called with invalid interval", function()
            local res = assert(client:send {
              methd = "GET",
              path = "/vitals/status_codes/by_route",
              query = {
                interval = "so-wrong",
                route_id = route_id,
              }
            })
            res = assert.res_status(400, res)
            local json = cjson.decode(res)

            assert.same("Invalid query params: interval must be 'minutes' or 'seconds'", json.message)
          end)

          it("returns a 400 if called with invalid route_id", function()
            local route_id = "shh.. I'm not a real route id"
            local res = assert(client:send {
              methd = "GET",
              path = "/vitals/status_codes/by_route",
              query = {
                interval = "minutes",
                route_id = route_id,
              }
            })
            res = assert.res_status(400, res)
            local json = cjson.decode(res)

            assert.same("Invalid query params: route_id is invalid", json.message)
          end)

          it("returns a 400 if called with no route_id", function()
            local res = assert(client:send {
              methd = "GET",
              path = "/vitals/status_codes/by_route",
              query = {
                interval = "minutes",
              }
            })
            res = assert.res_status(400, res)
            local json = cjson.decode(res)

            assert.same("Invalid query params: route_id is invalid", json.message)
          end)

          it("returns a 400 if called with invalid start_ts", function()
            local res = assert(client:send {
              methd = "GET",
              path = "/vitals/status_codes/by_route",
              query = {
                interval = "seconds",
                route_id = route_id,
                start_ts = "foo",
              }
            })
            res = assert.res_status(400, res)
            local json = cjson.decode(res)

            assert.same("Invalid query params: start_ts must be a number", json.message)
          end)

          it("returns a 404 if called with a route_id that is not an actual id for a route", function()
            local route_id = "20426633-55dc-4050-89ef-2382c95a611a"
            local res = assert(client:send {
              methd = "GET",
              path = "/vitals/status_codes/by_route",
              query = {
                interval = "minutes",
                route_id = route_id,
              }
            })
            res = assert.res_status(404, res)
            local json = cjson.decode(res)

            assert.same("Not found", json.message)
          end)
        end)
      end)

      describe("/vitals/status_codes/by_consumer", function()
        before_each(function()
          dao.db:truncate_table("consumers")
          dao.db:truncate_table("vitals_codes_by_consumer_route")
        end)

        describe("GET", function()
          it("retrieves the seconds-level response code data for a given consumer", function()
            local consumer
            helpers.with_current_ws(
              dao.workspaces:find_all({name = "default"}),
              function()
                consumer = assert(dao.consumers:insert {
                  username  = "bob",
                  custom_id = "1234"
                })
            end)

            local now        = time()
            local minute     = now - (now % 60)
            local route_id   = utils.uuid()
            local service_id = utils.uuid()

            local test_status_code_data = {
              { consumer.id, route_id, service_id, "404", tostring(now), "1", 4 },
              { consumer.id, route_id, service_id, "404", tostring(now - 1), "1", 2 },
              { consumer.id, route_id, service_id, "500", tostring(minute), "60", 5 },
            }

            assert(strategy:insert_status_codes_by_consumer_and_route(test_status_code_data))

            local res = assert(client:send {
              methd = "GET",
              path = "/vitals/status_codes/by_consumer",
              query = {
                interval    = "seconds",
                consumer_id = consumer.id,
              }
            })

            res = assert.res_status(200, res)
            local json = cjson.decode(res)

            local expected = {
              meta = {
                entity_type = "consumer",
                entity_id   = consumer.id,
                earliest_ts = now - 1,
                interval    = "seconds",
                latest_ts   = now,
                level       = "cluster",
                stat_labels = {
                  "status_codes_per_consumer_total",
                },
              },
              stats = {
                cluster = {
                  [tostring(now - 1)] = {
                    ["404"] = 2,

                  },
                  [tostring(now)] = {
                    ["404"] = 4,
                  },
                }
              }
            }

            assert.same(expected, json)
          end)

          it("retrieves the minutes-level response code data for a given consumer", function()
            local consumer
            helpers.with_current_ws(
              dao.workspaces:find_all({name = "default"}),
              function()
                consumer = assert(dao.consumers:insert {
                  username  = "bob",
                  custom_id = "1234"
                })
            end)

            local minute_start_at = time() - (time() % 60)
            local route_id        = utils.uuid()
            local service_id      = utils.uuid()

            local test_status_code_data = {
              { consumer.id, route_id, service_id, "404", tostring(minute_start_at), "60", 101},
              { consumer.id, route_id, service_id, "200", tostring(minute_start_at - 60), "60", 205},
              { consumer.id, route_id, service_id, "500", tostring(minute_start_at - 60), "60", 6},
            }

            assert(strategy:insert_status_codes_by_consumer_and_route(test_status_code_data))

            local res = assert(client:send {
              methd = "GET",
              path = "/vitals/status_codes/by_consumer",
              query = {
                interval = "minutes",
                consumer_id = consumer.id,
              }
            })
            res = assert.res_status(200, res)
            local json = cjson.decode(res)

            local expected = {
              meta = {
                entity_type = "consumer",
                entity_id   = consumer.id,
                earliest_ts = minute_start_at - 60,
                interval    = "minutes",
                latest_ts   = minute_start_at,
                level       = "cluster",
                stat_labels = {
                  "status_codes_per_consumer_total",
                },
              },
              stats = {
                cluster = {
                  [tostring(minute_start_at - 60)] = {
                    ["200"] = 205,
                    ["500"] = 6,
                  },
                  [tostring(minute_start_at)] = {
                    ["404"] = 101,
                  },
                }
              }
            }

            assert.same(expected, json)
          end)

          it("returns a 400 if called with invalid interval", function()
            local consumer
            helpers.with_current_ws(
              dao.workspaces:find_all({name = "default"}),
              function()
                consumer = assert(dao.consumers:insert {
                  username  = "bob",
                  custom_id = "1234"
                })
            end)

            local res = assert(client:send {
              methd = "GET",
              path = "/vitals/status_codes/by_consumer",
              query = {
                interval = "so-wrong",
                consumer_id = consumer.id,
              }
            })
            res = assert.res_status(400, res)
            local json = cjson.decode(res)

            assert.same("Invalid query params: interval must be 'minutes' or 'seconds'", json.message)
          end)

          it("returns a 400 if called with invalid start_ts", function()
            local consumer = assert(dao.consumers:insert {
              username  = "bob",
              custom_id = "1234"
            })

            local res = assert(client:send {
              methd = "GET",
              path = "/vitals/status_codes/by_consumer",
              query = {
                interval = "seconds",
                consumer_id = consumer.id,
                start_ts = "foo",
              }
            })
            res = assert.res_status(400, res)
            local json = cjson.decode(res)

            assert.same("Invalid query params: start_ts must be a number", json.message)
          end)

          it("returns a 404 if called with invalid consumer_id", function()
            local consumer_id = "shh.. I'm not a real consumer id"
            local res = assert(client:send {
              methd = "GET",
              path = "/vitals/status_codes/by_consumer",
              query = {
                interval = "minutes",
                consumer_id = consumer_id,
              }
            })
            res = assert.res_status(404, res)
            local json = cjson.decode(res)

            assert.same("Not found", json.message)
          end)

          it("returns a 404 if called with no consumer_id", function()
            local res = assert(client:send {
              methd = "GET",
              path = "/vitals/status_codes/by_consumer",
              query = {
                interval = "minutes",
              }
            })
            res = assert.res_status(404, res)
            local json = cjson.decode(res)

            assert.same("Not found", json.message)
          end)

          it("returns a 404 if called with a consumer_id that is not an actual id for a consumer", function()
            local consumer_id = "20426633-55dc-4050-89ef-2382c95a611a"
            local res = assert(client:send {
              methd = "GET",
              path = "/vitals/status_codes/by_consumer",
              query = {
                interval = "minutes",
                consumer_id = consumer_id,
              }
            })
            res = assert.res_status(404, res)
            local json = cjson.decode(res)

            assert.same("Not found", json.message)
          end)
        end)
      end)

      describe("/vitals/status_codes/by_consumer_and_route", function()
        before_each(function()
          dao.db:truncate_table("consumers")
          dao.db:truncate_table("routes")
          dao.db:truncate_table("vitals_codes_by_consumer_route")
        end)

        describe("GET", function()
          it("retrieves the seconds-level response code data for a given consumer", function()
            local consumer, route
            helpers.with_current_ws(
              dao.workspaces:find_all({name = "default"}),
              function()
                consumer = assert(dao.consumers:insert {
                  username  = "bob",
                  custom_id = "1234"
                })
                route = bp.routes:insert({ paths = { "/my-route" } })
            end)

            local route_id = route.id

            local now        = time()
            local minute     = now - (now % 60)
            local service_id = utils.uuid()

            local test_status_code_data = {
              { consumer.id, route_id, service_id, "404", tostring(now), "1", 4 },
              { consumer.id, route_id, service_id, "404", tostring(now - 1), "1", 2 },
              { consumer.id, route_id, service_id, "500", tostring(minute), "60", 5 },
            }

            assert(strategy:insert_status_codes_by_consumer_and_route(test_status_code_data))

            local res = assert(client:send {
              methd = "GET",
              path = "/vitals/status_codes/by_consumer_and_route",
              query = {
                interval    = "seconds",
                consumer_id = consumer.id,
              }
            })

            res = assert.res_status(200, res)
            local json = cjson.decode(res)

            local expected = {
              meta = {
                entity_type = "consumer_route",
                entity_id   = consumer.id,
                earliest_ts = now - 1,
                interval    = "seconds",
                latest_ts   = now,
                level       = "cluster",
                stat_labels = {
                  "status_codes_per_consumer_route_total",
                },
              },
              stats = {
                [route_id] = {
                  [tostring(now - 1)] = {
                    ["404"] = 2,

                  },
                  [tostring(now)] = {
                    ["404"] = 4,
                  },
                }
              }
            }

            assert.same(expected, json)
          end)

          it("retrieves the minutes-level response code data for a given consumer", function()
            local consumer, route
            helpers.with_current_ws(
              dao.workspaces:find_all({name = "default"}),
              function()
                consumer = assert(dao.consumers:insert {
                  username  = "bob",
                  custom_id = "1234"
                })
                route = bp.routes:insert({ paths = { "/my-route" } })
            end)


            local route_id = route.id

            local minute_start_at = time() - (time() % 60)
            local service_id      = utils.uuid()

            local test_status_code_data = {
              { consumer.id, route_id, service_id, "404", tostring(minute_start_at), "60", 101},
              { consumer.id, route_id, service_id, "200", tostring(minute_start_at - 60), "60", 205},
              { consumer.id, route_id, service_id, "500", tostring(minute_start_at - 60), "60", 6},
            }

            assert(strategy:insert_status_codes_by_consumer_and_route(test_status_code_data))

            local res = assert(client:send {
              methd = "GET",
              path = "/vitals/status_codes/by_consumer_and_route",
              query = {
                interval = "minutes",
                consumer_id = consumer.id,
              }
            })
            res = assert.res_status(200, res)
            local json = cjson.decode(res)

            local expected = {
              meta = {
                entity_type = "consumer_route",
                entity_id   = consumer.id,
                earliest_ts = minute_start_at - 60,
                interval    = "minutes",
                latest_ts   = minute_start_at,
                level       = "cluster",
                stat_labels = {
                  "status_codes_per_consumer_route_total",
                },
              },
              stats = {
                [route_id] = {
                  [tostring(minute_start_at - 60)] = {
                    ["200"] = 205,
                    ["500"] = 6,
                  },
                  [tostring(minute_start_at)] = {
                    ["404"] = 101,
                  },
                }
              }
            }

            assert.same(expected, json)
          end)

          it("returns a 400 if called with invalid interval", function()
            local consumer
            helpers.with_current_ws(
              dao.workspaces:find_all({name = "default"}),
              function()
                consumer = assert(dao.consumers:insert {
                  username  = "bob",
                  custom_id = "1234"
                })
            end)

            local res = assert(client:send {
              methd = "GET",
              path = "/vitals/status_codes/by_consumer_and_route",
              query = {
                interval = "so-wrong",
                consumer_id = consumer.id,
              }
            })
            res = assert.res_status(400, res)
            local json = cjson.decode(res)

            assert.same("Invalid query params: interval must be 'minutes' or 'seconds'", json.message)
          end)

          it("returns a 400 if called with invalid start_ts", function()
            local consumer = assert(dao.consumers:insert {
              username  = "bob",
              custom_id = "1234"
            })

            local res = assert(client:send {
              methd = "GET",
              path = "/vitals/status_codes/by_consumer_and_route",
              query = {
                interval = "seconds",
                consumer_id = consumer.id,
                start_ts = "foo",
              }
            })
            res = assert.res_status(400, res)
            local json = cjson.decode(res)

            assert.same("Invalid query params: start_ts must be a number", json.message)
          end)

          it("returns a 404 if called with invalid consumer_id", function()
            local consumer_id = "shh.. I'm not a real consumer id"
            local res = assert(client:send {
              methd = "GET",
              path = "/vitals/status_codes/by_consumer_and_route",
              query = {
                interval = "minutes",
                consumer_id = consumer_id,
              }
            })
            res = assert.res_status(404, res)
            local json = cjson.decode(res)

            assert.same("Not found", json.message)
          end)

          it("returns a 404 if called with no consumer_id", function()
            local res = assert(client:send {
              methd = "GET",
              path = "/vitals/status_codes/by_consumer_and_route",
              query = {
                interval = "minutes",
              }
            })
            res = assert.res_status(404, res)
            local json = cjson.decode(res)

            assert.same("Not found", json.message)
          end)

          it("returns a 404 if called with a consumer_id that is not an actual id for a consumer", function()
            local consumer_id = "20426633-55dc-4050-89ef-2382c95a611a"
            local res = assert(client:send {
              methd = "GET",
              path = "/vitals/status_codes/by_consumer_and_route",
              query = {
                interval = "minutes",
                consumer_id = consumer_id,
              }
            })
            res = assert.res_status(404, res)
            local json = cjson.decode(res)

            assert.same("Not found", json.message)
          end)
        end)
      end)

      describe("/vitals/nodes", function()
        describe("GET", function()
          pending("fails intermittently -- retrieves the vitals seconds data for all nodes", function()
            local res = assert(client:send {
              methd = "GET",
              path = "/vitals/nodes",
              query = {
                interval = "seconds"
              }
            })
            res = assert.res_status(200, res)
            local json = cjson.decode(res)

            local expected = {
              meta = {
                level = "node",
                interval = "seconds",
                earliest_ts = minute_start_at,
                latest_ts = minute_start_at + 2,
                stat_labels = stat_labels,
                nodes = {
                  [node_1] = { hostname = "testhostname1" },
                  [node_2] = { hostname = "testhostname2" },
                },
              },
              stats = {
                ["20426633-55dc-4050-89ef-2382c95a611e"] = {
                  [tostring(minute_start_at)] = { 0, 0, cjson.null, cjson.null, cjson.null, cjson.null, 0, 10, 10 },
                  [tostring(minute_start_at + 1)] = { 0, 3, 0, 11, 193, 212, 1, 10, 10 },
                  [tostring(minute_start_at + 2)] = { 3, 4, 1, 8, 60, 9182, 4, 10, 10 },
                },
                ["8374682f-17fd-42cb-b1dc-7694d6f65ba0"] = {
                  [tostring(minute_start_at + 1)] = { 1, 5, 0, 99, 25, 144, 9, 10, 10 },
                  [tostring(minute_start_at + 2)] = { 1, 7, 0, 0, 13, 19, 8, 10, 10 },
                }
              }
            }

            assert.same(expected, json)
          end)

          pending("fails intermittently -- retrieves the vitals minutes data for all nodes", function()
            local res = assert(client:send {
              methd = "GET",
              path = "/vitals/nodes",
              query = {
                interval = "minutes"
              }
            })
            res = assert.res_status(200, res)
            local json = cjson.decode(res)

            local expected = {
              meta = {
                level = "node",
                interval = "minutes",
                earliest_ts = minute_start_at,
                latest_ts = minute_start_at,
                stat_labels = stat_labels,
                nodes = {
                  [node_1] = { hostname = "testhostname1" },
                  [node_2] = { hostname = "testhostname2" },
                },
              },
              stats = {
                [node_1] = {
                  [tostring(minute_start_at)] = { 3, 7, 0, 11, 60, 9182, 5, 10, 10 }
                },
                [node_2] = {
                  [tostring(minute_start_at)] = { 2, 12, 0, 99, 13, 144, 17, 10, 10 }
                }
              }
            }

            assert.same(expected, json)
          end)

          it("returns a 400 if called with invalid interval", function()
            local res = assert(client:send {
              methd = "GET",
              path = "/vitals/nodes",
              query = {
                interval = "so-wrong"
              }
            })
            res = assert.res_status(400, res)
            local json = cjson.decode(res)

            assert.same("Invalid query params: interval must be 'minutes' or 'seconds'", json.message)
          end)

          it("returns a 400 if called with invalid start_ts", function()
            local res = assert(client:send {
              methd = "GET",
              path = "/vitals/nodes",
              query = {
                interval = "seconds",
                start_ts = "foo",
              }
            })
            res = assert.res_status(400, res)
            local json = cjson.decode(res)

            assert.same("Invalid query params: start_ts must be a number", json.message)
          end)
        end)
      end)

      describe("/vitals/nodes/{node_id}", function()
        describe("GET", function()
          it("retrieves the vitals seconds data for a requested node", function()
            local res = assert(client:send {
              methd = "GET",
              path = "/vitals/nodes/" .. node_1,
              query = {
                interval = "seconds"
              }
            })
            res = assert.res_status(200, res)
            local json = cjson.decode(res)

            local expected = {
              meta = {
                level = "node",
                interval = "seconds",
                interval_width = 1,
                earliest_ts = minute_start_at,
                latest_ts = minute_start_at + 2,
                stat_labels = stat_labels,
                nodes = {
                  [node_1] = { hostname = "testhostname1"}
                }
              },
              stats = {
                [node_1] = {
                  [tostring(minute_start_at)] = { 0, 0, cjson.null, cjson.null, cjson.null, cjson.null, 0, 10, 10 },
                  [tostring(minute_start_at + 1)] = { 0, 3, 0, 11, 193, 212, 1, 10, 10 },
                  [tostring(minute_start_at + 2)] = { 3, 4, 1, 8, 60, 9182, 4, 10, 10 },
                },
              }
            }

            assert.same(expected, json)
          end)

          it("retrieves the vitals minutes data for a requested node", function()
            local res = assert(client:send {
              methd = "GET",
              path = "/vitals/nodes/" .. node_1,
              query = {
                interval = "minutes"
              }
            })
            res = assert.res_status(200, res)
            local json = cjson.decode(res)

            local expected = {
              stats = {
                [node_1] = {
                  [tostring(minute_start_at)] = { 3, 7, 0, 11, 60, 9182, 5, 10, 10 }
                }
              },
              meta = {
                level = "node",
                interval = "minutes",
                interval_width = 60,
                earliest_ts = minute_start_at,
                latest_ts = minute_start_at,
                stat_labels = stat_labels,
                nodes = {
                  [node_1] = { hostname = "testhostname1"}
                }
              }
            }

            assert.same(expected, json)
          end)

          it("returns empty stats if the requested node hasn't reported data", function()
            local res = assert(client:send {
              methd = "GET",
              path = "/vitals/nodes/" .. node_3,
              query = {
                interval = "minutes"
              }
            })
            res = assert.res_status(200, res)
            local json = cjson.decode(res)

            local expected = {
              meta = {
                level = "node",
                interval = "minutes",
                interval_width = 60,
              },
              stats = {},
            }

            assert.same(expected, json)
          end)

          it("returns a 400 if called with invalid interval", function()
            local res = assert(client:send {
              methd = "GET",
              path = "/vitals/nodes/" .. node_1,
              query = {
                wrong_query_key = "seconds"
              }
            })
            res = assert.res_status(400, res)
            local json = cjson.decode(res)

            assert.same("Invalid query params: interval must be 'minutes' or 'seconds'", json.message)
          end)

          it("returns a 400 if called with invalid start_ts", function()
            local res = assert(client:send {
              methd = "GET",
              path = "/vitals/nodes/" .. node_1,
              query = {
                interval = "seconds",
                start_ts = "foo",
              }
            })
            res = assert.res_status(400, res)
            local json = cjson.decode(res)

            assert.same("Invalid query params: start_ts must be a number", json.message)
          end)

          it("returns a 404 if the node_id is not valid", function()
            local res = assert(client:send {
              methd = "GET",
              path = "/vitals/nodes/totally-fake-uuid",
              query = {
                interval = "seconds"
              }
            })
            res = assert.res_status(404, res)
            local json = cjson.decode(res)

            assert.same("Not found", json.message)
          end)

          it("returns a 404 if the node_id does not exist", function()
            local res = assert(client:send {
              methd = "GET",
              path = "/vitals/nodes/" .. utils.uuid(),
              query = {
                interval = "seconds"
              }
            })
            res = assert.res_status(404, res)
            local json = cjson.decode(res)

            assert.same("Not found", json.message)
          end)
        end)
      end)

      describe("/vitals/consumers/{username_or_id}/cluster", function()
        before_each(function()
          dao.db:truncate_table("consumers")
          dao.db:truncate_table("vitals_consumers")
          dao.db:truncate_table("vitals_codes_by_consumer_route")
        end)

        describe("GET", function()
          it("retrieves consumer stats (seconds)", function()
            local consumer = assert(dao.consumers:insert {
              username = "bob",
              custom_id = "1234"
            })

            local now = time()

            if dao.db_type == "cassandra" then
              assert(strategy:insert_consumer_stats({
                -- inserting minute and second data, but only expecting second data in response
                { consumer.id, now, 60, 45 },
                { consumer.id, now, 1, 17 }
              }, utils.uuid()))
            else
              assert(strategy:insert_status_codes_by_consumer_and_route({
                -- inserting minute and second data, but only expecting second data in response
                { consumer.id, utils.uuid(), utils.uuid(), "200", now, 60, 45 },
                { consumer.id, utils.uuid(), utils.uuid(), "200", now, 1, 17 }
              }))
            end

            local res = assert(client:send {
              methd = "GET",
              path = "/vitals/consumers/" .. consumer.id .. "/cluster",
              query = {
                interval = "seconds"
              }
            })

            res = assert.res_status(200, res)
            local json = cjson.decode(res)

            local expected =  {
              meta = {
                level = "cluster",
                interval = "seconds",
                earliest_ts = now,
                latest_ts = now,
                stat_labels = consumer_stat_labels,
              },
              stats = {
                cluster = {
                  [tostring(now)] = 17
                }
              }
            }

            assert.same(expected, json)
          end)

          it("returns a 404 if called with invalid consumer_id path param", function()
            local res = assert(client:send {
              methd = "GET",
              path = "/vitals/consumers/fake-uuid/cluster",
              query = {
                interval = "seconds"
              }
            })
            res = assert.res_status(404, res)
            local json = cjson.decode(res)

            assert.same("Not found", json.message)
          end)

          it("returns a 400 if called with invalid interval", function()
            local consumer
            helpers.with_current_ws(
              dao.workspaces:find_all({name = "default"}),
              function()
                consumer = assert(dao.consumers:insert {
                  username = "bob",
                  custom_id = "1234"
                })
            end)

            local res = assert(client:send {
              methd = "GET",
              path = "/vitals/consumers/" .. consumer.id .. "/cluster",
              query = {
                wrong_query_key = "seconds"
              }
            })
            res = assert.res_status(400, res)
            local json = cjson.decode(res)

            assert.same("Invalid query params: consumer_id, duration, and level are required", json.message)
          end)

          it("returns a 400 if called with invalid start_ts", function()
            local consumer = assert(dao.consumers:insert {
              username = "bob",
              custom_id = "1234"
            })

            local res = assert(client:send {
              methd = "GET",
              path = "/vitals/consumers/" .. consumer.id .. "/cluster",
              query = {
                interval = "seconds",
                start_ts = "foo"
              }
            })
            res = assert.res_status(400, res)
            local json = cjson.decode(res)

            assert.same("Invalid query params: start_ts must be a number", json.message)
          end)
        end)
      end)
    end)

    describe("when vitals is not enabled", function()
      setup(function()
        bp, _, dao = helpers.get_db_utils(kong_conf.database)

        assert(helpers.start_kong({
          database = kong_conf.database,
          vitals   = false,
        }))

        client = helpers.admin_client()
      end)

      teardown(function()
        if client then
          client:close()
        end

        helpers.stop_kong()
      end)

      describe("GET", function()

        it("responds 404", function()
          local res = assert(client:send {
            methd = "GET",
            path = "/vitals"
          })
          assert.res_status(404, res)
        end)
      end)
    end)
  end)

end)
