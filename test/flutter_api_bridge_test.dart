import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_api_bridge/flutter_api_bridge.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory hiveDirectory;

  const todo = <String, Object?>{
    'userId': 1,
    'id': 1,
    'title': 'delectus aut autem',
    'completed': false,
  };

  setUpAll(() async {
    hiveDirectory = await Directory.systemTemp.createTemp(
      'flutter_api_bridge_test_',
    );
    Hive.init(hiveDirectory.path);
  });

  tearDownAll(() async {
    await Hive.close();
    if (await hiveDirectory.exists()) {
      await hiveDirectory.delete(recursive: true);
    }
  });

  group('ApiResult', () {
    test('success exposes typed data and source metadata', () {
      const result = ApiSuccess<Map<String, Object?>>(
        message: 'Loaded',
        statusCode: 200,
        data: todo,
        raw: <String, Object?>{'message': 'Loaded', 'data': todo},
        meta: ApiResultMetadata(
          source: ApiDataSource.hiveCache,
          operationId: 'todos.getOne',
        ),
      );

      expect(result.isSuccess, isTrue);
      expect(result.dataOrNull, todo);
      expect(result.metadata?.source, ApiDataSource.hiveCache);
      expect(result.metadata?.operationId, 'todos.getOne');
      expect(
        result.when(
          success: (_, __, statusCode) => statusCode,
          error: (_, __, ___) => -1,
        ),
        200,
      );
    });

    test('error exposes transport details', () {
      const result = ApiError<Map<String, Object?>>(
        message: 'Request failed',
        error: 'Not found',
        statusCode: 404,
        meta: ApiResultMetadata(source: ApiDataSource.network),
      );

      var handled = '';
      result.ifError((error, _) => handled = error);

      expect(result.isError, isTrue);
      expect(result.dataOrNull, isNull);
      expect(handled, 'Not found');
    });
  });

  group('typed requests and options', () {
    test('GET builds a stable path and preserves production controls', () {
      const request = GetRequest<Map<String, Object?>>(
        endpoint: '/todos',
        version: '/v1',
        query: <String, Object?>{'userId': 1, 'completed': false},
        options: ApiGetRequestOptions(
          cache: true,
          cachePolicy: ApiCachePolicy.networkWithStaleFallback,
          cacheTtl: Duration(minutes: 10),
          forceRefresh: true,
          noAuth: true,
          headers: <String, String>{'x-client': 'test'},
          cookies: <String, String>{'preview': 'yes'},
          operationId: 'todos.list',
        ),
      );

      expect(request.fullPath, '/v1/todos');
      expect(request.cacheKey, contains('/v1/todos?'));
      expect(request.cache, isTrue);
      expect(request.forceRefresh, isTrue);
      expect(request.noAuth, isTrue);
      expect(request.headers?['x-client'], 'test');
      expect(request.cookies?['preview'], 'yes');
      expect(request.operationId, 'todos.list');
    });

    test('copyWith injects operation metadata without losing options', () {
      const caller = ApiGetRequestOptions(
        cache: false,
        headers: <String, String>{'X-Tenant': 'company-7'},
        cookies: <String, String>{'mode': 'preview'},
      );

      final generated = caller.copyWith(operationId: 'services.list');

      expect(generated.operationId, 'services.list');
      expect(generated.cache, isFalse);
      expect(generated.headers?['X-Tenant'], 'company-7');
      expect(generated.cookies?['mode'], 'preview');
    });

    test('upload requests require upload-specific options', () {
      const request = UploadRequest<Map<String, Object?>>(
        endpoint: '/uploads',
        version: '/v1',
        files: <UploadFile>[
          UploadFile.fromBytes(
            field: 'photo',
            bytes: <int>[1],
            filename: 'todo.png',
          ),
        ],
        fields: <String, String>{'title': 'Todo'},
        method: UploadMethod.put,
        options: ApiUploadRequestOptions(
          noAuth: true,
          headers: <String, String>{'x-upload': 'yes'},
          operationId: 'uploads.replace',
        ),
      );

      expect(request.fullPath, '/v1/uploads');
      expect(request.uploadOptions?.operationId, 'uploads.replace');
      expect(request.noAuth, isTrue);
      expect(request.headers?['x-upload'], 'yes');
    });
  });

  group('session-partitioned Hive cache', () {
    Future<ApiCache> createCache(String suffix) => ApiCache.create(
          connectionKey: 'cache-$suffix-${DateTime.now().microsecondsSinceEpoch}',
          baseUri: Uri.parse('https://api.example.com'),
          config: const ApiCacheConfig(maxEntries: 20),
        );

    test('session changes clear the previous active partition', () async {
      final cache = await createCache('switch');
      await cache.startSession(sessionId: 'session-a');
      await cache.write(
        'GET|/profile',
        todo,
        ttl: const Duration(minutes: 5),
      );
      expect((await cache.read('GET|/profile'))?.data, todo);

      await cache.startSession(sessionId: 'session-b');
      expect(await cache.read('GET|/profile'), isNull);

      await cache.startSession(
        sessionId: 'session-a',
        clearPreviousOnChange: false,
      );
      expect(await cache.read('GET|/profile'), isNull);
      await cache.clearAll();
    });

    test('supports stale fallback and tag invalidation', () async {
      final cache = await createCache('stale');
      await cache.startSession(sessionId: 'session-a');
      await cache.write(
        'GET|/bookings',
        <String, Object?>{'items': <Object?>[]},
        ttl: const Duration(milliseconds: -1),
        tags: const <String>['bookings'],
      );

      expect(await cache.read('GET|/bookings'), isNull);
      final stale = await cache.read('GET|/bookings', allowStale: true);
      expect(stale?.isStale, isTrue);
      expect(stale?.source, anyOf(ApiCacheSource.memory, ApiCacheSource.hive));

      await cache.invalidateTags(const <String>['bookings']);
      expect(
        await cache.read('GET|/bookings', allowStale: true),
        isNull,
      );
      await cache.clearAll();
    });

    test('can clear an explicit session ID', () async {
      final cache = await createCache('clear');
      await cache.startSession(sessionId: 'session-a');
      await cache.write(
        'GET|/services',
        todo,
        ttl: const Duration(minutes: 5),
      );
      await cache.clearSession('session-a');
      expect(await cache.read('GET|/services'), isNull);
      await cache.clearAll();
    });
  });

  group('authentication strategies', () {
    test('bearer token uses secure storage and applies its header', () async {
      final storage = _MemoryCredentialStorage();
      final context = _context(storage: storage, suffix: 'bearer');
      const strategy = BearerStrategy(tokenKey: 'access_token');

      await strategy.saveCredentials('abc123', context);
      expect(await strategy.hasCredentials(context), isTrue);

      final options = RequestOptions(path: '/private');
      await strategy.apply(options, context);
      expect(options.headers['Authorization'], 'Bearer abc123');

      await strategy.clearCredentials(context);
      expect(await strategy.hasCredentials(context), isFalse);
    });

    test('cookie auth restores from the actual cookie jar', () async {
      final manager = ApiCookieManager.memory(
        baseUri: Uri.parse('https://api.example.com'),
      );
      await manager.setValues(const <String, String>{'session': 'cookie-value'});
      final context = AuthStrategyContext(
        connectionKey: 'cookies',
        storageNamespace: 'cookies',
        cookies: manager,
        secureStorage: _MemoryCredentialStorage(),
      );

      expect(
        await const CookieStrategy(
          sessionCookieNames: <String>['session'],
        ).hasCredentials(context),
        isTrue,
      );
      expect(
        await const CookieStrategy().hasCredentials(context),
        isTrue,
      );
      expect(
        await manager.mergedHeader(
          uri: Uri.parse('https://api.example.com/private'),
          overrides: const <String, String>{'preview': 'yes'},
        ),
        contains('preview=yes'),
      );
    });

    test('API key strategy uses the configured header', () async {
      final context = _context(
        storage: _MemoryCredentialStorage(),
        suffix: 'api-key',
      );
      final options = RequestOptions(path: '/private');

      await const ApiKeyStrategy(apiKey: 'secret').apply(options, context);

      expect(options.headers['x-api-key'], 'secret');
    });
  });

  group('client identity and uploads', () {
    test('builds a caller-owned user agent and diagnostic headers', () {
      const identity = ApiClientIdentity(
        applicationName: 'RiderescueDriver',
        applicationVersion: '2.4.1',
        buildNumber: '184',
        platform: 'android',
        installationId: 'installation-1',
        locale: 'en-KE',
      );

      final headers = identity.toHeaders();
      expect(headers['User-Agent'], contains('RiderescueDriver/2.4.1'));
      expect(headers['X-Client-Platform'], 'android');
      expect(headers['X-Installation-Id'], 'installation-1');
      expect(headers['Accept-Language'], 'en-KE');
    });

    test('UploadFile converts bytes and streams', () async {
      final bytesFile = await const UploadFile.fromBytes(
        field: 'photo',
        bytes: <int>[1, 2, 3],
        filename: 'todo.png',
      ).toMultipart();
      final streamFile = await UploadFile.fromStream(
        field: 'document',
        stream: Stream<List<int>>.value(<int>[4, 5, 6, 7]),
        filename: 'todo.txt',
        length: 4,
      ).toMultipart();

      expect(bytesFile.value.length, 3);
      expect(streamFile.value.length, 4);
    });
  });
}

AuthStrategyContext _context({
  required ApiCredentialStorage storage,
  required String suffix,
}) =>
    AuthStrategyContext(
      connectionKey: suffix,
      storageNamespace: suffix,
      cookies: ApiCookieManager.memory(
        baseUri: Uri.parse('https://api.example.com'),
      ),
      secureStorage: storage,
    );

class _MemoryCredentialStorage implements ApiCredentialStorage {
  final Map<String, String> _values = <String, String>{};

  @override
  Future<void> delete({required String key}) async {
    _values.remove(key);
  }

  @override
  Future<String?> read({required String key}) async => _values[key];

  @override
  Future<void> write({required String key, required String? value}) async {
    if (value == null) {
      _values.remove(key);
    } else {
      _values[key] = value;
    }
  }
}
