import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';

import '../api/api_cache.dart';
import '../api/api_normalizer.dart';
import '../api/api_request.dart';
import '../api/api_request_options.dart';
import '../api/api_result.dart';
import '../auth/api_auth.dart';
import '../auth/auth_strategy.dart';
import '../config/api_bridge_config.dart';
import '../cookies/cookie_manager.dart';
import '../logging/api_logger.dart';

/// One isolated API runtime used by a generated package.
class ApiConnection {
  ApiConnection._({
    required this.key,
    required this.config,
    required Dio dio,
    required this.auth,
    required this.cache,
    required this.cookies,
    required ApiClientIdentity? identity,
  })  : _dio = dio,
        _identity = identity;

  final String key;
  final ApiBridgeConfig config;
  final Dio _dio;
  final ApiAuth auth;
  final ApiCache cache;
  final ApiCookieManager cookies;
  final ApiClientIdentity? _identity;

  /// Escape hatch for legacy integrations. Generated packages should use
  /// [execute] so caching, retries, diagnostics, and invalidation remain active.
  Dio get rawDio => _dio;

  static int _requestSequence = 0;
  bool _disposed = false;

  static Future<ApiConnection> create({
    required String key,
    required ApiBridgeConfig config,
  }) async {
    final cleanKey = key.trim();
    if (cleanKey.isEmpty) {
      throw ArgumentError.value(key, 'key', 'Connection key cannot be empty.');
    }

    final cookieManager = await ApiCookieManager.create(
      connectionKey: cleanKey,
      baseUri: config.baseUri,
    );
    final cache = await ApiCache.create(
      connectionKey: cleanKey,
      baseUri: config.baseUri,
      config: config.cache,
    );
    const secureStorage = FlutterApiCredentialStorage();
    final authContext = AuthStrategyContext(
      connectionKey: cleanKey,
      storageNamespace: _safeNamespace(
        '$cleanKey|${config.baseUri.scheme}://${config.baseUri.authority}',
      ),
      cookies: cookieManager,
      secureStorage: secureStorage,
    );
    final auth = ApiAuth(
      strategy: config.auth,
      context: authContext,
      logger: config.logger,
      logging: config.logging,
    );
    final identity = await config.clientIdentity?.call();
    final dio = Dio(
      BaseOptions(
        baseUrl: config.baseUri.toString(),
        connectTimeout: config.connectTimeout,
        sendTimeout: config.sendTimeout,
        receiveTimeout: config.receiveTimeout,
        headers: <String, String>{
          'Accept': 'application/json',
          'Content-Type': 'application/json',
          ...config.defaultHeaders,
          ...?identity?.toHeaders(),
        },
      ),
    );

    if (config.cookiesEnabled) {
      dio.interceptors.add(cookieManager.interceptor);
    }
    dio.interceptors.add(
      _ConnectionRequestInterceptor(
        auth: auth,
        cookies: cookieManager,
        cookiesEnabled: config.cookiesEnabled,
      ),
    );

    final connection = ApiConnection._(
      key: cleanKey,
      config: config,
      dio: dio,
      auth: auth,
      cache: cache,
      cookies: cookieManager,
      identity: identity,
    );
    final restored = await auth.initialize();
    await cache.startSession(
      sessionId: restored.sessionId ?? 'anonymous',
      clearPreviousOnChange: false,
    );
    return connection;
  }

