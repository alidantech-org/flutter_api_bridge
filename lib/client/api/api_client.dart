import 'dart:async';

import 'package:dio/dio.dart';

import '../auth/api_auth.dart';
import '../auth/auth_strategy.dart';
import '../cookies/cookie_manager.dart';
import '../logging/api_logger.dart';

/// Legacy compatibility event emitted when the server returns 401.
class UnauthorizedEvent {
  const UnauthorizedEvent({required this.path});
  final String path;
}

/// Legacy compatibility event emitted when the server returns 403.
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

  static void emitUnauthorized(UnauthorizedEvent event) =>
      _unauthorizedController.add(event);
  static void emitForbidden(ForbiddenEvent event) =>
      _forbiddenController.add(event);

  static Future<void> dispose() async {
    await _unauthorizedController.close();
    await _forbiddenController.close();
  }
}

/// Singleton Dio instance factory used by the legacy [Server] API.
class ApiClient {
  ApiClient._();

  static String? _baseUrl;
  static AuthStrategy? _authStrategy;
  static ApiAuth? _auth;
  static ApiLogger _logger = const DeveloperApiLogger();
  static ApiLoggingConfig _logging = const ApiLoggingConfig();
  static final Map<String, Dio> _instances = <String, Dio>{};

  static void init({
    required String baseUrl,
    required AuthStrategy authStrategy,
    required ApiAuth auth,
    ApiLogger logger = const DeveloperApiLogger(),
    ApiLoggingConfig logging = const ApiLoggingConfig(),
  }) {
    _baseUrl = baseUrl;
    _authStrategy = authStrategy;
    _auth = auth;
    _logger = logger;
    _logging = logging;
  }

  static Dio instance(String version) {
    if (_baseUrl == null || _authStrategy == null || _auth == null) {
      throw StateError('ApiClient is not initialised. Call Server.init() first.');
    }
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
    dio.interceptors.add(_AuthInterceptor(_authStrategy!, _auth!));
    if (_logging.enabled) {
      dio.interceptors.add(
        _StructuredLoggingInterceptor(
          logger: _logger,
          config: _logging,
        ),
      );
    }
    return dio;
  }

  static void reset() => _instances.clear();
}

class _AuthInterceptor extends Interceptor {
  _AuthInterceptor(this._strategy, this._auth);

  final AuthStrategy _strategy;
  final ApiAuth _auth;

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
  void onError(DioException error, ErrorInterceptorHandler handler) {
    final path = error.requestOptions.path;
    switch (error.response?.statusCode) {
      case 401:
        AuthEvents.emitUnauthorized(UnauthorizedEvent(path: path));
        unawaited(_auth.expire(reason: 'http_401'));
      case 403:
        AuthEvents.emitForbidden(ForbiddenEvent(path: path));
    }
    handler.next(error);
  }
}

class _StructuredLoggingInterceptor extends Interceptor {
  _StructuredLoggingInterceptor({
    required ApiLogger logger,
    required ApiLoggingConfig config,
  })  : _logger = logger,
        _config = config,
        _redactor = ApiLogRedactor(config.sensitiveKeys);

  static const String _startedAtKey = 'flutter_api_bridge.started_at';

  final ApiLogger _logger;
  final ApiLoggingConfig _config;
  final ApiLogRedactor _redactor;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.extra[_startedAtKey] = DateTime.now().toUtc();
    _logger.log(
      ApiLogEvent(
        level: ApiLogLevel.debug,
        type: ApiLogEventType.request,
        message: 'API request',
        timestamp: DateTime.now().toUtc(),
        method: options.method,
        path: options.uri.toString(),
        data: <String, Object?>{
          if (_config.logRequestHeaders)
            'headers': _redactor.redact(options.headers),
          if (_config.logRequestBody) 'body': _redactor.redact(options.data),
          if (options.queryParameters.isNotEmpty)
            'query': _redactor.redact(options.queryParameters),
        },
      ),
    );
    handler.next(options);
  }

  @override
  void onResponse(Response<dynamic> response, ResponseInterceptorHandler handler) {
    _logger.log(
      ApiLogEvent(
        level: ApiLogLevel.info,
        type: ApiLogEventType.response,
        message: 'API response',
        timestamp: DateTime.now().toUtc(),
        method: response.requestOptions.method,
        path: response.requestOptions.uri.toString(),
        statusCode: response.statusCode,
        duration: _duration(response.requestOptions),
        data: <String, Object?>{
          if (_config.logResponseBody)
            'body': _redactor.redact(response.data),
        },
      ),
    );
    handler.next(response);
  }

  @override
  void onError(DioException error, ErrorInterceptorHandler handler) {
    _logger.log(
      ApiLogEvent(
        level: ApiLogLevel.error,
        type: ApiLogEventType.failure,
        message: 'API request failed',
        timestamp: DateTime.now().toUtc(),
        method: error.requestOptions.method,
        path: error.requestOptions.uri.toString(),
        statusCode: error.response?.statusCode,
        duration: _duration(error.requestOptions),
        data: <String, Object?>{
          'type': error.type.name,
          if (_config.logResponseBody)
            'response': _redactor.redact(error.response?.data),
        },
        error: error.message,
        stackTrace: error.stackTrace,
      ),
    );
    handler.next(error);
  }

  Duration? _duration(RequestOptions options) {
    final startedAt = options.extra[_startedAtKey];
    if (startedAt is! DateTime) return null;
    return DateTime.now().toUtc().difference(startedAt);
  }
}
