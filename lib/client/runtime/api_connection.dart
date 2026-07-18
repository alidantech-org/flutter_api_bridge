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
  }) : _dio = dio;

  final String key;
  final ApiBridgeConfig config;
  final Dio _dio;
  final ApiAuth auth;
  final ApiCache cache;
  final ApiCookieManager cookies;

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
    final context = _ExecutionLogContext(
      requestId: _nextRequestId(),
      startedAt: DateTime.now().toUtc(),
      options: config.logging.resolve(request.options?.log),
    );
    _logRequest(request, context);
    if (request is GetRequest<T>) return _executeGet(request, context);
    return _executeMutation(request, context);
  }

  Future<ApiResult<T>> _executeGet<T>(
    GetRequest<T> request,
    _ExecutionLogContext context,
  ) async {
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
        final result = _parse<T>(
          request: request,
          responseBody: cached.data,
          statusCode: 200,
          meta: _cacheMetadata(request, cached),
        );
        _logResponse(
          request,
          context,
          statusCode: 200,
          source: 'cache',
          data: <String, Object?>{
            'cache': 'hit',
            'age':
                '${DateTime.now().toUtc().difference(cached.storedAt).inSeconds}s',
            'cacheSource': cached.source.name,
            if (context.options.responseBody) 'body': cached.data,
          },
        );
        return result;
      }
      if (policy == ApiCachePolicy.cacheOnly) {
        final result = ApiError<T>(
          message: 'No cached data is available',
          error: 'cache_miss',
          meta: ApiResultMetadata(
            source: ApiDataSource.hiveCache,
            operationId: request.operationId,
          ),
        );
        _logError(
          request,
          context,
          code: 'cache_miss',
          message: result.message,
        );
        return result;
      }
    }

    final network = await _network<T>(request, context);
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
      _logNetworkSuccess(request, context, network);
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
        final result = _parse<T>(
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
        _logResponse(
          request,
          context,
          statusCode: 200,
          source: 'cache',
          data: <String, Object?>{
            'cache': 'hit',
            'fallback': 'network_failure',
            'stale': cached.isStale,
            'cacheSource': cached.source.name,
            if (context.options.responseBody) 'body': cached.data,
          },
        );
        return result;
      }
    }
    _logNetworkError(request, context, network);
    return network.result;
  }

  Future<ApiResult<T>> _executeMutation<T>(
    ApiRequest<T> request,
    _ExecutionLogContext context,
  ) async {
    final network = await _network<T>(request, context);
    if (network.result is ApiSuccess<T>) {
      await _applyPostSuccessInvalidation(request.options);
      _logNetworkSuccess(request, context, network);
    } else {
      _logNetworkError(request, context, network);
    }
    return network.result;
  }

  Future<_NetworkResult<T>> _network<T>(
    ApiRequest<T> request,
    _ExecutionLogContext context,
  ) async {
    final requestId = context.requestId;
    final maxAttempts = _maxAttempts(request);
    DioException? lastException;

    for (var attempt = 1; attempt <= maxAttempts; attempt += 1) {
      try {
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
        return _NetworkResult<T>(
          result: result,
          responseBody: response.data,
          response: response,
          attempt: attempt,
        );
      } on DioException catch (error) {
        lastException = error;
        if (error.response?.statusCode == 401) {
          unawaited(auth.expire(reason: 'http_401'));
        }
        final canRetry = attempt < maxAttempts && _shouldRetry(request, error);
        if (!canRetry) break;
        final delay = _retryDelay(error, attempt);
        _logRetry(
          request,
          context,
          attempt: attempt + 1,
          maxAttempts: maxAttempts,
          delay: delay,
          reason: _retryReason(error),
        );
        await Future<void>.delayed(delay);
      } catch (error) {
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
          attempt: attempt,
        );
      }
    }

    final raw = asResponseMap(lastException?.response?.data);
    return _NetworkResult<T>(
      exception: lastException,
      responseBody: lastException?.response?.data,
      response: lastException?.response,
      attempt: maxAttempts,
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
    } catch (error) {
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

  void _logRequest<T>(ApiRequest<T> request, _ExecutionLogContext context) {
    final data = <String, Object?>{
      if (context.options.queryParameters && request.query != null)
        'query': buildDioQueryParameters(request.query),
      if (context.options.requestHeaders && request.headers?.isNotEmpty == true)
        'headers': request.headers,
      if (context.options.cookies && request.cookies?.isNotEmpty == true)
        'cookies': request.cookies,
      if (context.options.requestBody) 'body': _requestBodyForLog(request),
    };
    _emit(
      ApiRequestLogEvent(
        timestamp: context.startedAt,
        method: _method(request),
        path: request.fullPath,
        operationId: request.operationId,
        requestId: context.requestId,
        attempt: 1,
        maxAttempts: _maxAttempts(request),
        options: context.options,
        data: _safeLogData(context.options, data),
      ),
    );
  }

  void _logNetworkSuccess<T>(
    ApiRequest<T> request,
    _ExecutionLogContext context,
    _NetworkResult<T> network,
  ) {
    _logResponse(
      request,
      context,
      statusCode: network.response?.statusCode ??
          (network.result as ApiSuccess<T>).statusCode,
      source: 'network',
      attempt: network.attempt,
      data: <String, Object?>{
        if (context.options.responseHeaders && network.response != null)
          'headers': network.response!.headers.map,
        if (context.options.responseBody) 'body': network.responseBody,
      },
    );
  }

  void _logResponse<T>(
    ApiRequest<T> request,
    _ExecutionLogContext context, {
    required int statusCode,
    required String source,
    int? attempt,
    Map<String, Object?> data = const <String, Object?>{},
  }) {
    _emit(
      ApiResponseLogEvent(
        timestamp: DateTime.now().toUtc(),
        method: _method(request),
        path: request.fullPath,
        operationId: request.operationId,
        requestId: context.requestId,
        statusCode: statusCode,
        duration: DateTime.now().toUtc().difference(context.startedAt),
        source: source,
        attempt: attempt,
        options: context.options,
        data: _safeLogData(context.options, data),
      ),
    );
  }

  void _logNetworkError<T>(
    ApiRequest<T> request,
    _ExecutionLogContext context,
    _NetworkResult<T> network,
  ) {
    final errorResult =
        network.result is ApiError<T> ? network.result as ApiError<T> : null;
    final raw = asResponseMap(network.responseBody);
    final message = errorResult?.message ??
        _extractMessage(raw, fallback: 'Request failed');
    final code = _errorCode(network.exception, raw, errorResult?.error);
    _logError(
      request,
      context,
      statusCode: errorResult?.statusCode ?? network.response?.statusCode,
      attempt: network.attempt,
      code: code,
      message: message,
      data: <String, Object?>{
        if (context.options.responseHeaders && network.response != null)
          'headers': network.response!.headers.map,
        if (context.options.responseBody) 'body': network.responseBody,
      },
    );
  }

  void _logError<T>(
    ApiRequest<T> request,
    _ExecutionLogContext context, {
    required String code,
    required String message,
    int? statusCode,
    int? attempt,
    Map<String, Object?> data = const <String, Object?>{},
  }) {
    _emit(
      ApiErrorLogEvent(
        timestamp: DateTime.now().toUtc(),
        method: _method(request),
        path: request.fullPath,
        operationId: request.operationId,
        requestId: context.requestId,
        statusCode: statusCode,
        duration: DateTime.now().toUtc().difference(context.startedAt),
        attempt: attempt,
        code: code,
        options: context.options,
        data: _safeLogData(
          context.options,
          <String, Object?>{'message': message, ...data},
        ),
      ),
    );
  }

  void _logRetry<T>(
    ApiRequest<T> request,
    _ExecutionLogContext context, {
    required int attempt,
    required int maxAttempts,
    required Duration delay,
    required String reason,
  }) {
    _emit(
      ApiRetryLogEvent(
        timestamp: DateTime.now().toUtc(),
        operationId: request.operationId,
        requestId: context.requestId,
        attempt: attempt,
        maxAttempts: maxAttempts,
        retryDelay: delay,
        options: context.options,
        data: _safeLogData(
          context.options,
          <String, Object?>{'reason': reason},
        ),
      ),
    );
  }

  Object? _requestBodyForLog<T>(ApiRequest<T> request) {
    if (request is UploadRequest<T>) {
      return <String, Object?>{
        'type': 'multipart',
        'fields': request.fields,
        'files': request.files
            .map(
              (file) => <String, Object?>{
                'field': file.field,
                'filename': file.filename,
                'size': file.bytes?.length ?? file.length,
                'source': file.path != null
                    ? 'path'
                    : file.bytes != null
                        ? 'bytes'
                        : 'stream',
              },
            )
            .toList(growable: false),
      };
    }
    final body = switch (request) {
      PostRequest<T> value => value.body,
      PutRequest<T> value => value.body,
      PatchRequest<T> value => value.body,
      DeleteRequest<T> value => value.body,
      _ => null,
    };
    if (body == null || body is String || body is num || body is bool) {
      return body;
    }
    try {
      return normalizeBody(body);
    } catch (_) {
      return body;
    }
  }

  String _errorCode(
    DioException? error,
    Map<String, dynamic>? raw,
    Object? resultError,
  ) {
    final code = raw?['code'];
    if (code is String && code.trim().isNotEmpty) return code.trim();
    final rawError = raw?['error'];
    if (rawError is String && rawError.trim().isNotEmpty) {
      return rawError.trim();
    }
    if (resultError is String && resultError.trim().isNotEmpty) {
      return resultError.trim();
    }
    return error?.type.name ?? 'request_failed';
  }

  String _retryReason(DioException error) {
    final raw = asResponseMap(error.response?.data);
    return _errorCode(error, raw, null);
  }

  Map<String, Object?> _safeLogData(
    ApiResolvedLogOptions options,
    Map<String, Object?> data,
  ) {
    try {
      final safe = options.redactor.redact(data);
      return safe is Map<String, Object?>
          ? safe
          : const <String, Object?>{};
    } catch (_) {
      return const <String, Object?>{'diagnostic': '[REDACTION_FAILED]'};
    }
  }

  void _emit(ApiLogEvent event) {
    final options = event.options ?? config.logging.resolve();
    if (!options.enabled) return;
    if (options.level == ApiLoggingLevel.errors &&
        event.type != ApiLogEventType.failure) {
      return;
    }
    try {
      config.logger.log(event);
    } catch (_) {
      // Diagnostics must never affect request execution.
    }
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
    this.response,
    this.attempt,
  });

  final ApiResult<T> result;
  final dynamic responseBody;
  final DioException? exception;
  final Response<dynamic>? response;
  final int? attempt;
}

class _ExecutionLogContext {
  const _ExecutionLogContext({
    required this.requestId,
    required this.startedAt,
    required this.options,
  });

  final String requestId;
  final DateTime startedAt;
  final ApiResolvedLogOptions options;
}