  /// Initializes the active user/cache session after generated login succeeds.
  Future<void> initializeUserSession({
    required String sessionId,
    String? bearerToken,
    Map<String, String>? authHeaders,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) async {
    _ensureActive();
    await cache.startSession(sessionId: sessionId, metadata: metadata);
    await auth.initializeUserSession(
      sessionId: sessionId,
      bearerToken: bearerToken,
      authHeaders: authHeaders,
    );
  }

  Future<void> clearSessionCache(String sessionId) =>
      cache.clearSession(sessionId);

  Future<void> clearActiveSessionCache() => cache.clearActiveSession();

  Future<void> clearAllCache() => cache.clearAll();

  /// Clears all connection cache, credentials, and cookies.
  Future<void> logout() async {
    _ensureActive();
    await cache.clearAll();
    await auth.clear();
    if (config.cookiesEnabled) await cookies.clearAll();
    await cache.startSession(
      sessionId: 'anonymous',
      clearPreviousOnChange: false,
    );
  }

  Future<ApiResult<T>> execute<T>(ApiRequest<T> request) async {
    _ensureActive();
    if (request is GetRequest<T>) return _executeGet(request);
    return _executeMutation(request);
  }

  Future<ApiResult<T>> _executeGet<T>(GetRequest<T> request) async {
    final options = request.getOptions;
    final policy = !request.cache || !config.cache.enabled
        ? ApiCachePolicy.disabled
        : request.forceRefresh
            ? ApiCachePolicy.refresh
            : options?.cachePolicy ?? config.cache.defaultPolicy;
    final cacheKey = _cacheKey(request, options);

    if (request.invalidateCache) await cache.invalidate(cacheKey);
    await _applyPreRequestInvalidation(request.options);

    if (policy == ApiCachePolicy.cacheFirst ||
        policy == ApiCachePolicy.cacheOnly) {
      final cached = await cache.read(
        cacheKey,
        allowStale: policy == ApiCachePolicy.cacheOnly,
      );
      if (cached != null) {
        return _parse<T>(
          request: request,
          responseBody: cached.data,
          statusCode: 200,
          meta: _cacheMetadata(request, cached),
        );
      }
      if (policy == ApiCachePolicy.cacheOnly) {
        return ApiError<T>(
          message: 'No cached data is available',
          error: 'cache_miss',
          meta: ApiResultMetadata(
            source: ApiDataSource.hiveCache,
            operationId: request.operationId,
          ),
        );
      }
    }

    final network = await _network<T>(request);
    if (network.result is ApiSuccess<T>) {
      if (policy != ApiCachePolicy.disabled) {
        final success = network.result as ApiSuccess<T>;
        await cache.write(
          cacheKey,
          success.raw ?? network.responseBody,
          ttl: options?.cacheTtl ?? config.cache.defaultTtl,
          tags: options?.cacheTags ?? const <String>[],
        );
      }
      return network.result;
    }

    final allowFallback = policy == ApiCachePolicy.networkFirst ||
        policy == ApiCachePolicy.networkWithStaleFallback ||
        config.cache.allowStaleOnNetworkError;
    if (allowFallback && _isOfflineLike(network.exception)) {
      final cached = await cache.read(
        cacheKey,
        allowStale: policy == ApiCachePolicy.networkWithStaleFallback ||
            config.cache.allowStaleOnNetworkError,
      );
      if (cached != null) {
        _log(
          ApiLogLevel.warning,
          ApiLogEventType.cache,
          'Using cached data after network failure',
          request: request,
          data: <String, Object?>{
            'source': cached.source.name,
            'stale': cached.isStale,
          },
        );
        return _parse<T>(
          request: request,
          responseBody: cached.data,
          statusCode: 200,
          meta: ApiResultMetadata(
            source: cached.isStale
                ? ApiDataSource.staleCache
                : cached.source == ApiCacheSource.memory
                    ? ApiDataSource.memoryCache
                    : ApiDataSource.hiveCache,
            isStale: cached.isStale,
            isOfflineFallback: true,
            operationId: request.operationId,
            receivedAt: cached.storedAt,
            expiresAt: cached.expiresAt,
          ),
        );
      }
    }
    return network.result;
  }

  Future<ApiResult<T>> _executeMutation<T>(ApiRequest<T> request) async {
    final network = await _network<T>(request);
    if (network.result is ApiSuccess<T>) {
      await _applyPostSuccessInvalidation(request.options);
    }
    return network.result;
  }

  Future<_NetworkResult<T>> _network<T>(ApiRequest<T> request) async {
    final requestId = _nextRequestId();
    final maxAttempts = _maxAttempts(request);
    DioException? lastException;

    for (var attempt = 1; attempt <= maxAttempts; attempt += 1) {
      final startedAt = DateTime.now().toUtc();
      try {
        _log(
          ApiLogLevel.debug,
          ApiLogEventType.request,
          'API request',
          request: request,
          requestId: requestId,
          attempt: attempt,
        );
        final response = await _send(request, requestId, attempt);
        final result = _parse<T>(
          request: request,
          responseBody: response.data,
          statusCode: response.statusCode ?? 200,
          meta: ApiResultMetadata(
            source: ApiDataSource.network,
            requestId: requestId,
            operationId: request.operationId,
            receivedAt: DateTime.now().toUtc(),
            attempt: attempt,
          ),
        );
        _log(
          ApiLogLevel.info,
          ApiLogEventType.response,
          'API response',
          request: request,
          requestId: requestId,
          statusCode: response.statusCode,
          duration: DateTime.now().toUtc().difference(startedAt),
          attempt: attempt,
        );
        return _NetworkResult<T>(
          result: result,
          responseBody: response.data,
        );
      } on DioException catch (error) {
        lastException = error;
        if (error.response?.statusCode == 401) {
          unawaited(auth.expire(reason: 'http_401'));
        }
        final canRetry = attempt < maxAttempts && _shouldRetry(request, error);
        _log(
          canRetry ? ApiLogLevel.warning : ApiLogLevel.error,
          canRetry ? ApiLogEventType.retry : ApiLogEventType.failure,
          canRetry ? 'API request will retry' : 'API request failed',
          request: request,
          requestId: requestId,
          statusCode: error.response?.statusCode,
          duration: DateTime.now().toUtc().difference(startedAt),
          attempt: attempt,
          error: error,
          stackTrace: error.stackTrace,
        );
        if (!canRetry) break;
        await Future<void>.delayed(_retryDelay(error, attempt));
      } catch (error, stackTrace) {
        _log(
          ApiLogLevel.error,
          ApiLogEventType.failure,
          'Unexpected API failure',
          request: request,
          requestId: requestId,
          attempt: attempt,
          error: error,
          stackTrace: stackTrace,
        );
        return _NetworkResult<T>(
          result: ApiError<T>(
            message: 'An unexpected error occurred',
            error: error.toString(),
            meta: ApiResultMetadata(
              source: ApiDataSource.network,
              requestId: requestId,
              operationId: request.operationId,
              attempt: attempt,
            ),
          ),
        );
      }
    }

    final raw = asResponseMap(lastException?.response?.data);
    return _NetworkResult<T>(
      exception: lastException,
      responseBody: lastException?.response?.data,
      result: ApiError<T>(
        message: _extractMessage(
          raw,
          fallback: lastException?.response?.statusMessage ?? 'Request failed',
        ),
        error: _extractDioError(lastException, raw),
        statusCode: lastException?.response?.statusCode,
        raw: raw,
        meta: ApiResultMetadata(
          source: ApiDataSource.network,
          requestId: requestId,
          operationId: request.operationId,
          attempt: maxAttempts,
        ),
      ),
    );
  }

  Future<Response<dynamic>> _send<T>(
    ApiRequest<T> request,
    String requestId,
    int attempt,
  ) async {
    final method = _method(request);
    final headers = <String, String>{...?request.headers};
    final idempotencyKey = request.options?.idempotencyKey?.trim();
    if (idempotencyKey != null && idempotencyKey.isNotEmpty) {
      headers.putIfAbsent('Idempotency-Key', () => idempotencyKey);
    }
    final options = Options(
      method: method,
      headers: headers,
      contentType: request is UploadRequest
          ? Headers.multipartFormDataContentType
          : null,
      extra: <String, Object?>{
        'noAuth': request.noAuth,
        'customCookies': request.cookies ?? const <String, String>{},
        'requestId': requestId,
        'operationId': request.operationId,
        'attempt': attempt,
      },
    );

    return _dio.request<dynamic>(
      request.fullPath,
      data: await _body(request),
      queryParameters: buildDioQueryParameters(request.query),
      options: options,
      cancelToken: request.options?.cancelToken,
      onSendProgress: request is UploadRequest<T>
          ? request.uploadOptions?.onSendProgress
          : null,
    );
  }

  Future<Object?> _body<T>(ApiRequest<T> request) async {
    if (request is UploadRequest<T>) {
      final formData = FormData();
      if (request.fields != null) {
        formData.fields.addAll(request.fields!.entries);
      }
      for (final file in request.files) {
        formData.files.add(await file.toMultipart());
      }
      return formData;
    }
    final body = switch (request) {
      PostRequest<T> value => value.body,
      PutRequest<T> value => value.body,
      PatchRequest<T> value => value.body,
      DeleteRequest<T> value => value.body,
      _ => null,
    };
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
    required ApiRequest<T> request,
    required dynamic responseBody,
    required int statusCode,
    required ApiResultMetadata meta,
  }) {
    final raw = asResponseMap(responseBody);
    final message = _extractMessage(raw);
    if (request.fromJson == null || responseBody == null) {
      return ApiSuccess<T>(
        message: message,
        statusCode: statusCode,
        raw: raw,
        meta: meta,
      );
    }
    try {
      return ApiSuccess<T>(
        message: message,
        statusCode: statusCode,
        data: request.fromJson!(responseBody),
        raw: raw,
        meta: meta,
      );
    } catch (error, stackTrace) {
      _log(
        ApiLogLevel.error,
        ApiLogEventType.failure,
        'Failed to parse API response',
        request: request,
        error: error,
        stackTrace: stackTrace,
      );
      return ApiError<T>(
        message: message.isEmpty ? 'Failed to parse response' : message,
        error: 'Failed to parse response: $error',
        statusCode: statusCode,
        raw: raw,
        meta: meta,
      );
    }
  }

