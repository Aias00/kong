package = "kong-plugin-enterprise-rate-limiting"
version = "1.6.0-0"

source = {
  url = "https://github.com/Kong/kong-plugin-enterprise-rate-limiting",
  tag = "1.6.0"
}

supported_platforms = {"linux", "macosx"}
description = {
  summary = "Kong Enterprise Rate Limiting",
}

build = {
  type = "builtin",
  modules = {
    ["kong.plugins.rate-limiting-advanced.handler"] = "kong/plugins/rate-limiting-advanced/handler.lua",
    ["kong.plugins.rate-limiting-advanced.schema"] = "kong/plugins/rate-limiting-advanced/schema.lua",
  }
}
