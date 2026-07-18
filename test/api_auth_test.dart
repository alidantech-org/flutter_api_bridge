import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_api_bridge/flutter_api_bridge.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('transport auth restoration', () {
    test('manual auth headers and session ID restore after restart', () async {
      final storage = _MemoryCredentialStorage();
      final context = AuthStrategyContext(
        connectionKey: 'test',
        storageNamespace: 'test-runtime',
        cookies: ApiCookieManager.memory(
          baseUri: Uri.parse('https://api.example.com'),
        ),
        secureStorage: storage,
      );

      final first = ApiAuth(
        strategy: const NoAuthStrategy(),
        context: context,
      );
      await first.initialize();
      await first.initializeUserSession(
        sessionId: 'user-42',
        authHeaders: const <String, String>{
          'Authorization': 'Custom credential',
        },
      );
      await first.dispose();

      final restored = ApiAuth(
        strategy: const NoAuthStrategy(),
        context: context,
      );
      final session = await restored.initialize();

      expect(session.status, AuthSessionStatus.authenticated);
      expect(session.sessionId, 'user-42');
      expect(
        restored.sessionHeaders['Authorization'],
        'Custom credential',
      );
      await restored.dispose();
    });

    test('expired state survives restart until the session is renewed',
        () async {
      final storage = _MemoryCredentialStorage();
      final context = AuthStrategyContext(
        connectionKey: 'expired-test',
        storageNamespace: 'expired-runtime',
        cookies: ApiCookieManager.memory(
          baseUri: Uri.parse('https://api.example.com'),
        ),
        secureStorage: storage,
      );

      final first = ApiAuth(
        strategy: const NoAuthStrategy(),
        context: context,
      );
      await first.initialize();
      await first.initializeUserSession(
        sessionId: 'user-42',
        authHeaders: const <String, String>{
          'Authorization': 'Custom credential',
        },
      );
      await first.expire(reason: 'http_401');
      await first.dispose();

      final restored = ApiAuth(
        strategy: const NoAuthStrategy(),
        context: context,
      );
      final expired = await restored.initialize();

      expect(expired.status, AuthSessionStatus.expired);
      expect(expired.sessionId, 'user-42');
      expect(expired.reason, 'http_401');

      await restored.initializeUserSession(
        sessionId: 'user-42',
        authHeaders: const <String, String>{
          'Authorization': 'Replacement credential',
        },
      );
      expect(restored.current.status, AuthSessionStatus.authenticated);
      await restored.dispose();

      final renewed = ApiAuth(
        strategy: const NoAuthStrategy(),
        context: context,
      );
      final renewedSession = await renewed.initialize();
      expect(renewedSession.status, AuthSessionStatus.authenticated);
      expect(
        renewed.sessionHeaders['Authorization'],
        'Replacement credential',
      );
      await renewed.dispose();
    });

    test('concurrent unauthorized responses expire the session once', () async {
      final strategy = _CountingUnauthorizedStrategy();
      final auth = ApiAuth(
        strategy: strategy,
        context: AuthStrategyContext(
          connectionKey: 'concurrent-401',
          storageNamespace: 'concurrent-401',
          cookies: ApiCookieManager.memory(
            baseUri: Uri.parse('https://api.example.com'),
          ),
          secureStorage: _MemoryCredentialStorage(),
        ),
      );
      await auth.initialize();
      await auth.initializeUserSession(
        sessionId: 'user-42',
        authHeaders: const <String, String>{
          'Authorization': 'Custom credential',
        },
      );

      await Future.wait<void>(<Future<void>>[
        auth.expire(reason: 'http_401'),
        auth.expire(reason: 'http_401'),
        auth.expire(reason: 'http_401'),
      ]);

      expect(strategy.unauthorizedCalls, 1);
      expect(auth.current.status, AuthSessionStatus.expired);
      await auth.dispose();
    });
  });

  group('session cache isolation', () {
    late Directory directory;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('fab_cache_test_');
      Hive.init(directory.path);
    });

    tearDown(() async {
      await Hive.close();
      await directory.delete(recursive: true);
    });

    test('changing session clears the previous session cache', () async {
      final cache = await ApiCache.create(
        connectionKey: 'cache-test-${DateTime.now().microsecondsSinceEpoch}',
        baseUri: Uri.parse('https://api.example.com'),
        config: const ApiCacheConfig(),
      );

      await cache.startSession(sessionId: 'session-a');
      await cache.write(
        'GET|/profile',
        const <String, dynamic>{'name': 'A'},
        ttl: const Duration(minutes: 5),
      );
      expect(await cache.read('GET|/profile'), isNotNull);

      await cache.startSession(sessionId: 'session-b');
      await cache.startSession(
        sessionId: 'session-a',
        clearPreviousOnChange: false,
      );

      expect(await cache.read('GET|/profile'), isNull);
    });
  });

  test('request options preserve generated operation metadata', () {
    const options = ApiGetRequestOptions(
      cache: false,
      forceRefresh: true,
      headers: <String, String>{'X-Test': 'yes'},
    );

    final generated = options.copyWith(operationId: 'users.getCurrent');

    expect(generated.operationId, 'users.getCurrent');
    expect(generated.cache, isFalse);
    expect(generated.forceRefresh, isTrue);
    expect(generated.headers?['X-Test'], 'yes');
  });

  test('ApiLogRedactor removes nested secrets', () {
    const redactor = ApiLogRedactor(ApiLoggingConfig.defaultSensitiveKeys);
    final value = redactor.redact(<String, Object?>{
      'email': 'user@example.com',
      'password': 'secret',
      'headers': <String, String>{
        'Authorization': 'Bearer token',
        'Accept': 'application/json',
      },
    }) as Map<String, Object?>;

    expect(value['email'], 'user@example.com');
    expect(value['password'], '[REDACTED]');
    expect(
      (value['headers'] as Map<String, Object?>)['Authorization'],
      '[REDACTED]',
    );
  });
}

class _CountingUnauthorizedStrategy extends AuthStrategy {
  int unauthorizedCalls = 0;

  @override
  Future<void> apply(
    RequestOptions options,
    AuthStrategyContext context,
  ) async {}

  @override
  Future<void> onUnauthorized(AuthStrategyContext context) async {
    unauthorizedCalls += 1;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class _MemoryCredentialStorage implements ApiCredentialStorage {
  final Map<String, String> values = <String, String>{};

  @override
  Future<void> delete({required String key}) async {
    values.remove(key);
  }

  @override
  Future<String?> read({required String key}) async => values[key];

  @override
  Future<void> write({required String key, required String? value}) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }
}