  String _cacheKey<T>(GetRequest<T> request, ApiGetRequestOptions? options) {
    final vary = <String, String>{};
    for (final name in options?.varyHeaders ?? const <String>[]) {
      final value = request.headers?[name] ?? config.defaultHeaders[name];
      if (value != null) vary[name] = value;
    }
    return cache.keyFor(
      method: 'GET',
      path: request.fullPath,
      query: stableQueryString(request.query),
      varyHeaders: vary,
      operationId: request.operationId,
    );
  }

  ApiResultMetadata _cacheMetadata<T>(
    GetRequest<T> request,
    ApiCacheRead cached,
  ) =>
      ApiResultMetadata(
        source: cached.isStale
            ? ApiDataSource.staleCache
            : cached.source == ApiCacheSource.memory
                ? ApiDataSource.memoryCache
                : ApiDataSource.hiveCache,
        isStale: cached.isStale,
        operationId: request.operationId,
        receivedAt: cached.storedAt,
        expiresAt: cached.expiresAt,
      );

  Future<void> _applyPreRequestInvalidation(ApiRequestOptions? options) async {
    if (options == null) return;
    if (options.clearActiveSessionCache) await cache.clearActiveSession();
    for (final path in options.invalidateCachePaths) {
      await cache.invalidateWhere(path);
    }
    if (options.invalidateCacheTags.isNotEmpty) {
      await cache.invalidateTags(options.invalidateCacheTags);
    }
  }

