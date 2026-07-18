# flutter_api_bridge

A production transport runtime for generated Dart and Flutter API packages.

It provides connection-scoped Dio clients, browser-like persistent cookies,
secure bearer persistence, structured logging, safe retries, and
session-partitioned Hive caching with offline fallback metadata.

## Generated-package usage

Applications should normally depend on and import only their generated API
package. The generated package depends directly on `flutter_api_bridge` and
exposes the safe runtime configuration and session methods.

```text
Flutter application
  -> generated riderescue_api package
    -> flutter_api_bridge
      -> Dio / cookies / secure auth / Hive / retries
```

## Direct bridge configuration

```dart
await FlutterApiBridge.configure(
  key: 'riderescue_api',
  config: ApiBridgeConfig(
    baseUri: Uri.parse('https://api.example.com'),
    auth: const CookieStrategy(
      sessionCookieNames: <String>['refresh_token'],
    ),
    cookiesEnabled: true,
    cache: const ApiCacheConfig(
      defaultPolicy: ApiCachePolicy.networkFirst,
      defaultTtl: Duration(minutes: 5),
    ),
    retry: const ApiRetryConfig(maxAttempts: 3),
    logging: const ApiLoggingConfig(
      level: ApiLoggingLevel.basic,
      showDuration: true,
      showRequestId: false,
      prettyPrintBodies: true,
    ),
    clientIdentity: () => const ApiClientIdentity(
      applicationName: 'RiderescueDriver',
      applicationVersion: '2.4.1',
      platform: 'android',
    ),
  ),
);
```

## User/cache session initialization

After a generated login operation succeeds, initialize the user session. The
session ID partitions all cached data. Changing the session ID clears the
previous active session by default to prevent cross-account data leakage.

Cookie-backed login:

```dart
await connection.initializeUserSession(
  sessionId: account.id,
  metadata: <String, Object?>{
    'companyId': account.companyId,
    'role': account.role,
  },
);
```

Bearer-backed login:

```dart
await connection.initializeUserSession(
  sessionId: account.id,
  bearerToken: login.accessToken,
);
```

Manual authorization headers:

```dart
await connection.initializeUserSession(
  sessionId: account.id,
  authHeaders: <String, String>{
    'Authorization': 'Custom ${login.credential}',
  },
);
```

Bearer credentials and manual session headers are restored from secure
platform storage. Cookie sessions are restored from the real persistent cookie
jar, not from marker flags.

## Cache controls

Every generated GET accepts `ApiGetRequestOptions`:

```dart
const ApiGetRequestOptions(
  cache: false,
);

const ApiGetRequestOptions(
  forceRefresh: true,
);

const ApiGetRequestOptions(
  cachePolicy: ApiCachePolicy.networkWithStaleFallback,
  cacheTtl: Duration(minutes: 15),
  cacheTags: <String>['bookings'],
);
```

Supported policies:

- `disabled`
- `cacheFirst`
- `networkFirst`
- `cacheOnly`
- `refresh`
- `networkWithStaleFallback`

The result reports its source:

```dart
switch (result.metadata?.source) {
  case ApiDataSource.network:
    break;
  case ApiDataSource.memoryCache:
  case ApiDataSource.hiveCache:
  case ApiDataSource.staleCache:
    // The UI may show cached/offline state.
    break;
  case null:
    break;
}
```

Explicit clearing:

```dart
await connection.clearActiveSessionCache();
await connection.clearSessionCache('user-42');
await connection.clearAllCache();
```

`logout()` clears the complete connection cache, credentials, and cookies.

## Per-request overrides

All requests accept common options for:

- custom headers;
- request-only cookie overrides;
- no-auth operations;
- cancellation;
- retry control;
- idempotency keys;
- cache tag/path invalidation;
- operation IDs for diagnostics.
- client-only per-call logging controls.

```dart
const ApiRequestOptions(
  headers: <String, String>{'X-Tenant': 'company-7'},
  cookies: <String, String>{'preview': 'enabled'},
  idempotencyKey: 'booking-create-123',
  log: ApiCallLogOptions(enabled: false),
);
```

Cookie overrides apply to that request only. Normal backend `Set-Cookie`
responses are captured and persisted automatically by Dio's cookie manager.

## Retry safety

The bridge retries safe reads and selected timeout/408/425/429/5xx failures
with exponential backoff, jitter, and `Retry-After` support. Unsafe mutations
are not retried unless an idempotency key is present or the caller explicitly
sets `retryUnsafeRequest`.

