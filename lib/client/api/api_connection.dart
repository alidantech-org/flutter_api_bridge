import 'dart:async';

import 'package:dio/dio.dart';

import '../auth/api_auth.dart';
import '../auth/auth_config.dart';
import '../auth/auth_session.dart';
import '../auth/auth_storage.dart';
import '../cookies/connection_cookie_store.dart';
import '../logging/api_logging.dart';
import 'api_bridge_config.dart';
import 'api_cache.dart';
import 'api_normalizer.dart';
import 'api_request.dart';
import 'api_request_options.dart';
import 'api_result.dart';

/// One isolated, configured API connection used by generated clients.
class ApiConnection {
  ApiConnection._({
    required this.key,
    required this.config,
    required Dio client,
    required Dio refreshClient,
    required ConnectionCookieStore cookies,
    required ApiLogger logger,
    required this.auth,
  }) : _client = client,
       _refreshClient = refreshClient,
       _cookies = cookies,
       _logger = logger;

  final String key;
  final ApiBridgeConfig config;
  final Dio _client;
  final Dio _refreshClient;
  final ConnectionCookieStore _cookies;
  final ApiLogger _logger;
  final ApiAuth auth;

  bool _disposed = false;
  int _requestSequence = 0;

  static Future<ApiConnection> create({
    required String key,
    required ApiBridgeConfig config,
  }) async {
    config.validate();

    final logger = ApiLogger(connectionKey: key, config: config.logging);
    final cookies = await ConnectionCookieStore.create(
      connectionKey: key,
      baseUri: config.baseUri,
    );
    final client = Dio(_baseOptions(config));
    final refreshClient = Dio(_baseOptions(config));

    client.interceptors.add(cookies.interceptor);
    refreshClient.interceptors.add(cookies.interceptor);

    final credentialStore = config.auth.transport == AuthTransport.bearer
        ? HiveAuthCredentialStore(connectionKey: key, config: config.auth)
        : null;

    final auth = ApiAuth(
      connectionKey: key,
      config: config.auth,
      logger: logger,
      refreshClient: refreshClient,
      cookies: cookies,
      credentialStore: credentialStore,
    );

    final connection = ApiConnection._(
      key: key,
      config: config,
      client: client,
      refreshClient: refreshClient,
      cookies: cookies,
      logger: logger,
      auth: auth,
    );

    client.interceptors.add(
      _ConnectionAuthInterceptor(connection: connection, auth: auth),
    );
    client.interceptors.add(
      _ConnectionLoggingInterceptor(logger: logger, config: config.logging),
    );
    refreshClient.interceptors.add(
      _ConnectionLoggingInterceptor(logger: logger, config: config.logging),
    );

    await auth.initialize();
    logger.log(
      ApiLogLevel.info,
      ApiLogCategory.lifecycle,
      'API connection configured',
      metadata: <String, Object?>{
        'baseUri': config.baseUri,
        'authTransport': config.auth.transport.name,
      },
    );
    return connection;
  }

  static BaseOptions _baseOptions(ApiBridgeConfig config) {
    return BaseOptions(
      baseUrl: config.baseUri.toString(),
      connectTimeout: config.connectTimeout,
      sendTimeout: config.sendTimeout,
      receiveTimeout: config.receiveTimeout,
      headers: Map<String, String>.from(config.defaultHeaders),
      followRedirects: config.followRedirects,
      maxRedirects: config.maxRedirects,
      receiveDataWhenStatusError: true,
    );
  }

  /// Executes a generated request and always returns [ApiResult].
  Future<ApiResult<T>> execute<T>(ApiRequest<T> request) async {
    _ensureActive();

    return switch (request) {
      GetRequest<T> value => _get(value),
      PostRequest<T> value => _mutate(value, 'POST', value.body),
      PutRequest<T> value => _mutate(value, 'PUT', value.body),
      PatchRequest<T> value => _mutate(value, 'PATCH', value.body),
      DeleteRequest<T> value => _mutate(value, 'DELETE', value.body),
      UploadRequest<T> value => _upload(value),
      _ => ApiError<T>(
        message: 'Unsupported request type',
        error: 'Unsupported request type: ${request.runtimeType}',
      ),
    };
  }