  Future<void> _applyPostSuccessInvalidation(ApiRequestOptions? options) async {
    await _applyPreRequestInvalidation(options);
  }

  int _maxAttempts<T>(ApiRequest<T> request) {
    if (!config.retry.enabled || request.options?.retry == false) return 1;
    if (!_isRetrySafe(request)) return 1;
    return max(1, config.retry.maxAttempts);
  }

  bool _isRetrySafe<T>(ApiRequest<T> request) {
    final method = _method(request);
    if (method == 'GET' || method == 'HEAD' || method == 'OPTIONS') return true;
    if (request.options?.retryUnsafeRequest == true) return true;
    return request.options?.idempotencyKey?.trim().isNotEmpty == true;
  }

  bool _shouldRetry<T>(ApiRequest<T> request, DioException error) {
    if (!_isRetrySafe(request)) return false;
    if (error.type == DioExceptionType.cancel ||
        error.response?.statusCode == 401 ||
        error.response?.statusCode == 403) {
      return false;
    }
    if (_isOfflineLike(error)) return true;
    final status = error.response?.statusCode;
    return status != null && config.retry.retryStatusCodes.contains(status);
  }

  Duration _retryDelay(DioException error, int attempt) {
    final retryAfter = error.response?.headers.value('retry-after');
    if (retryAfter != null) {
      final seconds = int.tryParse(retryAfter.trim());
      if (seconds != null && seconds >= 0) return Duration(seconds: seconds);
      try {
        final date = HttpDate.parse(retryAfter);
        final duration = date.difference(DateTime.now().toUtc());
        if (!duration.isNegative) return duration;
      } on FormatException {
        // Ignore malformed Retry-After values and use exponential backoff.
      }
    }
    final exponent = max(0, attempt - 1);
    final baseMs = config.retry.baseDelay.inMilliseconds * pow(2, exponent);
    final capped = min(baseMs.round(), config.retry.maxDelay.inMilliseconds);
    final jitter = Random().nextInt(max(1, capped ~/ 3));
    return Duration(milliseconds: capped + jitter);
  }

