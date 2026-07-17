# flutter_api_bridge

A reusable Flutter transport layer built on Dio, Riverpod, Hive, persistent cookies, typed requests, and typed API results.

## Responsibility boundary

`flutter_api_bridge` manages HTTP transport, credentials, transport-session state, caching, uploads, cookies, and safe diagnostics.

It does **not** implement application-specific login, registration, refresh, user bootstrap, company selection, or profile endpoints. Those calls belong to generated API clients. After a generated authentication call succeeds, the application explicitly tells the bridge to complete the transport-auth transition.

This prevents login DTOs from being treated as application state and prevents widgets from guessing whether a token or cookie was persisted.

## Initialization

```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Server.init(
    baseUrl: 'https://api.example.com',
    authStrategy: BearerStrategy(tokenKey: 'access_token'),
    logging: const ApiLoggingConfig(
      enabled: true,
      logRequestHeaders: false,
      logRequestBody: false,
      logResponseBody: false,
    ),
  );

  runApp(const MyApp());
}
```

`Server.auth.initialize()` is called during `Server.init`. The restored state is available through `Server.auth.current`.

## Correct login flow

The generated client performs the backend request. The bridge only persists the resulting transport credential and transitions its session after the endpoint reports success.

```dart
final result = await generatedAuth.login(
  email: email,
  password: password,
);

await result.when(
  success: (response, message, statusCode) async {
    if (response == null) return;

    await Server.auth.completeAuthentication(
      credential: response.accessToken,
    );

    // Now load the application's typed account/bootstrap endpoint.
    await accountProvider.bootstrap();
  },
  error: (error, message, statusCode) async {
    // Login failed. Do not alter bridge auth state.
  },
);
```

For an HttpOnly-cookie backend, configure `CookieStrategy` and call `completeAuthentication()` without a credential after the generated login endpoint succeeds:

```dart
await Server.init(
  baseUrl: 'https://api.example.com',
  authStrategy: const CookieStrategy(
    sessionCookieNames: ['refresh_token'],
  ),
);

await Server.auth.completeAuthentication();
```

## Observing auth state

```dart
final subscription = Server.auth.changes.listen((session) {
  switch (session.status) {
    case AuthSessionStatus.initializing:
      break;
    case AuthSessionStatus.anonymous:
      // Show sign-in.
      break;
    case AuthSessionStatus.authenticated:
      // Bootstrap the typed application account.
      break;
    case AuthSessionStatus.refreshing:
      // Keep the current screen while refresh runs.
      break;
    case AuthSessionStatus.expired:
      // Stop authenticated runtime and show sign-in once.
      break;
  }
});
```

A protected request returning HTTP 401 transitions the bridge to `expired` once. Repeated failing requests do not emit repeated expiry transitions or repeated logout loops.

## Refresh flow

Refresh remains an application/generated-client endpoint:

```dart
Server.auth.beginRefresh();

final result = await generatedAuth.refreshSession();
final token = result.dataOrNull?.accessToken;

if (result.isSuccess && token != null) {
  await Server.auth.completeRefresh(credential: token);
} else {
  await Server.auth.expire(reason: 'refresh_failed');
}
```

## Logout

Call the backend logout endpoint first when available, then clear the bridge:

```dart
try {
  await generatedAuth.logout();
} finally {
  await Server.logout();
}
```

Logout clears API cache, transport credentials, and persisted cookies. It does not invent or retain an application user model.

## Structured logging

The default logger uses `dart:developer`. Request and response bodies and request headers are disabled by default.

```dart
await Server.init(
  baseUrl: 'https://api.example.com',
  authStrategy: BearerStrategy(tokenKey: 'access_token'),
  logger: const DeveloperApiLogger(name: 'my_app.api'),
  logging: const ApiLoggingConfig(
    enabled: true,
    logRequestHeaders: false,
    logRequestBody: false,
    logResponseBody: false,
  ),
);
```

Sensitive values are redacted recursively before reaching the logger. Default protected keys include authorization, cookies, passwords, access/refresh/ID tokens, API keys, secrets, OTP values, and authentication codes.

Applications can provide a custom sink:

```dart
class CrashReportingApiLogger implements ApiLogger {
  const CrashReportingApiLogger();

  @override
  void log(ApiLogEvent event) {
    // Forward structured metadata to the selected observability service.
    // Do not reconstruct raw request credentials here.
  }
}
```

## Typed requests

```dart
final result = await ref.read(apiProvider.notifier).send(
  GetRequest<Map<String, dynamic>>(
    endpoint: '/todos/1',
    options: const ApiGetRequestOptions(
      cache: true,
      noAuth: true,
    ),
    fromJson: (json) => Map<String, dynamic>.from(json as Map),
  ),
);
```

Every request returns `ApiResult<T>` and can be handled using `when`, `dataOrNull`, `isSuccess`, and `isError`.

## Uploads

```dart
final result = await ref.read(uploadProvider.notifier).upload(
  UploadRequest<Map<String, dynamic>>(
    endpoint: '/upload',
    files: [UploadFile.fromPath(field: 'photo', path: filePath)],
    fields: {'album': 'profile'},
    fromJson: (json) => Map<String, dynamic>.from(json as Map),
  ),
);
```

## Security rules

- Never mark a session authenticated merely because a login response object exists.
- Never cast an auth user summary into a full application account model.
- Never log raw authorization headers, cookies, passwords, tokens, OTP values, or secrets.
- Load the typed account/bootstrap resource only after bridge authentication succeeds.
- Treat 401 as session expiry; treat 403 as an authorization failure without destroying a valid session.
