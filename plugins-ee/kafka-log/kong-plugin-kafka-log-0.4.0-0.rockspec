package = "kong-plugin-kafka-log"
version = "0.4.0-0"
source = {
   url = "git://github.com/kong/kong-plugin-kafka-log",
   tag = "0.4.0"
}
description = {
   summary = "This plugin sends request and response logs to Kafka.",
   homepage = "https://github.com/kong/kong-plugin-kafka-log",
}
dependencies = {
   "lua >= 5.1",
   "kong-lua-resty-kafka >= 0.13"
}
build = {
   type = "builtin",
   modules = {
      ["kong.plugins.kafka-log.handler"] = "kong/plugins/kafka-log/handler.lua",
      ["kong.plugins.kafka-log.schema"] = "kong/plugins/kafka-log/schema.lua",
   }
}
