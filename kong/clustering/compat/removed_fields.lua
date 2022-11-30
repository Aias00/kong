-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]


return {
  -- Any dataplane older than 3.1.0
  [3001000000] = {
    -- OSS
    acme = {
      "enable_ipv4_common_name",
      "storage_config.redis.ssl",
      "storage_config.redis.ssl_verify",
      "storage_config.redis.ssl_server_name",
    },
    rate_limiting = {
      "error_code",
      "error_message",
    },
    response_ratelimiting = {
      "redis_ssl",
      "redis_ssl_verify",
      "redis_server_name",
    },
    datadog = {
      "retry_count",
      "queue_size",
      "flush_timeout",
    },
    statsd = {
      "retry_count",
      "queue_size",
      "flush_timeout",
    },
    session = {
      "cookie_persistent",
    },
    zipkin = {
      "http_response_header_for_traceid",
    },

    -- Enterprise plugins
    mocking = {
      "included_status_codes",
      "random_status_code",
    },
    opa = {
      "include_uri_captures_in_opa_input",
    },
    forward_proxy = {
      "x_headers",
    },
    rate_limiting_advanced = {
      "disable_penalty",
      "error_code",
      "error_message",
    },
    mtls_auth = {
      "allow_partial_chain",
      "send_ca_dn",
    },
    request_transformer_advanced = {
      "dots_in_keys",
      "add.json_types",
      "append.json_types",
      "replace.json_types",
    },
    route_transformer_advanced = {
      "escape_path",
    },
  },
}