  Future<ApiResult<T>> _get<T>(GetRequest<T> request) async {
    final cacheKey = _cacheKey(request.cacheKey);
    try {
      if (request.invalidateCache) {
        await ApiCache.invalidate(cacheKey);
      }

      if (request.cache && !request.forceRefresh) {
        final cached = ApiCache.read(cacheKey);
        final cachedRaw = asResponseMap(cached);
        if (cachedRaw != null) {
          _logger.log(
            ApiLogLevel.debug,
            ApiLogCategory.cache,
            'GET response served from cache',
            metadata: <String, Object?>{'cacheKey': request.cacheKey},
          );
          return _parse<T>(
            responseBody: cachedRaw,
            statusCode: 200,
            fromJson: request.fromJson,
            fullRaw: cachedRaw,
          );
        }
      }

      final response = await _client.get<dynamic>(
        request.fullPath,
        queryParameters: buildDioQueryParameters(request.query),
        options: _requestOptions(request),
      );
      await _synchronizeCookieAuth();

      final raw = asResponseMap(response.data);
      if (request.cache && raw != null) {
        await ApiCache.write(
          cacheKey,
          raw,
          request.cacheTtl ?? config.defaultCacheTtl,
        );
      }

      return _parse<T>(
        responseBody: response.data,
        statusCode: response.statusCode ?? 200,
        fromJson: request.fromJson,
        fullRaw: raw,
      );
    } on DioException catch (error) {
      return _handleDioError<T>(error);
    } catch (error, stackTrace) {
      return _handleUnexpected<T>(error, stackTrace);
    }
  }

  Future<ApiResult<T>> _mutate<T>(
    ApiRequest<T> request,
    String method,
    Object? body,
  ) async {
    try {
      final response = await _client.request<dynamic>(
        request.fullPath,
        data: _prepareBody(body),
        queryParameters: buildDioQueryParameters(request.query),
        options: _requestOptions(request, method: method),
      );
      await _synchronizeCookieAuth();

      final raw = asResponseMap(response.data);
      return _parse<T>(
        responseBody: response.data,
        statusCode: response.statusCode ?? 200,
        fromJson: request.fromJson,
        fullRaw: raw,
      );
    } on DioException catch (error) {
      return _handleDioError<T>(error);
    } catch (error, stackTrace) {
      return _handleUnexpected<T>(error, stackTrace);
    }
  }

  Future<ApiResult<T>> _upload<T>(UploadRequest<T> request) async {
    try {
      final formData = FormData();
      final fields = request.fields;
      if (fields != null) formData.fields.addAll(fields.entries);
      for (final file in request.files) {
        formData.files.add(await file.toMultipart());
      }

      final response = await _client.request<dynamic>(
        request.fullPath,
        data: formData,
        queryParameters: buildDioQueryParameters(request.query),
        options: _requestOptions(
          request,
          method: request.method.httpMethod,
          contentType: Headers.multipartFormDataContentType,
          retryOverride: false,
        ),
      );
      await _synchronizeCookieAuth();

      final raw = asResponseMap(response.data);
      return _parse<T>(
        responseBody: response.data,
        statusCode: response.statusCode ?? 200,
        fromJson: request.fromJson,
        fullRaw: raw,
      );
    } on DioException catch (error) {
      return _handleDioError<T>(error);
    } catch (error, stackTrace) {
      return _handleUnexpected<T>(error, stackTrace);
    }
  }

  Options _requestOptions(
    ApiRequest<dynamic> request, {
    String? method,
    String? contentType,
    bool? retryOverride,
  }) {
    final requestId = _nextRequestId();
    final requestOptions = request.options;
    final usesAuthentication = requestOptions?.usesAuthentication ?? true;
    final retry =
        retryOverride ?? (requestOptions?.retryOnUnauthorized ?? true);

    return Options(
      method: method,
      headers: request.headers,
      contentType: contentType,
      extra: <String, Object?>{
        'bridge.noAuth': !usesAuthentication,
        'bridge.retryOnUnauthorized': retry,
        'bridge.retryCount': 0,
        'bridge.requestId': requestId,
      },
    );
  }

  String _nextRequestId() {
    _requestSequence += 1;
    return '$key-${DateTime.now().toUtc().microsecondsSinceEpoch}-$_requestSequence';
  }

  String _cacheKey(String value) => 'connection:$key:$value';

  Object? _prepareBody(Object? body) {
    if (body == null ||
        body is FormData ||
        body is MultipartFile ||
        body is List<int> ||
        body is String ||
        body is num ||
        body is bool) {
      return body;
    }
    return normalizeBody(body);
  }

