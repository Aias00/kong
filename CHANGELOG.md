## v0.1.3

- Add `config.extra_jwks_uris`
- Fix set headers when callback to get header value failed
- Rediscovery of JWKS is now cached
- Admin API self-check discovery

## v0.1.2

This release adds option that allows e.g. rate-limiting by arbitrary claim:

- Add `config.credential_claim`

## v0.1.1

- Bearer token is now looked up on `Access-Token` and `X-Access-Token` headers
  too.

## v0.1.0

This release only fixes some bugs in 0.0.9.

- Fix `exp` retrival
- Fix `jwt_session_cookie` verification
- Fix consumer mapping using introspection

## v0.0.9

With this release the whole code base got refactored and a lot of
new features were added. We also made the code a lot more robust.

This release deprecates:
- OpenID Connect Authentication Plugin
- OpenID Connect Protection Plugin
- OpenID Connect Verification Plugin

This release removes:
- Remove multipart parsing of id tokens (it was never proxy safe)

This release adds:
- Add `config.session_storage`
- Add `config.session_memcache_prefix`
- Add `config.session_memcache_socket`
- Add `config.session_memcache_host`
- Add `config.session_memcache_port`
- Add `config.session_redis_prefix`
- Add `config.session_redis_socket`
- Add `config.session_redis_host`
- Add `config.session_redis_port`
- Add `config.session_redis_auth`
- Add `config.session_cookie_lifetime`
- Add `config.authorization_cookie_lifetime`
- Add `config.forbidden_destroy_session`
- Add `config.forbidden_redirect_uri`
- Add `config.unauthorized_redirect_uri`
- Add `config.unexpected_redirect_uri`
- Add `config.scopes_required`
- Add `config.scopes_claim`
- Add `config.audience_required`
- Add `config.audience_claim`
- Add `config.discovery_headers_names`
- Add `config.discovery_headers_values`
- Add `config.introspection_hint`
- Add `config.introspection_headers_names`
- Add `config.introspection_headers_values`
- Add `config.token_exchange_endpoint`
- Add `config.cache_token_exchange`
- Add `config.bearer_token_param_type`
- Add `config.client_credentials_param_type`
- Add `config.password_param_type`
- Add `config.hide_credentials`
- Add `config.cache_ttl`
- Add `config.run_on_preflight`
- Add `config.upstream_headers_claims`
- Add `config.upstream_headers_names`
- Add `config.downstream_headers_claims`
- Add `config.downstream_headers_names`

## v0.0.8

NOTE: the way `config.anonymous` has changed in this release is a **BREAKING**
change **AND** can lead to **UNAUTHORIZED** access if old behavior was used.
Please use `acl` or `request-termination` plugins to restrict `anonymous`
access. The change was made so that that this plugin follows similar patterns
as other Kong Authentication plugins regarding to `config.anonymous`.

- In case of auth plugins concatenation, the OpenID Connect plugin now
  removes remnants of anonymous
- Fixed anonymous consumer mapping
- Anonymous consumer uses now a simple cache key that is used in other plugins
- `config.anonymous` now behaves similarly to other plugins and doesn't halt
  execution or proxying (previously it was used just as a fallback for consumer
  mapping) and the plugin always needed valid credentials to be allowed to proxy
  if the client wasn't already authenticated by higher priority auth plugin.
- Change if `anonymous` consumer is not found we return internal server error
  instead of forbidden
- Change `config.client_id` from `required` to `optional`
- Change `config.client_secret` from `required` to `optional`

## v0.0.7

- Fixed authorization code flow client selection

## v0.0.6

- Updated .VERSION property of all the plugins (sorry, forgot that in 0.0.5)

## v0.0.5

- Implement logout with optional revocation and rp initiated logout
- Implement passing dynamic arguments to authorization endpoint from client
- Add `config.authorization_query_args_client`
- Add `config.client_arg` configuration parameter
- Add `config.logout_redirect_uri`
- Add `config.logout_query_arg`
- Add `config.logout_post_arg`
- Add `config.logout_uri_suffix`
- Add `config.logout_methods`
- Add `config.logout_revoke`
- Add `config.revocation_endpoint`
- Add `config.end_session_endpoint`
- Change `config.login_redirect_uri` from `string` to `array`

## v0.0.4

- Add changelog
- Add config.login_redirect_mode configuration option
- Fix invalid re-verify to cleanup existing session
- Update docs with removal of non-accessible uris
- Update .rockspec with new homepage and repository link

## v0.0.3

- First tagged release
