# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
