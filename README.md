# Riderescue API SDK

Flutter/Dart SDK for the Riderescue API.

## Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  riderescue_api:
    git:
      url: https://github.com/riderescue/riderescue_api_sdk.git
      path: packages/dart
      ref: main
```

## Usage

### Initialization

```dart
import 'package:riderescue_api/riderescue_api.dart';

await Server.init(
  baseUrl: 'https://api.riderescue.com',
  authStrategy: BearerStrategy(tokenKey: 'access_token'),
  defaultCacheTtl: const Duration(minutes: 5),
);
```

### Making API Calls

```dart
final api = AuthApi(Server.dio);

final result = await api.login(
  LoginBody(
    email: email,
    password: password,
  ),
);
```

### Error Handling

```dart
final apiError = ApiErrorResponse.fromJson(error.response?.data);

final emailError = apiError.firstFieldError(LoginErrorFields.email);
final passwordError = apiError.firstFieldError(LoginErrorFields.password);
```

## Features

- ✅ Dio-based HTTP client
- ✅ Cookie management
- ✅ Hive caching
- ✅ Riverpod state management
- ✅ Upload progress tracking
- ✅ Multiple auth strategies (Bearer, API Key, None)
- ✅ Auto-generated endpoints and DTOs

## Structure

- `lib/src/client/` - Manually owned runtime API client code
- `lib/src/generated/` - Auto-generated endpoints, DTOs, and clients

## Development

To regenerate the generated code:

```bash
cd sdk/generators
pnpm generate:dart
```
# Dependencies to add to pubspec.yaml

```yaml
dependencies:
  dio: ^5.7.0
  dio_cookie_manager: ^3.1.1
  cookie_jar: ^4.0.8
  hive_flutter: ^1.1.0
  flutter_riverpod: ^2.5.1
  path_provider: ^2.1.4

dev_dependencies:
  build_runner: ^2.4.13
  hive_generator: ^2.0.1
```

## main.dart

```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Server.init(
    baseUrl: 'https://api.riderescue.com',
    authStrategy: BearerStrategy(tokenKey: 'access_token'),
    defaultCacheTtl: Duration(minutes: 5),
  );

  runApp(const ProviderScope(child: MyApp()));
}
```

## Screen usage examples

```dart
// GET with cache
final result = await ref.read(apiProvider.notifier).send(
  GetRequest(
    endpoint: V1.brands,
    version: ApiVersion.v1,
    fromJson: (j) => BrandsResponse.fromJson(j as Map),
    cache: true,
    cacheTtl: Duration(minutes: 10),
  ),
);
result.when(
  success: (data, message, _) => showSnackbar(message),
  error:   (error, message, _) => showSnackbar(message),
);

// POST
final result = await ref.read(apiProvider.notifier).send(
  PostRequest(
    endpoint: V1.login,
    version: ApiVersion.v1,
    body: {'email': email, 'password': password},
    fromJson: AuthSessionResponse.fromJson,
    noAuth: true,
  ),
);

// Force refresh — bypasses cache
await ref.read(apiProvider.notifier).send(
  GetRequest(
    endpoint: V1.brands,
    version: ApiVersion.v1,
    fromJson: (j) => BrandsResponse.fromJson(j as Map),
    forceRefresh: true,
  ),
);

// Invalidate cache for a whole endpoint family
await ApiCache.invalidateWhere('/v1/brands');

// Upload with progress bar
ref.read(uploadProvider.notifier).upload(
  UploadRequest(
    endpoint: V1.upload,
    version: ApiVersion.v1,
    fromJson: (j) => UploadResponse.fromJson(j as Map),
    files: [UploadFile.fromPath(field: 'photo', path: filePath)],
    fields: {'vehicleId': id},
  ),
);

// In widget tree — watch progress
final progress = ref.watch(uploadProgressStreamProvider);
progress.when(
  data: (p) => LinearProgressIndicator(value: p.percent),
  loading: () => const SizedBox.shrink(),
  error: (_, __) => const SizedBox.shrink(),
);

// Listen to auth events anywhere
AuthEvents.onUnauthorized.listen((e) {
  // refresh token or logout
});

// Cookie helpers
final cookies = CookieManager();
final hasToken = await cookies.has('refresh_token');
await cookies.clearAll(); // on logout
CookieEvents.onCookieSet('refresh_token').listen((_) {
  // cookie was just set by backend
});

// Save token after login (app creator does this)
await BearerStrategy.saveToken(token, key: 'access_token');

