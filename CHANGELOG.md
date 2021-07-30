## Unreleased

- fix(schema) add a "local" strategy

## 1.4.4

- fix(*) sync counters in all nodes after CRUD events (hybrid/traditional) (FTI-2426)

## 1.4.3

- fix(handler) event hooks registration should be in init_worker
- Merge pull request #67 from Kong/tests/travis-docker-hub-transition
- tests(*) travis docker hub transition

## 1.4.2

- fix(*) BasePlugin inheritance removal (FT-1701)

## 1.4.1

- fix(rla) do not pre-create namespaces on init-worker
- feature(conf) disallow decimal values between 0,1 in sync_rate [FT-928]

## 1.4.0

- Add a jitter (random delay) to the Retry-After header of denied requests (status = 429) in order to (help) prevent all the clients to come back at the same time

## 1.3.8

- add copyright
- add dbless integration testing
- switch to Pongo

## 1.3.7

- feat(handler) add RateLimit headers for draft RFC (FTI-1447)

## 1.3.6

- fix(handler) Corrected service ID lookup (FTI-1704) (#49)

## 1.3.5

- chore(*) use each_by_name instead of select_all (#47)

## 1.3.4

### Fixed

- Fix namespace field defaulting to nil.

### Added

- Emit a rate-limit-exceeded event-hooks event

## 1.3.3

### Fixed
- Make plugin initialization safe if the database is not present during worker startup

## 1.3.2

### Fixed

- Fix issue preventing the plugin to be imported into the Kong database (db_import)

## 1.3.1

### Changed

- Use the Kong PDK instead of the Nginx API

## 1.2.1

### Added

- Add rate limits by an arbitrary header

## 1.1.1

### Added

- Add rate limits by service (global)

## 1.0.1

### Fixed

- Fix entity check blocking with the `redis.cluster_addresses` parameter

## 1.0.0

### Changed

- Convert to new dao
- Use PDK

## 0.31.4

### Changed
 - Internal improvements

## 0.31.3

### Fixed

- Fix issue preventing the plugin to load configuration and create sync timers
- Fix issue preventing the plugin to correctly propagate configuration changes
among Kong Nginx workers

## 0.31.2

### Fixed

- Fix a typo in Cassandra migration
- Fix selection of dictionary used for counters

## 0.31.1

### Changed

- The default shared dictionary for storing RL counters is now
  `kong_rate_limiting_counters` - which is also used by Kong CE rate-limiting

### Added

## 0.31.0

- Plugin was moved out of Kong Enterprise core into its own repository
