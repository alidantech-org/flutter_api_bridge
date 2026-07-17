# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0-alpha.1] - 2026-07-17

### Added

- Named, isolated `ApiConnection` instances for generated API packages.
- Bridge-owned `ApiAuth` lifecycle with restoring, authenticated, refreshing, expired, and unauthenticated states.
- Connection-scoped persistent cookie and bearer credential storage.
- Explicit bearer credential establishment after application-level response validation.
- Single-flight authentication refresh with one bounded request retry.
- `ApiRequestOptions.unauthenticated` for login, signup, reset, health, and other public endpoints.
- Configurable structured request, response, authentication, refresh, cache, and parsing logs.
- Recursive redaction for authorization headers, cookies, API keys, passwords, secrets, and token fields.
- Request correlation IDs, duration, retry count, and auth-application metadata.
- Tests for explicit authentication transitions, refresh concurrency, failed refresh cleanup, and log redaction.

### Changed

- A successful endpoint response no longer implies an authenticated bridge session.
- Cookie authentication is derived from actual persisted access and refresh cookies.
- Generated clients can execute typed requests directly without Riverpod or application API wrappers.
- Legacy debug logging no longer records request or response bodies or credential-bearing headers.
- Package version advanced to `0.2.0-alpha.1`.

### Fixed

- Prevented concurrent unauthorized requests from starting duplicate refresh operations.
- Prevented unauthenticated login failures from refreshing or reusing an older session when correctly marked as public.
- Prevented auth-state revision changes when persisted credentials did not actually change.
- Prevented global bearer and cookie storage from leaking authentication across API connections.

## [0.1.0] - 2026-05-23

### Added

- Initial release of flutter_api_bridge
- Lightweight and extensible HTTP client wrapper for Dart and Flutter
- Built-in cookie management using `dio_cookie_manager` and `cookie_jar`
- State management with `flutter_riverpod`
- Local data persistence using `hive_flutter`
- Automatic request caching
- Request interceptor support via `dio`
- Cookie jar storage and persistence
- Upload progress tracking
- Authentication strategy support
- API request options customization
- API envelope for structured responses

### Features

- `ApiClient` - Main HTTP client wrapper
- `ApiCache` - Local caching layer
- `CookieManager` - Automatic cookie handling
- `UploadProvider` - File upload with progress tracking
- `AuthStrategy` - Pluggable authentication
- `ApiEnvelope` - Response envelope for standardized API responses
- `ServerConfig` - Configuration management for API servers