// Full logout
await Server.logout(tokenKey: 'access_token');
```

---

**Complete `lib/server/` plan**

**Init — once at app start**

```dart
Server.init(
  baseUrl: 'https://api.riderescue.com',
  defaultVersion: ApiVersion.v1,
  authStrategy: BearerStrategy(tokenKey: 'access_token'),
  cacheTtl: Duration(minutes: 5),
  apiKey: null, // future
);
```

**Folder structure — final**

```
lib/server/
  api/
    api_client.dart        — Dio instance, version routing, interceptors
    api_request.dart       — all request types including upload
    api_result.dart        — ApiResult<T> with data + message + success
    api_provider.dart      — single Riverpod notifier screens talk to
    api_cache.dart         — L1 memory + L2 Hive, TTL, manual invalidation
    api_endpoints.dart     — endpoint constants + deprecation markers
    api_versions.dart      — version enum + deprecation mechanism
  auth/
    auth_strategy.dart     — abstract + Bearer + Cookie + ApiKey(future)
    auth_config.dart       — token key constant, api key placeholder
  cookies/
    cookie_manager.dart    — CookieJar wrapper, get/set/clear/clearByName
    cookie_events.dart     — streams: onCookiesChanged, onCookiesCleared, onCookieSet
  upload/
    upload_provider.dart   — upload notifier with progress stream
    upload_progress.dart   — UploadProgress model (sent, total, percent, isDone)
  models/                  — already exists, auto-generated
  server.dart              — barrel export + Server.init()
```

**Request types summary**

```
ApiRequest.get()      — endpoint, version, query, cache config, fromJson
ApiRequest.post()     — endpoint, version, body, fromJson
ApiRequest.put()      — endpoint, version, body, fromJson
ApiRequest.patch()    — endpoint, version, body, fromJson
ApiRequest.delete()   — endpoint, version, body, fromJson
ApiRequest.upload()   — endpoint, version, fields, files, fromJson
```

**Cache**

```
L1 memory  — always, instant
L2 Hive    — persistent, own named box: 'server_cache'
TTL        — app-level default constant, per-request override
Invalidate — by exact key or pattern
```

**Auth**

```
BearerStrategy  — memory first → Hive fallback, key is app constant
CookieStrategy  — Dio CookieJar fully automatic
ApiKeyStrategy  — future, compile-time constant, all requests, opt-out per request
Screens         — can only opt out via noAuth: true
Token refresh   — app responsibility, layer emits onUnauthorized stream
```

**Cookie streams**

```
onCookiesChanged   — any add/update
onCookiesCleared   — full clear
onCookieSet(name)  — specific cookie set
```

**Auth event streams**

```
onUnauthorized     — 401
onForbidden        — 403
```

**Upload**

```
Progress stream    — UploadProgress(sent, total, percent, isDone)
Cancel token       — screen can cancel mid-upload
Result             — same ApiResult<T> as all other requests
Content-Type       — auto-set by request type
Supports           — file path, bytes, stream, mixed FormData
```

**ApiResult<T>**

```dart
ApiResult<T>
  ├── success: bool
  ├── message: String      // raw server message for snackbars
  ├── data: T?             // parsed model
  ├── statusCode: int
  └── error: String?       // logged as warning, shown if needed
```

**Screen usage will look like:**

```dart
// GET with cache
ref.read(apiProvider.notifier).send(
  GetRequest(
    endpoint: V1.brands,
    version: ApiVersion.v1,
    fromJson: BrandsResponse.fromJson,
    cache: true,
    cacheTtl: Duration(minutes: 10),
  ),
);

// POST
ref.read(apiProvider.notifier).send(
  PostRequest(
    endpoint: V1.login,
    version: ApiVersion.v1,
    body: {'email': email, 'password': password},
    fromJson: AuthSessionResponse.fromJson,
  ),
);

// Upload with progress
ref.read(uploadProvider.notifier).upload(
  UploadRequest(
    endpoint: V1.uploadPhoto,
    version: ApiVersion.v1,
    files: [UploadFile(field: 'photo', path: filePath)],
    fields: {'vehicleId': id},
    fromJson: UploadResponse.fromJson,
  ),
);

// Watch progress
final progress = ref.watch(uploadProgressProvider);
LinearProgressIndicator(value: progress.percent);
```

---

**Are you happy with this full plan?** Once you confirm I'll write each file one at a time in order, complete and ready to copy in.
# flutter_api_bridge
