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

```dart
const ApiRequestOptions(
  headers: <String, String>{'X-Tenant': 'company-7'},
  cookies: <String, String>{'preview': 'enabled'},
  idempotencyKey: 'booking-create-123',
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

The bridge emits structured `ApiLogEvent` values with request IDs, operation
IDs, attempt numbers, durations, connection/session metadata, and cache/retry
events. Sensitive headers, cookies, tokens, passwords, secrets, OTP values,
and authentication codes are redacted.

```dart
class AppApiLogger implements ApiLogger {
  const AppApiLogger();

  @override
  void log(ApiLogEvent event) {
    // Forward safe structured events to the application's logger.
  }
}
```

## Legacy `Server`

`Server.init()` remains as a default-connection compatibility wrapper. New
generated packages should use their own stable `FlutterApiBridge` connection
key so multiple APIs and environments cannot collide.
