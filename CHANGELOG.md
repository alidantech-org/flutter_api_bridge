# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-07-18

### Added

- Named, connection-scoped API runtimes for generated Dart packages.
- Browser-like persistent cookies using Dio cookie manager and persistent jars.
- Secure bearer-token and manual authorization-header persistence.
- User/cache session initialization with session-partitioned Hive storage.
- Network, memory-cache, Hive-cache, stale-cache, and offline-fallback result metadata.
- Cache policies, force refresh, cache disable, TTLs, tags, path invalidation, and LRU limits.
- Safe retry policies with exponential backoff, jitter, `Retry-After`, cancellation, and idempotency controls.
- Structured logging with request IDs, operation IDs, attempts, cache/retry events, durations, and recursive secret redaction.
- Caller-provided user-agent and client identity metadata.
- Per-request custom headers, request-only cookie overrides, cancellation, and invalidation controls.

### Changed

- Cookie authentication now restores from the actual persisted cookie jar instead of separate presence markers.
- `Server` is now a compatibility facade over the default named connection.
- Riverpod compatibility providers and uploads execute through the same production runtime.
- Logout clears the full connection cache, credentials, and persistent cookies.

## [0.1.0] - 2026-05-23

### Added

- Initial release of flutter_api_bridge.
- Lightweight and extensible HTTP client wrapper for Dart and Flutter.
- Built-in cookie management using `dio_cookie_manager` and `cookie_jar`.
- State management with `flutter_riverpod`.
- Local data persistence using `hive_flutter`.
- Automatic request caching.
- Request interceptor support via `dio`.
- Cookie jar storage and persistence.
- Upload progress tracking.
- Authentication strategy support.
- API request options customization.
- API envelope for structured responses.
# Unreleased

- Added compact structured `REQ`, `RES`, `ERR`, `RETRY`, `CACHE`, and `AUTH`
  logging with total operation durations and network/cache source metadata.
- Added `ApiLoggingLevel`, immutable `ApiCallLogOptions`, typed log event
  subclasses, callback logger support, and configurable body formatting.
- Added mandatory bounded redaction before custom logger callbacks, including
  nested credentials, signed URLs, multipart uploads, binary data, streams,
  long values, and cyclic objects.
- Added client-only per-request logging options without changing transport,
  serialization, cache, retry, cookie, or authentication semantics.
- Preserved legacy `ApiLoggingConfig.enabled`, logging booleans, `ApiLogLevel`,
  `ApiLogEvent`, and `ApiLogger` compatibility.