  bool _isOfflineLike(DioException? error) {
    if (error == null) return false;
    return error.type == DioExceptionType.connectionError ||
        error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.sendTimeout ||
        error.type == DioExceptionType.receiveTimeout ||
        (error.type == DioExceptionType.unknown && error.response == null);
  }

  String _method<T>(ApiRequest<T> request) => switch (request) {
        GetRequest<T> _ => 'GET',
        PostRequest<T> _ => 'POST',
        PutRequest<T> _ => 'PUT',
        PatchRequest<T> _ => 'PATCH',
        DeleteRequest<T> _ => 'DELETE',
        UploadRequest<T> value => switch (value.method) {
            UploadMethod.post => 'POST',
            UploadMethod.put => 'PUT',
            UploadMethod.patch => 'PATCH',
          },
      };

  String _extractMessage(
    Map<String, dynamic>? raw, {
    String fallback = '',
  }) {
    final value = raw?['message'];
    if (value is String) return value;
    if (value is List) return value.whereType<String>().join(', ');
    return fallback;
  }

  String _extractDioError(
    DioException? error,
    Map<String, dynamic>? raw,
  ) {
    final rawError = raw?['error'];
    if (rawError is String && rawError.trim().isNotEmpty) return rawError;
    final rawErrors = raw?['errors'];
    if (rawErrors is String && rawErrors.trim().isNotEmpty) return rawErrors;
    if (rawErrors is List && rawErrors.isNotEmpty) {
      return rawErrors.map((item) => item.toString()).join(', ');
    }
    return error?.message ?? error?.type.name ?? 'request_failed';
  }

  void _log(
    ApiLogLevel level,
    ApiLogEventType type,
    String message, {
    ApiRequest<dynamic>? request,
    String? requestId,
    int? statusCode,
    Duration? duration,
    int? attempt,
    Map<String, Object?> data = const <String, Object?>{},
    Object? error,
    StackTrace? stackTrace,
  }) {
    if (!config.logging.enabled) return;
    config.logger.log(
      ApiLogEvent(
        level: level,
        type: type,
        message: message,
        timestamp: DateTime.now().toUtc(),
        method: request == null ? null : _method(request),
        path: request?.fullPath,
        statusCode: statusCode,
        duration: duration,
        requestId: requestId,
        operationId: request?.operationId,
        attempt: attempt,
        data: <String, Object?>{
          'connection': key,
          'sessionId': auth.current.sessionId,
          if (_identity != null) 'client': _identity.applicationName,
          ...data,
        },
        error: error,
        stackTrace: stackTrace,
      ),
    );
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _dio.close(force: true);
    await auth.dispose();
  }

  void _ensureActive() {
    if (_disposed) throw StateError('API connection $key has been disposed.');
  }

  static String _nextRequestId() {
    _requestSequence += 1;
    return '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-'
        '${_requestSequence.toRadixString(36)}';
  }

  static String _safeNamespace(String value) =>
      value.replaceAll(RegExp(r'[^a-zA-Z0-9._-]+'), '_');
}

class _ConnectionRequestInterceptor extends Interceptor {
  _ConnectionRequestInterceptor({
    required this.auth,
    required this.cookies,
    required this.cookiesEnabled,
  });

  final ApiAuth auth;
  final ApiCookieManager cookies;
  final bool cookiesEnabled;

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    await auth.apply(options);
    if (cookiesEnabled) {
      final overrides = options.extra['customCookies'];
      final custom = overrides is Map
          ? overrides.map(
              (key, value) => MapEntry(key.toString(), value.toString()),
            )
          : const <String, String>{};
      if (custom.isNotEmpty) {
        final header = await cookies.mergedHeader(
          uri: options.uri,
          overrides: custom,
        );
        if (header != null) options.headers['Cookie'] = header;
      }
    }
    handler.next(options);
  }
}

class _NetworkResult<T> {
  const _NetworkResult({
    required this.result,
    this.responseBody,
    this.exception,
  });

  final ApiResult<T> result;
  final dynamic responseBody;
  final DioException? exception;
}
