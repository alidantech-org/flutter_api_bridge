// lib/server/api/api_client.dart
import 'dart:async';
import 'dart:developer' as dev;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../auth/auth_strategy.dart';
import '../cookies/cookie_manager.dart';

// ─── Auth event streams ──────────────────────────────────────────────────────

/// Emitted when the legacy client receives 401.
class UnauthorizedEvent {
  const UnauthorizedEvent({required this.path});

  final String path;
}

/// Emitted when the legacy client receives 403.
class ForbiddenEvent {
  const ForbiddenEvent({required this.path});

  final String path;
}

class AuthEvents {
  AuthEvents._();

  static final StreamController<UnauthorizedEvent> _unauthorizedController =
      StreamController<UnauthorizedEvent>.broadcast();
  static final StreamController<ForbiddenEvent> _forbiddenController =
      StreamController<ForbiddenEvent>.broadcast();

  static Stream<UnauthorizedEvent> get onUnauthorized =>
      _unauthorizedController.stream;

  static Stream<ForbiddenEvent> get onForbidden => _forbiddenController.stream;

  static void emitUnauthorized(UnauthorizedEvent event) {
    _unauthorizedController.add(event);
  }

  static void emitForbidden(ForbiddenEvent event) {
    _forbiddenController.add(event);
  }

  static Future<void> dispose() async {
    await _unauthorizedController.close();
    await _forbiddenController.close();
  }
}

// ─── Legacy ApiClient ────────────────────────────────────────────────────────

/// Legacy singleton Dio instance factory.
///
/// Generated clients should use a named `ApiConnection` instead. This API is
/// retained for compatibility with applications using `Server.init`.
class ApiClient {
  ApiClient._();

  static String? _baseUrl;
  static AuthStrategy? _authStrategy;
  static final Map<String, Dio> _instances = <String, Dio>{};

  static void init({
    required String baseUrl,
    required AuthStrategy authStrategy,
  }) {
    _baseUrl = baseUrl;
    _authStrategy = authStrategy;
  }

  static Dio instance(String version) {
    assert(
      _baseUrl != null,
      'ApiClient not initialised. Call Server.init() first.',
    );
    return _instances.putIfAbsent(version, () => _create(version));
  }

  static Dio _create(String version) {
    final dio = Dio(
      BaseOptions(
        baseUrl: '$_baseUrl$version',
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
        headers: const <String, String>{
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
      ),
    );

    dio.interceptors.add(CookieManager.interceptor);
    dio.interceptors.add(_LegacyAuthInterceptor(_authStrategy!));

    // Never log request/response bodies or credential-bearing headers. The old
    // LogInterceptor configuration exposed passwords, tokens, cookies, and PII.
    if (kDebugMode) dio.interceptors.add(const _LegacySafeLogInterceptor());

    return dio;
  }

  static void reset() {
    for (final dio in _instances.values) {
      dio.close(force: true);
    }
    _instances.clear();
  }
}

class _LegacyAuthInterceptor extends Interceptor {
  _LegacyAuthInterceptor(this._strategy);

  final AuthStrategy _strategy;

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final noAuth = options.extra['noAuth'] as bool? ?? false;
    if (!noAuth) await _strategy.apply(options);
    handler.next(options);
  }

  @override
  Future<void> onError(
    DioException error,
    ErrorInterceptorHandler handler,
  ) async {
    final path = error.requestOptions.path;
    switch (error.response?.statusCode) {
      case 401:
        AuthEvents.emitUnauthorized(UnauthorizedEvent(path: path));
        await _strategy.onUnauthorized();
      case 403:
        AuthEvents.emitForbidden(ForbiddenEvent(path: path));
    }
    handler.next(error);
  }
}

class _LegacySafeLogInterceptor extends Interceptor {
  const _LegacySafeLogInterceptor();

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    dev.log(
      '${options.method} ${_safeUri(options.uri)}',
      name: 'flutter_api_bridge.legacy',
      level: 800,
    );
    handler.next(options);
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    dev.log(
      '${response.requestOptions.method} '
      '${_safeUri(response.requestOptions.uri)} '
      'status=${response.statusCode}',
      name: 'flutter_api_bridge.legacy',
      level: 800,
    );
    handler.next(response);
  }

  @override
  void onError(DioException error, ErrorInterceptorHandler handler) {
    dev.log(
      '${error.requestOptions.method} '
      '${_safeUri(error.requestOptions.uri)} '
      'status=${error.response?.statusCode} type=${error.type.name}',
      name: 'flutter_api_bridge.legacy',
      level: 900,
      error: error.error ?? error.message,
    );
    handler.next(error);
  }

  Uri _safeUri(Uri uri) => uri.replace(query: '', fragment: '');
}