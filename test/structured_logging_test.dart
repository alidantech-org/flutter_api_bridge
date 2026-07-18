import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_api_bridge/flutter_api_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory runtimeDirectory;
  HttpOverrides? previousHttpOverrides;

  setUpAll(() async {
    previousHttpOverrides = HttpOverrides.current;
    HttpOverrides.global = _RealHttpOverrides();
    runtimeDirectory = await Directory.systemTemp.createTemp(
      'flutter_api_bridge_logging_',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => runtimeDirectory.path,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => switch (call.method) {
        'read' => null,
        'readAll' => <String, String>{},
        'containsKey' => false,
        _ => null,
      },
    );
  });

  tearDownAll(() async {
    await FlutterApiBridge.disposeAll();
    await Hive.close();
    HttpOverrides.global = previousHttpOverrides;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      null,
    );
    if (await runtimeDirectory.exists()) {
      await runtimeDirectory.delete(recursive: true);
    }
  });

  const formatter = ApiLogFormatter();
  final basic = const ApiLoggingConfig().resolve();
  final withRequestId = const ApiLoggingConfig(showRequestId: true).resolve();
  final detailed = const ApiLoggingConfig(
    level: ApiLoggingLevel.detailed,
    logRequestBody: true,
    logResponseBody: true,
  ).resolve();
  final timestamp = DateTime.utc(2026, 1, 2, 3, 4, 5);

  group('structured formatter', () {
    test('formats a compact request without request IDs by default', () {
      final output = formatter.format(
        ApiRequestLogEvent(
          timestamp: timestamp,
          method: 'GET',
          path: '/v1/user/auth/bootstrap',
          operationId: 'user_auth.getCurrentAuthBootstrap',
          requestId: 'hkimxurjjl-123456',
          attempt: 1,
          maxAttempts: 3,
          options: basic,
        ),
      );

      expect(
        output,
        'REQ: user_auth.getCurrentAuthBootstrap · GET · '
        '/v1/user/auth/bootstrap\n  ↳ attempt=1',
      );
      expect(output, isNot(contains('hkimxurjjl')));
    });

    test('shortens request IDs only when enabled', () {
      final output = formatter.format(
        ApiRequestLogEvent(
          timestamp: timestamp,
          method: 'GET',
          path: '/v1/jobs',
          operationId: 'jobs.list',
          requestId: '12345678901234567890',
          attempt: 1,
          maxAttempts: 1,
          options: withRequestId,
        ),
      );

      expect(output, contains('request=123456789012...'));
      expect(output, isNot(contains('12345678901234567890')));
    });

    test('formats network and cache responses with duration', () {
      final network = formatter.format(
        ApiResponseLogEvent(
          timestamp: timestamp,
          method: 'GET',
          path: '/v1/jobs',
          operationId: 'jobs.list',
          requestId: 'request-1',
          statusCode: 200,
          duration: const Duration(milliseconds: 184),
          source: 'network',
          options: basic,
        ),
      );
      final cache = formatter.format(
        ApiResponseLogEvent(
          timestamp: timestamp,
          method: 'GET',
          path: '/v1/jobs',
          operationId: 'jobs.list',
          requestId: 'request-2',
          statusCode: 200,
          duration: const Duration(milliseconds: 8),
          source: 'cache',
          options: basic,
          data: const <String, Object?>{'cache': 'hit'},
        ),
      );

      expect(
          network, startsWith('RES: jobs.list · GET · /v1/jobs · 200 · 184ms'));
      expect(network, contains('source=network'));
      expect(cache, contains('source=cache'));
      expect(cache, contains('cache=hit'));
    });

    test('formats safe errors, retries, cache, and auth events', () {
      final error = formatter.format(
        ApiErrorLogEvent(
          timestamp: timestamp,
          method: 'POST',
          path: '/v1/bookings',
          operationId: 'booking.createBooking',
          requestId: 'request-1',
          statusCode: 422,
          duration: const Duration(milliseconds: 197),
          code: 'validation_failed',
          options: basic,
          data: const <String, Object?>{'message': 'Vehicle is required'},
        ),
      );
      final retry = formatter.format(
        ApiRetryLogEvent(
          timestamp: timestamp,
          operationId: 'user_auth.refreshSession',
          requestId: 'request-2',
          attempt: 2,
          maxAttempts: 3,
          retryDelay: const Duration(milliseconds: 800),
          options: basic,
          data: const <String, Object?>{'reason': 'connection_timeout'},
        ),
      );
      final cache = formatter.format(
        ApiCacheLogEvent(
          timestamp: timestamp,
          operationId: 'jobs.listAvailableJobs',
          source: 'disk',
          options: basic,
          data: const <String, Object?>{'cache': 'hit', 'age': '42s'},
        ),
      );
      final auth = formatter.format(
        ApiAuthLogEvent(
          timestamp: timestamp,
          options: basic,
          data: const <String, Object?>{
            'status': 'authenticated',
            'reason': 'credentials_restored',
          },
        ),
      );

      expect(
          error,
          contains(
              'ERR: booking.createBooking · POST · /v1/bookings · 422 · 197ms'));
      expect(error, contains('code=validation_failed'));
      expect(error, contains('message="Vehicle is required"'));
      expect(
          retry,
          startsWith(
              'RETRY: user_auth.refreshSession · attempt 2/3 · in 800ms'));
      expect(retry, contains('reason=connection_timeout'));
      expect(cache, startsWith('CACHE: jobs.listAvailableJobs · hit'));
      expect(auth, 'AUTH: authenticated\n  ↳ reason=credentials_restored');
    });

    test('renders explicitly enabled bodies below summaries', () {
      final output = formatter.format(
        ApiRequestLogEvent(
          timestamp: timestamp,
          method: 'POST',
          path: '/v1/bookings',
          operationId: 'booking.createBooking',
          requestId: 'request-1',
          attempt: 1,
          maxAttempts: 1,
          options: detailed,
          data: const <String, Object?>{
            'body': <String, Object?>{
              'serviceId': 'service_123',
              'password': 'never-print-this',
            },
          },
        ),
      );

      expect(output, contains('body={'));
      expect(output, contains('"serviceId": "service_123"'));
      expect(output, contains('"password": "[REDACTED]"'));
      expect(output, isNot(contains('never-print-this')));
    });
  });

  group('configuration precedence', () {
    test('safe defaults disable bodies and transport metadata', () {
      const config = ApiLoggingConfig();
      final resolved = config.resolve();

      expect(resolved.level, ApiLoggingLevel.basic);
      expect(resolved.requestHeaders, isFalse);
      expect(resolved.requestBody, isFalse);
      expect(resolved.responseHeaders, isFalse);
      expect(resolved.responseBody, isFalse);
      expect(resolved.queryParameters, isFalse);
      expect(resolved.cookies, isFalse);
      expect(resolved.showRequestId, isFalse);
    });

    test('per-call options override global metadata defaults', () {
      const config = ApiLoggingConfig(
        level: ApiLoggingLevel.detailed,
        logRequestHeaders: true,
        logResponseHeaders: true,
      );
      final resolved = config.resolve(
        const ApiCallLogOptions(requestBody: true, responseBody: true),
      );

      expect(resolved.requestHeaders, isFalse);
      expect(resolved.responseHeaders, isFalse);
      expect(resolved.requestBody, isTrue);
      expect(resolved.responseBody, isTrue);
    });

    test('none and per-call disabled suppress logging', () {
      expect(
        const ApiLoggingConfig(level: ApiLoggingLevel.none).resolve().enabled,
        isFalse,
      );
      expect(
        const ApiLoggingConfig()
            .resolve(const ApiCallLogOptions(enabled: false))
            .enabled,
        isFalse,
      );
    });

    test('request options preserve client-only logging controls', () {
      const callLog = ApiCallLogOptions(requestBody: true);
      const options = ApiGetRequestOptions(log: callLog, cache: false);
      final copy = options.copyWith(operationId: 'jobs.list');

      expect(copy.log, same(callLog));
      expect(copy.operationId, 'jobs.list');
      expect(copy.cache, isFalse);
    });
  });

  group('mandatory redaction', () {
    const redactor = ApiLogRedactor(
      ApiLoggingConfig.defaultSensitiveKeys,
    );
    const boundedRedactor = ApiLogRedactor(
      ApiLoggingConfig.defaultSensitiveKeys,
      maxDepth: 3,
      maxCollectionItems: 2,
      maxStringLength: 12,
    );

    test('redacts case and naming variants recursively', () {
      final safe = redactor.redact(<String, Object?>{
        'Authorization': 'Bearer secret',
        'refresh_token': 'refresh-secret',
        'profile': <String, Object?>{
          'passwordConfirmation': 'password-secret',
          'name': 'Driver',
        },
      }) as Map<String, Object?>;

      expect(safe['Authorization'], '[REDACTED]');
      expect(safe['refresh_token'], '[REDACTED]');
      expect(
        (safe['profile'] as Map<String, Object?>)['passwordConfirmation'],
        '[REDACTED]',
      );
    });

    test('redacts secrets embedded in URL query parameters', () {
      final safe = redactor.redact(
        'https://example.com/file?signature=secret&name=report',
      );

      expect(safe, contains('signature=%5BREDACTED%5D'));
      expect(safe, isNot(contains('signature=secret')));
    });

    test('bounds long values, collections, depth, and cycles', () {
      final cyclic = <String, Object?>{};
      cyclic['self'] = cyclic;
      final safe = boundedRedactor.redact(<String, Object?>{
        'long': 'abcdefghijklmnopqrstuvwxyz',
        'items': <String>['one', 'two', 'three'],
      }) as Map<String, Object?>;
      final cyclicSafe = redactor.redact(cyclic);

      expect(safe['long'], 'abcdefghijkl...[TRUNCATED]');
      expect((safe['items'] as List<Object?>).last, '[TRUNCATED]');
      expect(cyclicSafe.toString(), contains('[CIRCULAR]'));
    });

    test('summarizes binary, streams, and multipart without bytes', () {
      final form = FormData.fromMap(<String, Object?>{
        'name': 'document',
        'file': MultipartFile.fromBytes(
          <int>[1, 2, 3, 4],
          filename: 'document.pdf',
        ),
      });

      expect(redactor.redact(Uint8List.fromList(<int>[1, 2, 3])),
          '[BINARY 3 bytes]');
      expect(redactor.redact(const Stream<List<int>>.empty()), '[STREAM]');
      final multipart = redactor.redact(form) as Map<String, Object?>;
      expect(multipart['type'], 'multipart');
      expect(multipart['files'], 1);
      expect(multipart['size'], 4);
      expect(multipart.toString(), isNot(contains('[1, 2, 3, 4]')));
    });
  });

  group('runtime integration', () {
    test('emits one request, concise retries, and one final response',
        () async {
      var attempts = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        attempts += 1;
        request.response.headers.contentType = ContentType.json;
        if (attempts < 3) {
          request.response.statusCode = HttpStatus.serviceUnavailable;
          request.response.write('{"error":"temporarily_unavailable"}');
        } else {
          request.response.write('{"message":"ok","value":1}');
        }
        await request.response.close();
      });
      final logger = _RecordingLogger();
      final key = 'logging-retry-${server.port}';

      try {
        final connection = await FlutterApiBridge.configure(
          key: key,
          config: ApiBridgeConfig(
            baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
            auth: const NoAuthStrategy(),
            cookiesEnabled: false,
            cache: const ApiCacheConfig(enabled: false),
            retry: const ApiRetryConfig(
              maxAttempts: 3,
              baseDelay: Duration(milliseconds: 1),
              maxDelay: Duration(milliseconds: 1),
            ),
            logger: logger,
          ),
        );
        final result = await connection.execute<Map<String, Object?>>(
          GetRequest<Map<String, Object?>>(
            endpoint: '/retry',
            options: const ApiGetRequestOptions(
              cache: false,
              noAuth: true,
              operationId: 'test.retry',
            ),
            fromJson: (json) => Map<String, Object?>.from(json as Map),
          ),
        );

        expect(result, isA<ApiSuccess<Map<String, Object?>>>());
        expect(attempts, 3);
        expect(logger.ofType(ApiLogEventType.request), hasLength(1));
        expect(logger.ofType(ApiLogEventType.retry), hasLength(2));
        expect(logger.ofType(ApiLogEventType.response), hasLength(1));
        expect(logger.ofType(ApiLogEventType.failure), isEmpty);
        final response = logger.ofType(ApiLogEventType.response).single;
        expect(response.source, 'network');
        expect(response.attempt, 3);
      } finally {
        await FlutterApiBridge.removeConnection(key);
        await server.close(force: true);
      }
    });

    test('reports a cache hit as the final response source', () async {
      var requests = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        requests += 1;
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"message":"ok","value":1}');
        await request.response.close();
      });
      final logger = _RecordingLogger();
      final key = 'logging-cache-${server.port}';

      try {
        final connection = await FlutterApiBridge.configure(
          key: key,
          config: ApiBridgeConfig(
            baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
            auth: const NoAuthStrategy(),
            cookiesEnabled: false,
            cache: const ApiCacheConfig(
              defaultPolicy: ApiCachePolicy.cacheFirst,
            ),
            retry: const ApiRetryConfig(enabled: false),
            logger: logger,
          ),
        );
        const request = GetRequest<Map<String, Object?>>(
          endpoint: '/cached',
          options: ApiGetRequestOptions(
            noAuth: true,
            operationId: 'test.cached',
          ),
        );

        await connection.execute<Map<String, Object?>>(request);
        await connection.execute<Map<String, Object?>>(request);

        expect(requests, 1);
        final responses = logger.ofType(ApiLogEventType.response);
        expect(responses, hasLength(2));
        expect(responses.first.source, 'network');
        expect(responses.last.source, 'cache');
      } finally {
        await FlutterApiBridge.removeConnection(key);
        await server.close(force: true);
      }
    });

    test('custom sinks receive typed events with mandatory redaction', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        await utf8.decoder.bind(request).join();
        request.response.headers.contentType = ContentType.json;
        request.response.headers.add(
          HttpHeaders.setCookieHeader,
          'access_token=response-secret',
        );
        request.response.write(
          '{"message":"ok","accessToken":"response-secret"}',
        );
        await request.response.close();
      });
      final logger = _RecordingLogger();
      final key = 'logging-redaction-${server.port}';

      try {
        final connection = await FlutterApiBridge.configure(
          key: key,
          config: ApiBridgeConfig(
            baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
            auth: const NoAuthStrategy(),
            cookiesEnabled: false,
            cache: const ApiCacheConfig(enabled: false),
            retry: const ApiRetryConfig(enabled: false),
            logger: logger,
          ),
        );
        await connection.execute<Map<String, Object?>>(
          const PostRequest<Map<String, Object?>>(
            endpoint: '/redaction',
            body: <String, Object?>{
              'email': 'driver@example.com',
              'password': 'request-secret',
            },
            options: ApiRequestOptions(
              noAuth: true,
              operationId: 'test.redaction',
              headers: <String, String>{
                'Authorization': 'Bearer request-secret',
              },
              cookies: <String, String>{
                'sessionToken': 'cookie-secret',
              },
              log: ApiCallLogOptions(
                requestHeaders: true,
                requestBody: true,
                responseHeaders: true,
                responseBody: true,
                cookies: true,
              ),
            ),
          ),
        );

        final requestEvent = logger.ofType(ApiLogEventType.request).single;
        final responseEvent = logger.ofType(ApiLogEventType.response).single;
        expect(requestEvent, isA<ApiRequestLogEvent>());
        expect(responseEvent, isA<ApiResponseLogEvent>());
        expect(requestEvent.data.toString(), contains('[REDACTED]'));
        expect(responseEvent.data.toString(), contains('[REDACTED]'));
        expect(requestEvent.data.toString(), isNot(contains('request-secret')));
        expect(requestEvent.data.toString(), isNot(contains('cookie-secret')));
        expect(responseEvent.data.toString(), isNot(contains('response-secret')));
      } finally {
        await FlutterApiBridge.removeConnection(key);
        await server.close(force: true);
      }
    });

    test('logger exceptions never affect auth transitions', () async {
      final auth = ApiAuth(
        strategy: const NoAuthStrategy(),
        context: AuthStrategyContext(
          connectionKey: 'throwing-logger',
          storageNamespace: 'throwing-logger',
          cookies: ApiCookieManager.memory(
            baseUri: Uri.parse('https://api.example.com'),
          ),
          secureStorage: _MemoryCredentialStorage(),
        ),
        logger: const _ThrowingLogger(),
      );

      await expectLater(auth.initialize(), completes);
      await expectLater(
        auth.initializeUserSession(sessionId: 'session-1'),
        completes,
      );
      expect(auth.current.status, AuthSessionStatus.authenticated);
      await auth.dispose();
    });
  });
}

class _RecordingLogger implements ApiLogger {
  final List<ApiLogEvent> events = <ApiLogEvent>[];

  @override
  void log(ApiLogEvent event) => events.add(event);

  List<ApiLogEvent> ofType(ApiLogEventType type) =>
      events.where((event) => event.type == type).toList(growable: false);
}

class _ThrowingLogger implements ApiLogger {
  const _ThrowingLogger();

  @override
  void log(ApiLogEvent event) => throw StateError('logger failed');
}

class _MemoryCredentialStorage implements ApiCredentialStorage {
  final Map<String, String> _values = <String, String>{};

  @override
  Future<void> delete({required String key}) async => _values.remove(key);

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

class _RealHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context);
}
