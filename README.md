# flutter_api_bridge

A lightweight Flutter API layer built on Dio, Riverpod, Hive, and persistent cookies.

`flutter_api_bridge` gives Flutter apps a small set of reusable pieces for HTTP requests, authentication headers, cookie persistence, cached GET responses, upload progress, and typed success/error results.

## Features

- Dio client setup with shared auth and cookie interceptors
- Bearer token, cookie, and API key auth strategies
- Riverpod notifiers for API calls and uploads
- Memory + Hive cache for GET responses
- Upload progress stream with cancel support
- Cookie helpers and cookie change events
- Auth event streams for 401 and 403 responses

## Installation

Add the package to your `pubspec.yaml`:

```yaml
dependencies:
  flutter_api_bridge: ^0.1.0
```

Then run:

```bash
flutter pub get
```

## Initialize

Call `Server.init` before `runApp`.

```dart
import 'package:flutter/material.dart';
import 'package:flutter_api_bridge/flutter_api_bridge.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Server.init(
    baseUrl: 'https://api.example.com',
    authStrategy: BearerStrategy(tokenKey: 'access_token'),
    defaultCacheTtl: const Duration(minutes: 5),
  );

  runApp(const ProviderScope(child: MyApp()));
}
```

For cookie-based APIs, use `const CookieStrategy()` instead of `BearerStrategy`.

## Send Requests

Use `apiProvider` when you want Riverpod-managed request state.

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

result.when(
  success: (data, message, statusCode) {
    // Use parsed data.
  },
  error: (error, message, statusCode) {
    // Show or log the failure.
  },
);
```

Mutations use the same notifier:

```dart
final result = await ref.read(apiProvider.notifier).send(
  PostRequest<Map<String, dynamic>>(
    endpoint: '/posts',
    body: {'title': 'Hello'},
    options: const ApiRequestOptions(noAuth: true),
    fromJson: (json) => Map<String, dynamic>.from(json as Map),
  ),
);
```

## Direct Dio Access

If you only need the configured Dio instance, use `ApiClient.instance`.

```dart
final response = await ApiClient.instance('').get('/todos/1');
```

Pass a version prefix when you want separate clients:

```dart
final response = await ApiClient.instance('/v1').get('/users');
```

## Cache

GET requests cache by default. Configure cache behavior with `ApiGetRequestOptions`.

```dart
await ref.read(apiProvider.notifier).send(
  GetRequest<Map<String, dynamic>>(
    endpoint: '/users',
    options: const ApiGetRequestOptions(
      cacheTtl: Duration(minutes: 10),
      forceRefresh: true,
    ),
    fromJson: (json) => Map<String, dynamic>.from(json as Map),
  ),
);

await ApiCache.invalidateWhere('/users');
```

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

Watch upload progress from the widget tree:

```dart
final progress = ref.watch(uploadProgressStreamProvider);
```

Cancel an in-progress upload:

```dart
ref.read(uploadProvider.notifier).cancel();
```

## Auth And Cookies

Save and clear bearer tokens:

```dart
await BearerStrategy.saveToken(token, key: 'access_token');
await BearerStrategy.clearToken(key: 'access_token');
```

Listen for auth failures:

```dart
AuthEvents.onUnauthorized.listen((event) {
  // Refresh a token or send the user back to sign in.
});

AuthEvents.onForbidden.listen((event) {
  // Handle permission failures.
});
```

Work with cookies:

```dart
final hasRefreshToken = await CookieManager.has('refresh_token');

CookieEvents.onCookieSet('refresh_token').listen((event) {
  // React to cookie changes.
});
```

Clear local state during logout:

```dart
await Server.logout(tokenKey: 'access_token');
```

## Example

See the `example/` app for a minimal JSONPlaceholder request using the configured `ApiClient`.