401 and 403 are never handled as normal retries. Token or cookie refresh
endpoint orchestration remains the generated package or application's concern.

## Logging

The default logger emits compact, production-friendly summaries. Request and
response bodies, headers, query parameters, cookies, complete request IDs,
session IDs, and stack traces are not printed by default.

```text
REQ: user_auth.getCurrentAuthBootstrap · GET · /v1/user/auth/bootstrap
  ↳ attempt=1
RES: user_auth.getCurrentAuthBootstrap · GET · /v1/user/auth/bootstrap · 200 · 184ms
  ↳ source=network
ERR: booking.createBooking · POST · /v1/bookings · 422 · 197ms
  ↳ code=validation_failed · message="Vehicle is required"
RETRY: user_auth.refreshSession · attempt 2/3 · in 800ms
  ↳ reason=connection_timeout
CACHE: jobs.listAvailableJobs · hit
  ↳ source=disk · age=42s
AUTH: authenticated
  ↳ reason=credentials_restored
```

### Global configuration

`ApiLoggingLevel` controls package verbosity:

- `none`: no package logs;
- `errors`: terminal request and important authentication failures only;
- `basic`: concise request, response, error, retry, cache, and auth events;
- `detailed`: basic events plus metadata explicitly enabled below.

```dart
const ApiLoggingConfig(
  level: ApiLoggingLevel.detailed,
  logRequestHeaders: false,
  logRequestBody: false,
  logResponseHeaders: false,
  logResponseBody: false,
  logQueryParameters: false,
  logCookies: false,
  showDuration: true,
  showRequestId: false,
  prettyPrintBodies: true,
  useAnsi: false,
);
```

`enabled: false` remains supported for compatibility. Prefer
`level: ApiLoggingLevel.none` in new code. `ApiLogLevel` remains the severity
attached to a structured event; it is separate from `ApiLoggingLevel`.

### Per-operation debugging

`ApiCallLogOptions` is immutable and stored only in `ApiRequestOptions`. The
shared caller reads it locally; it is never serialized into headers, query
parameters, request bodies, cookies, or DTOs.

```dart
const options = ApiRequestOptions(
  log: ApiCallLogOptions(
    requestBody: true,
    responseBody: true,
  ),
);
```

Disable one operation without changing global configuration:

```dart
const options = ApiRequestOptions(
  log: ApiCallLogOptions(enabled: false),
);
```

Generated packages should expose `ApiCallLogOptions? log` on each operation
and forward it into request options. Existing generated calls remain valid
because the argument is optional. Generator/template integration is tracked in
[issue #15](https://github.com/alidantech-org/flutter_api_bridge/issues/15);
this runtime repository intentionally does not patch generated operations.

### Redaction guarantees

Mandatory centralized redaction runs before every logger callback, including
custom sinks. Explicit body/header/cookie flags never bypass it. Matching is
case-insensitive across snake_case, kebab-case, and camelCase variants and
includes passwords, tokens, authorization, cookies, secrets, API keys, OTPs,
PINs, credentials, and signed URL parameters.

The redactor also:

- truncates long strings and large collections;
- limits recursive depth and detects cycles;
- strips URL user information and redacts sensitive query parameters;
- summarizes binary data and streams;
- reports multipart file counts and sizes without reading or printing bytes;
- prevents redaction or logger failures from affecting API requests.

Production applications should use `basic` or `errors`. Enable bodies only for
the smallest possible scope and disable them again after diagnosis.

### Custom sinks

The runtime emits typed `ApiRequestLogEvent`, `ApiResponseLogEvent`,
`ApiErrorLogEvent`, `ApiRetryLogEvent`, `ApiCacheLogEvent`, and
`ApiAuthLogEvent` values through the existing `ApiLogger` abstraction.

```dart
class AppApiLogger implements ApiLogger {
  const AppApiLogger();

  @override
  void log(ApiLogEvent event) {
    // Metadata has already passed mandatory redaction.
    // Forward it to logging, logger, Crashlytics, Sentry, or another sink.
  }
}
```

For callback-style integrations, use `CallbackApiLogger`. The default
`DeveloperApiLogger` uses `ApiLogFormatter`; consumers can also format events
directly with the formatter. ANSI output is off by default.

## Legacy `Server`

`Server.init()` remains as a default-connection compatibility wrapper. New
generated packages should use their own stable `FlutterApiBridge` connection
key so multiple APIs and environments cannot collide.
