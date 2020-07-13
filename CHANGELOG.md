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
