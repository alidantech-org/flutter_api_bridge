# flutter_api_bridge

A typed Flutter HTTP runtime for generated API packages and application code. It provides isolated named connections, explicit authentication lifecycle, persistent cookies or bearer credentials, single-flight refresh, safe structured logging, caching, uploads, and typed `ApiResult<T>` values.

## Core rule: login is not authentication state

`flutter_api_bridge` never decides that a connection is authenticated because an endpoint returned HTTP 200 or because a response class is named `LoginResponse`.

Authentication is established only when credentials actually exist:

- **Cookie transport:** Dio persists the configured access cookie from `Set-Cookie`, then the bridge synchronizes the cookie jar.
- **Bearer transport:** application or SDK adapter code validates the response and explicitly calls `ApiAuth.establish`.

A successful login response without usable credentials leaves the connection unauthenticated.

## Add the package

```yaml
dependencies:
  flutter_api_bridge: ^0.2.0-alpha.1
```

## Configure a named connection

Generated API packages should own a stable connection key and configure it before `runApp`.

```dart
await FlutterApiBridge.configure(
  key: 'riderescue_api',
  config: ApiBridgeConfig(
    baseUri: Uri.parse('https://api.example.com'),
    auth: const AuthConfig(
      transport: AuthTransport.cookies,
      accessCookieName: 'access_token',
      refreshCookieName: 'refresh_token',
      refreshPath: '/v1/auth/refresh',
    ),
  ),
);

final connection = FlutterApiBridge.requireConnection('riderescue_api');
```

Generated wrappers can expose the same connection without depending on Riverpod, widget refs, or application providers:

```dart
class ExampleApi {
  ExampleApi._(ApiConnection connection) : v1 = V1Client(connection);

  static const connectionKey = 'example_api';

  static Future<void> configure(ApiBridgeConfig config) {
    return FlutterApiBridge.configure(
      key: connectionKey,
      config: config,
    );
  }

  static ApiConnection get connection {
    return FlutterApiBridge.requireConnection(connectionKey);
  }

  static ApiAuth get auth => connection.auth;

  final V1Client v1;
}
```

## Execute typed requests

```dart
final result = await connection.execute(
  GetRequest<UserResponse>(
    endpoint: '/v1/users/me',
    fromJson: (json) => UserResponse.fromJson(
      Map<String, dynamic>.from(json as Map),
    ),
  ),
);

result.when(
  success: (data, message, statusCode) {
    // Use typed data.
  },
  error: (error, message, statusCode) {
    // Present a safe application error.
  },
);
```

## Public authentication endpoints

Login, signup, Google sign-in, verification, password reset, health checks, and other public operations must be generated with unauthenticated request options:

```dart
PostRequest<AuthResponse>(
  endpoint: '/v1/auth/login',
  options: const ApiRequestOptions.unauthenticated(),
  body: body.toJson(),
  fromJson: AuthResponse.fromJson,
);
```

This prevents a failed login from refreshing or reusing an older session. The bridge only retries a 401 when:

1. authentication was enabled for the request;
2. a usable access credential was actually applied;
3. the request allows retry;
4. the request has not already been retried; and
5. refresh is configured and a refresh credential exists.

## Cookie authentication

Cookie auth is the default transport. It is suitable for HttpOnly access and refresh cookies.

```dart
const authConfig = AuthConfig(
  transport: AuthTransport.cookies,
  accessCookieName: 'access_token',
  refreshCookieName: 'refresh_token',
  refreshPath: '/v1/auth/refresh',
);
```

After a login request completes, read the bridge-owned state:

```dart
final session = connection.auth.current;
if (!session.isAuthenticated) {
  // Login returned no usable access cookie.
}
```

Do not parse, copy, expose, or store HttpOnly cookie values in application state.

## Bearer authentication

Bearer responses are application-specific, so the bridge does not guess token fields. Validate and commit credentials explicitly:

```dart
final response = await login();

if (response.isValid) {
  await connection.auth.establish(
    accessToken: response.accessToken,
    refreshToken: response.refreshToken,
    expiresAt: response.expiresAt,
  );
}
```

Configure refresh with a callback that extracts replacement credentials:

```dart
final config = AuthConfig(
  transport: AuthTransport.bearer,
  refresh: (context) async {
    final response = await context.request(
      path: '/v1/auth/refresh',
      data: {'refreshToken': securelyReadRefreshToken()},
    );

    final json = Map<String, dynamic>.from(response.data as Map);
    return AuthRefreshResult.success(
      accessToken: json['accessToken'] as String,
      refreshToken: json['refreshToken'] as String?,
      expiresAt: DateTime.parse(json['expiresAt'] as String),
    );
  },
);
```

Concurrent unauthorized requests share one refresh future. Each original request can be retried at most once.

## Observe authentication

```dart
final current = connection.auth.current;

final subscription = connection.auth.changes.listen((session) {
  switch (session.status) {
    case AuthSessionStatus.authenticated:
      // Start authenticated application services.
    case AuthSessionStatus.refreshing:
      // Keep the authenticated shell while refresh is in progress.
    case AuthSessionStatus.expired:
    case AuthSessionStatus.unauthenticated:
      // Stop protected services or route to sign in.
    default:
      break;
  }
});
```

Application state may cache user/profile DTOs, but it should not duplicate tokens, cookies, expiry calculations, or bridge authentication status.

## Logout

Call the backend logout endpoint first when one exists, then clear the connection-owned local state:

```dart
await api.userAuth.logoutCurrentSession();
await connection.logout();
```

`connection.logout()` clears only this connection's authentication credentials and namespaced cache. It does not affect other configured APIs.

## Structured logging

Logging is disabled by default. Enable it explicitly for development or provide a production telemetry sink:

```dart
final events = <ApiLogEvent>[];

final logging = ApiLoggingConfig(
  enabled: true,
  minimumLevel: ApiLogLevel.info,
  sink: events.add,
  logRequestHeaders: true,
  logResponseHeaders: true,
  logRequestBody: true,
  logResponseBody: false,
);
```

Before any event reaches a sink, the bridge recursively redacts:

- authorization and proxy-authorization headers;
- cookies and set-cookie headers;
- API keys;
- passwords, passcodes, PINs, and secrets;
- access, refresh, temporary, and identity tokens;
- sensitive nested map and JSON-string fields.

Multipart logs contain only field names, filenames, and byte lengths. Raw file contents are never logged.

Every request log carries a connection-scoped request ID, method, URI, status, duration, retry count, and whether authentication was actually applied.

## Legacy API

`Server`, `ApiClient`, `AuthStrategy`, and Riverpod's `apiProvider` remain available for compatibility. New generated packages should use `FlutterApiBridge`, `ApiConnection`, and `ApiAuth`.

The legacy debug logger no longer prints request/response bodies or credential-bearing headers.

## Validation

```bash
flutter pub get
dart format --set-exit-if-changed .
flutter analyze
flutter test
dart pub publish --dry-run
```