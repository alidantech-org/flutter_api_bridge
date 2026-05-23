import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_api_bridge/flutter_api_bridge.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';

void main() {
  late Directory hiveDirectory;

  const jsonPlaceholderTodo = <String, Object?>{
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
    await ApiCache.init();
  });

  tearDown(() async {
    await ApiCache.clearAll();
    await BearerStrategy.clearToken(key: 'access_token');
  });

  tearDownAll(() async {
    await Hive.close();
    if (await hiveDirectory.exists()) {
      await hiveDirectory.delete(recursive: true);
    }
  });

  group('ApiResult', () {
    test('ApiSuccess exposes parsed response details', () {
      const result = ApiSuccess<Map<String, Object?>>(
        message: 'Loaded',
        statusCode: 200,
        data: jsonPlaceholderTodo,
        raw: {'message': 'Loaded', 'data': jsonPlaceholderTodo},
      );

      expect(result.isSuccess, isTrue);
      expect(result.isError, isFalse);
      expect(result.message, 'Loaded');
      expect(result.dataOrNull, jsonPlaceholderTodo);

      final statusCode = result.when(
        success: (_, __, statusCode) => statusCode,
        error: (_, __, ___) => -1,
      );
      expect(statusCode, 200);
    });

    test('ApiError exposes error details and helper callbacks', () {
      const result = ApiError<Map<String, Object?>>(
        message: 'Request failed',
        error: 'Not found',
        statusCode: 404,
        raw: {'message': 'Request failed'},
      );

      var handledError = '';
      result.ifError((error, _) => handledError = error);

      expect(result.isSuccess, isFalse);
      expect(result.isError, isTrue);
      expect(result.dataOrNull, isNull);
      expect(result.message, 'Request failed');
      expect(handledError, 'Not found');
    });
  });

  group('ApiEnvelope', () {
    test('parses common fields from JSON-style API responses', () {
      final envelope = ApiEnvelope.fromResponse({
        'success': true,
        'message': 'Todo loaded',
        'data': jsonPlaceholderTodo,
      });

      expect(envelope.success, isTrue);
      expect(envelope.message, 'Todo loaded');
      expect(envelope.raw?['data'], jsonPlaceholderTodo);
    });

    test('treats non-map response bodies as successful empty envelopes', () {
      final envelope = ApiEnvelope.fromResponse(['todo']);

      expect(envelope.success, isTrue);
      expect(envelope.message, isEmpty);
      expect(envelope.raw, isNull);
    });
  });

  group('ApiRequest', () {
    test('GetRequest builds versioned paths and cache keys', () {
      const request = GetRequest<Map<String, Object?>>(
        endpoint: '/todos',
        version: '/v1',
        query: {'userId': 1, 'completed': false},
        options: ApiGetRequestOptions(
          cache: true,
          cacheTtl: Duration(minutes: 10),
          forceRefresh: true,
          noAuth: true,
          headers: {'x-client': 'test'},
        ),
      );

      expect(request.fullPath, '/v1/todos');
      expect(request.cacheKey, '/v1/todosuserId=1&completed=false');
      expect(request.cache, isTrue);
      expect(request.cacheTtl, const Duration(minutes: 10));
      expect(request.forceRefresh, isTrue);
      expect(request.noAuth, isTrue);
      expect(request.headers, {'x-client': 'test'});
    });

    test('mutation requests keep body, query, options, and parser', () {
      final request = PostRequest<Map<String, Object?>>(
        endpoint: '/posts',
        query: const {'draft': true},
        body: const {'title': 'Hello'},
        options: const ApiRequestOptions(noAuth: true),
        fromJson: (json) => Map<String, Object?>.from(json as Map),
      );

      expect(request.endpoint, '/posts');
      expect(request.query, {'draft': true});
      expect(request.body, {'title': 'Hello'});
      expect(request.noAuth, isTrue);
      expect(request.fromJson!(jsonPlaceholderTodo), jsonPlaceholderTodo);
    });
  });

  group('ApiCache', () {
    test('writes, reads, invalidates, and clears cached JSON payloads',
        () async {
      await ApiCache.write(
        '/todos/1',
        jsonPlaceholderTodo,
        const Duration(minutes: 5),
      );

      expect(ApiCache.read('/todos/1'), jsonPlaceholderTodo);

      await ApiCache.invalidate('/todos/1');
      expect(ApiCache.read('/todos/1'), isNull);

      await ApiCache.write(
        '/todos/1',
        jsonPlaceholderTodo,
        const Duration(minutes: 5),
      );
      await ApiCache.clearAll();
      expect(ApiCache.read('/todos/1'), isNull);
    });

    test('invalidates by endpoint pattern and evicts expired entries',
        () async {
      await ApiCache.write(
        '/todos/1',
        jsonPlaceholderTodo,
        const Duration(minutes: 5),
      );
      await ApiCache.write(
        '/users/1',
        {'id': 1, 'name': 'Leanne Graham'},
        const Duration(minutes: 5),
      );

      await ApiCache.invalidateWhere('/todos');

      expect(ApiCache.read('/todos/1'), isNull);
      expect(ApiCache.read('/users/1'), {'id': 1, 'name': 'Leanne Graham'});

      await ApiCache.write(
        '/expired',
        {'stale': true},
        const Duration(milliseconds: -1),
      );

      expect(ApiCache.read('/expired'), isNull);
    });
  });

  group('Auth strategies', () {
    test('BearerStrategy persists token and applies authorization header',
        () async {
      await BearerStrategy.saveToken('abc123', key: 'access_token');

      final options = RequestOptions(path: '/todos/1');
      await BearerStrategy(tokenKey: 'access_token').apply(options);

      expect(options.headers['Authorization'], 'Bearer abc123');

      await BearerStrategy.clearToken(key: 'access_token');

      final clearedOptions = RequestOptions(path: '/todos/1');
      await BearerStrategy(tokenKey: 'access_token').apply(clearedOptions);

      expect(clearedOptions.headers, isNot(contains('Authorization')));
    });

    test('ApiKeyStrategy applies x-api-key header', () async {
      final options = RequestOptions(path: '/todos/1');

      await const ApiKeyStrategy(apiKey: 'secret').apply(options);

      expect(options.headers['x-api-key'], 'secret');
    });

    test('CookieStrategy leaves headers untouched', () async {
      final options = RequestOptions(path: '/todos/1');

      await const CookieStrategy().apply(options);

      expect(options.headers, isEmpty);
    });
  });

  group('Events', () {
    test('AuthEvents emits unauthorized and forbidden events', () async {
      final unauthorized = expectLater(
        AuthEvents.onUnauthorized,
        emits(isA<UnauthorizedEvent>()
            .having((event) => event.path, 'path', '/private')),
      );
      final forbidden = expectLater(
        AuthEvents.onForbidden,
        emits(isA<ForbiddenEvent>()
            .having((event) => event.path, 'path', '/admin')),
      );

      AuthEvents.emitUnauthorized(const UnauthorizedEvent(path: '/private'));
      AuthEvents.emitForbidden(const ForbiddenEvent(path: '/admin'));

      await unauthorized;
      await forbidden;
    });

    test('CookieEvents filters named cookie updates', () async {
      final refreshToken = expectLater(
        CookieEvents.onCookieSet('refresh_token'),
        emits(
          isA<CookieChangedEvent>()
              .having((event) => event.name, 'name', 'refresh_token')
              .having((event) => event.value, 'value', 'cookie-value'),
        ),
      );

      CookieEvents.emitChanged(
        const CookieChangedEvent(
          name: 'refresh_token',
          value: 'cookie-value',
          domain: 'example.com',
        ),
      );

      await refreshToken;
    });
  });

  group('Uploads', () {
    test('UploadProgress reports ratios, sizes, completion, and text', () {
      const progress = UploadProgress(sent: 75, total: 100);
      const done = UploadProgress.done(100);
      const idle = UploadProgress.idle();

      expect(progress.percent, 0.75);
      expect(progress.isDone, isFalse);
      expect(progress.sentMB, closeTo(0.0000715, 0.000001));
      expect(done.percent, 1);
      expect(done.isDone, isTrue);
      expect(idle.percent, 0);
      expect(progress.toString(), contains('75.0%'));
    });

    test('UploadFile converts bytes and streams to multipart files', () async {
      final bytesFile = await const UploadFile.fromBytes(
        field: 'photo',
        bytes: [1, 2, 3],
        filename: 'todo.png',
      ).toMultipart();

      final streamFile = await UploadFile.fromStream(
        field: 'document',
        stream: Stream<List<int>>.value([4, 5, 6, 7]),
        filename: 'todo.txt',
        length: 4,
      ).toMultipart();

      expect(bytesFile.key, 'photo');
      expect(bytesFile.value.filename, 'todo.png');
      expect(bytesFile.value.length, 3);
      expect(streamFile.key, 'document');
      expect(streamFile.value.filename, 'todo.txt');
      expect(streamFile.value.length, 4);
    });

    test('UploadRequest keeps files, fields, method, and options', () {
      const request = UploadRequest<Map<String, Object?>>(
        endpoint: '/uploads',
        version: '/v1',
        files: [
          UploadFile.fromBytes(
            field: 'photo',
            bytes: [1],
            filename: 'todo.png',
          ),
        ],
        fields: {'title': 'Todo'},
        method: UploadMethod.put,
        options: ApiRequestOptions(
          noAuth: true,
          headers: {'x-upload': 'yes'},
        ),
      );

      expect(request.fullPath, '/v1/uploads');
      expect(request.files, hasLength(1));
      expect(request.fields, {'title': 'Todo'});
      expect(request.method, UploadMethod.put);
      expect(request.noAuth, isTrue);
      expect(request.headers, {'x-upload': 'yes'});
    });
  });
}