  ApiResult<T> _parse<T>({
    required dynamic responseBody,
    required int statusCode,
    required T Function(dynamic json)? fromJson,
    required Map<String, dynamic>? fullRaw,
  }) {
    final message = _extractMessage(fullRaw);
    if (fromJson == null || responseBody == null) {
      return ApiSuccess<T>(
        message: message,
        statusCode: statusCode,
        data: null,
        raw: fullRaw,
      );
    }

    try {
      return ApiSuccess<T>(
        message: message,
        statusCode: statusCode,
        data: fromJson(responseBody),
        raw: fullRaw,
      );
    } catch (error, stackTrace) {
      _logger.log(
        ApiLogLevel.error,
        ApiLogCategory.parsing,
        'Could not parse API response',
        statusCode: statusCode,
        error: error,
        stackTrace: stackTrace,
      );
      return ApiError<T>(
        message: message.isEmpty ? 'Failed to parse response' : message,
        error: 'Failed to parse response: $error',
        statusCode: statusCode,
        raw: fullRaw,
      );
    }
  }

  ApiResult<T> _handleDioError<T>(DioException error) {
    final raw = asResponseMap(error.response?.data);
    final message = _extractMessage(
      raw,
      fallback: error.response?.statusMessage ?? 'Request failed',
    );
    return ApiError<T>(
      message: message,
      error: _extractDioError(error, raw),
      statusCode: error.response?.statusCode,
      raw: raw,
    );
  }

  ApiResult<T> _handleUnexpected<T>(Object error, StackTrace stackTrace) {
    _logger.log(
      ApiLogLevel.error,
      ApiLogCategory.request,
      'Unexpected API execution failure',
      error: error,
      stackTrace: stackTrace,
    );
    return ApiError<T>(
      message: 'An unexpected error occurred',
      error: error.toString(),
    );
  }

  String _extractMessage(Map<String, dynamic>? raw, {String fallback = ''}) {
    final value = raw?['message'];
    if (value is String) return value;
    if (value is List) return value.whereType<String>().join(', ');
    return fallback;
  }

  String _extractDioError(DioException error, Map<String, dynamic>? raw) {
    final rawError = raw?['error'];
    if (rawError is String && rawError.trim().isNotEmpty) return rawError;

    final errors = raw?['errors'];
    if (errors is String && errors.trim().isNotEmpty) return errors;
    if (errors is List && errors.isNotEmpty) {
      return errors.map((item) => item.toString()).join(', ');
    }
    return error.message ?? error.type.name;
  }

  Future<void> _synchronizeCookieAuth() async {
    if (config.auth.transport == AuthTransport.cookies) {
      await auth.synchronize();
    }
  }

  Future<void> clearCache() {
    return ApiCache.invalidateWhere('connection:$key:');
  }

  Future<void> logout({String reason = 'logout'}) async {
    _ensureActive();
    await auth.clear(reason: reason);
    await clearCache();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await auth.dispose();
    _client.close(force: true);
    _refreshClient.close(force: true);
    _logger.log(
      ApiLogLevel.info,
      ApiLogCategory.lifecycle,
      'API connection disposed',
    );
  }

  void _ensureActive() {
    if (_disposed) {
      throw StateError('ApiConnection $key has been disposed.');
    }
  }
}

class _ConnectionAuthInterceptor extends Interceptor {
  _ConnectionAuthInterceptor({required this.connection, required this.auth});

  final ApiConnection connection;
  final ApiAuth auth;

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final noAuth = options.extra['bridge.noAuth'] == true;
    if (noAuth) {
      options.extra['bridge.authApplied'] = false;
      handler.next(options);
      return;
    }

