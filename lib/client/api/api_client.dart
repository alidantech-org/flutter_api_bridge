// lib/server/api/api_client.dart
import 'dart:async';
import 'dart:developer' as dev;
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../auth/auth_strategy.dart';
import '../cookies/cookie_manager.dart';

// ─── Auth event streams ────────────────────────────────────────────────────────

/// Emitted when the server returns 401 — app should refresh token or logout.
class UnauthorizedEvent {
  const UnauthorizedEvent({required this.path});
  final String path;
}

/// Emitted when the server returns 403.
class ForbiddenEvent {
  const ForbiddenEvent({required this.path});
  final String path;
}

class AuthEvents {
  AuthEvents._();

  static final _unauthorizedController =
      StreamController<UnauthorizedEvent>.broadcast();
  static final _forbiddenController =
      StreamController<ForbiddenEvent>.broadcast();

  static Stream<UnauthorizedEvent> get onUnauthorized =>
      _unauthorizedController.stream;
  static Stream<ForbiddenEvent> get onForbidden => _forbiddenController.stream;

  static void emitUnauthorized(UnauthorizedEvent e) =>
      _unauthorizedController.add(e);
  static void emitForbidden(ForbiddenEvent e) => _forbiddenController.add(e);

  static Future<void> dispose() async {
    await _unauthorizedController.close();
    await _forbiddenController.close();
  }
}

// ─── ApiClient ─────────────────────────────────────────────────────────────────

/// Singleton Dio instance factory.
/// One instance per [ApiVersion] — all share the same auth strategy and
/// cookie jar. Instances are cached so repeated access is free.
class ApiClient {
  ApiClient._();

  static String? _baseUrl;
  static AuthStrategy? _authStrategy;
  static final Map<String, Dio> _instances = {};

  /// Internal — called by [Server.init].
  static void init(
      {required String baseUrl, required AuthStrategy authStrategy}) {
    _baseUrl = baseUrl;
    _authStrategy = authStrategy;
  }

  /// Returns the Dio instance for [version].
  /// Creates it on first access, returns cached instance thereafter.
  static Dio instance(String version) {
    assert(_baseUrl != null,
        'ApiClient not initialised. Call Server.init() first.');
    return _instances.putIfAbsent(version, () => _create(version));
  }

  static Dio _create(String version) {
    final dio = Dio(
      BaseOptions(
        baseUrl: '$_baseUrl${version}',
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json'
        },
      ),
    );

    // Cookie jar — handles backend-set cookies automatically
    dio.interceptors.add(CookieManager.interceptor);

    // Auth interceptor
    dio.interceptors.add(_AuthInterceptor(_authStrategy!));

    // Debug logger — stripped in release
    if (kDebugMode) {
      dio.interceptors.add(
        LogInterceptor(
          requestBody: true,
          responseBody: true,
          logPrint: (o) => dev.log(o.toString(), name: 'server/dio'),
        ),
      );
    }

    return dio;
  }

  /// Discard all cached instances — useful after logout.
  static void reset() => _instances.clear();
}

// ─── Auth interceptor ─────────────────────────────────────────────────────────

class _AuthInterceptor extends Interceptor {
  _AuthInterceptor(this._strategy);

  final AuthStrategy _strategy;

  @override
  Future<void> onRequest(
      RequestOptions options, RequestInterceptorHandler handler) async {
    final noAuth = options.extra['noAuth'] as bool? ?? false;
    if (!noAuth) await _strategy.apply(options);
    handler.next(options);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final path = err.requestOptions.path;
    switch (err.response?.statusCode) {
      case 401:
        AuthEvents.emitUnauthorized(UnauthorizedEvent(path: path));
        _strategy.onUnauthorized();
      case 403:
        AuthEvents.emitForbidden(ForbiddenEvent(path: path));
    }
    handler.next(err);
  }
}