    try {
      await auth.apply(options);
      options.extra['bridge.authRevision'] = auth.current.revision;
      handler.next(options);
    } catch (error, stackTrace) {
      handler.reject(
        DioException(
          requestOptions: options,
          error: error,
          stackTrace: stackTrace,
          type: DioExceptionType.unknown,
        ),
      );
    }
  }

  @override
  Future<void> onError(
    DioException error,
    ErrorInterceptorHandler handler,
  ) async {
    final status = error.response?.statusCode;
    if (status == null) {
      handler.next(error);
      return;
    }

    final options = error.requestOptions;
    final requestId =
        options.extra['bridge.requestId']?.toString() ?? 'unknown';
    final authWasApplied = options.extra['bridge.authApplied'] == true;

    if (status == 403) {
      auth.recordFailure(
        AuthFailureEvent(
          statusCode: status,
          path: options.path,
          requestId: requestId,
          authWasApplied: authWasApplied,
        ),
      );
      handler.next(error);
      return;
    }

    if (!auth.config.unauthorizedStatusCodes.contains(status)) {
      handler.next(error);
      return;
    }

    auth.recordFailure(
      AuthFailureEvent(
        statusCode: status,
        path: options.path,
        requestId: requestId,
        authWasApplied: authWasApplied,
      ),
    );

    final skipRefresh = options.extra['bridge.skipAuthRefresh'] == true;
    final retryAllowed = options.extra['bridge.retryOnUnauthorized'] == true;
    final retryCount = options.extra['bridge.retryCount'] as int? ?? 0;

    if (skipRefresh || !retryAllowed || retryCount >= 1 || !authWasApplied) {
      if (authWasApplied && retryCount >= 1) {
        await auth.markExpired(reason: 'unauthorized_after_refresh');
      }
      handler.next(error);
      return;
    }

    try {
      final requestRevision =
          options.extra['bridge.authRevision'] as int? ?? -1;
      final credentialsAlreadyChanged =
          auth.current.isAuthenticated &&
          auth.current.revision != requestRevision;
      final refreshed =
          credentialsAlreadyChanged ||
          await auth.refresh(reason: 'http_$status');

      if (!refreshed) {
        handler.next(error);
        return;
      }

      options.extra['bridge.retryCount'] = retryCount + 1;
      options.extra['bridge.authRevision'] = auth.current.revision;
      await auth.prepareRetry(options);

      final response = await connection._client.fetch<dynamic>(options);
      handler.resolve(response);
    } catch (_) {
      handler.next(error);
    }
  }
}

class _ConnectionLoggingInterceptor extends Interceptor {
  _ConnectionLoggingInterceptor({required this.logger, required this.config});

  final ApiLogger logger;
  final ApiLoggingConfig config;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.extra['bridge.startedAt'] = DateTime.now().toUtc();
    final requestId = options.extra['bridge.requestId']?.toString();

    logger.log(
      ApiLogLevel.info,
      ApiLogCategory.request,
      'HTTP request started',
      requestId: requestId,
      method: options.method,
      uri: options.uri,
      metadata: <String, Object?>{
        if (options.queryParameters.isNotEmpty)
          'query': logger.redactor.value(options.queryParameters),
        if (config.logRequestHeaders)
          'headers': logger.redactor.headers(options.headers),
        if (config.logRequestBody) 'body': logger.redactor.body(options.data),
        'retryCount': options.extra['bridge.retryCount'] ?? 0,
        'authApplied': options.extra['bridge.authApplied'] == true,
      },
    );
    handler.next(options);
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    final options = response.requestOptions;
    final startedAt = options.extra['bridge.startedAt'];
    final duration = startedAt is DateTime
        ? DateTime.now().toUtc().difference(startedAt)
        : null;

    logger.log(
      ApiLogLevel.info,
      ApiLogCategory.response,
      'HTTP request completed',
      requestId: options.extra['bridge.requestId']?.toString(),
      method: options.method,
      uri: options.uri,
      statusCode: response.statusCode,
      duration: duration,
      metadata: <String, Object?>{
        if (config.logResponseHeaders)
          'headers': logger.redactor.value(response.headers.map),
        if (config.logResponseBody) 'body': logger.redactor.body(response.data),
      },
    );
    handler.next(response);
  }

  @override
  void onError(DioException error, ErrorInterceptorHandler handler) {
    final options = error.requestOptions;
    final startedAt = options.extra['bridge.startedAt'];
    final duration = startedAt is DateTime
        ? DateTime.now().toUtc().difference(startedAt)
        : null;

    logger.log(
      error.response == null ? ApiLogLevel.error : ApiLogLevel.warning,
      ApiLogCategory.response,
      'HTTP request failed',
      requestId: options.extra['bridge.requestId']?.toString(),
      method: options.method,
      uri: options.uri,
      statusCode: error.response?.statusCode,
      duration: duration,
      metadata: <String, Object?>{
        'type': error.type.name,
        if (config.logResponseHeaders && error.response != null)
          'headers': logger.redactor.value(error.response!.headers.map),
        if (config.logResponseBody && error.response != null)
          'body': logger.redactor.body(error.response!.data),
      },
      error: error.error ?? error.message,
      stackTrace: error.stackTrace,
    );
    handler.next(error);
  }
}

extension on UploadMethod {
  String get httpMethod {
    return switch (this) {
      UploadMethod.post => 'POST',
      UploadMethod.put => 'PUT',
      UploadMethod.patch => 'PATCH',
    };
  }
}
