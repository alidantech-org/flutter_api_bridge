import 'package:dio/dio.dart';

import '../config/api_bridge_config.dart';

/// Shared request controls available on every generated operation.
class ApiRequestOptions {
  const ApiRequestOptions({
    this.headers,
    this.cookies,
    this.noAuth = false,
    this.retry,
    this.retryUnsafeRequest = false,
    this.idempotencyKey,
    this.cancelToken,
    this.operationId,
    this.invalidateCacheTags = const <String>[],
    this.invalidateCachePaths = const <String>[],
    this.clearActiveSessionCache = false,
  });

  final Map<String, String>? headers;
  final Map<String, String>? cookies;
  final bool noAuth;
  final bool? retry;
  final bool retryUnsafeRequest;
  final String? idempotencyKey;
  final CancelToken? cancelToken;
  final String? operationId;
  final List<String> invalidateCacheTags;
  final List<String> invalidateCachePaths;
  final bool clearActiveSessionCache;

  ApiRequestOptions copyWith({
    Map<String, String>? headers,
    Map<String, String>? cookies,
    bool? noAuth,
    bool? retry,
    bool clearRetry = false,
    bool? retryUnsafeRequest,
    String? idempotencyKey,
    CancelToken? cancelToken,
    String? operationId,
    List<String>? invalidateCacheTags,
    List<String>? invalidateCachePaths,
    bool? clearActiveSessionCache,
  }) =>
      ApiRequestOptions(
        headers: headers ?? this.headers,
        cookies: cookies ?? this.cookies,
        noAuth: noAuth ?? this.noAuth,
        retry: clearRetry ? null : retry ?? this.retry,
        retryUnsafeRequest: retryUnsafeRequest ?? this.retryUnsafeRequest,
        idempotencyKey: idempotencyKey ?? this.idempotencyKey,
        cancelToken: cancelToken ?? this.cancelToken,
        operationId: operationId ?? this.operationId,
        invalidateCacheTags: invalidateCacheTags ?? this.invalidateCacheTags,
        invalidateCachePaths: invalidateCachePaths ?? this.invalidateCachePaths,
        clearActiveSessionCache:
            clearActiveSessionCache ?? this.clearActiveSessionCache,
      );
}

class ApiGetRequestOptions extends ApiRequestOptions {
  const ApiGetRequestOptions({
    super.headers,
    super.cookies,
    super.noAuth,
    super.retry,
    super.retryUnsafeRequest,
    super.idempotencyKey,
    super.cancelToken,
    super.operationId,
    super.invalidateCacheTags,
    super.invalidateCachePaths,
    super.clearActiveSessionCache,
    this.cache = true,
    this.cachePolicy,
    this.cacheTtl,
    this.forceRefresh = false,
    this.invalidateCache = false,
    this.cacheTags = const <String>[],
    this.varyHeaders = const <String>[],
  });

  /// Directly disables both cache reads and writes for this request.
  final bool cache;
  final ApiCachePolicy? cachePolicy;
  final Duration? cacheTtl;

  /// Skips cache reads and refreshes storage from a successful network result.
  final bool forceRefresh;
  final bool invalidateCache;
  final List<String> cacheTags;
  final List<String> varyHeaders;

  @override
  ApiGetRequestOptions copyWith({
    Map<String, String>? headers,
    Map<String, String>? cookies,
    bool? noAuth,
    bool? retry,
    bool clearRetry = false,
    bool? retryUnsafeRequest,
    String? idempotencyKey,
    CancelToken? cancelToken,
    String? operationId,
    List<String>? invalidateCacheTags,
    List<String>? invalidateCachePaths,
    bool? clearActiveSessionCache,
    bool? cache,
    ApiCachePolicy? cachePolicy,
    bool clearCachePolicy = false,
    Duration? cacheTtl,
    bool clearCacheTtl = false,
    bool? forceRefresh,
    bool? invalidateCache,
    List<String>? cacheTags,
    List<String>? varyHeaders,
  }) =>
      ApiGetRequestOptions(
        headers: headers ?? this.headers,
        cookies: cookies ?? this.cookies,
        noAuth: noAuth ?? this.noAuth,
        retry: clearRetry ? null : retry ?? this.retry,
        retryUnsafeRequest: retryUnsafeRequest ?? this.retryUnsafeRequest,
        idempotencyKey: idempotencyKey ?? this.idempotencyKey,
        cancelToken: cancelToken ?? this.cancelToken,
        operationId: operationId ?? this.operationId,
        invalidateCacheTags: invalidateCacheTags ?? this.invalidateCacheTags,
        invalidateCachePaths: invalidateCachePaths ?? this.invalidateCachePaths,
        clearActiveSessionCache:
            clearActiveSessionCache ?? this.clearActiveSessionCache,
        cache: cache ?? this.cache,
        cachePolicy: clearCachePolicy ? null : cachePolicy ?? this.cachePolicy,
        cacheTtl: clearCacheTtl ? null : cacheTtl ?? this.cacheTtl,
        forceRefresh: forceRefresh ?? this.forceRefresh,
        invalidateCache: invalidateCache ?? this.invalidateCache,
        cacheTags: cacheTags ?? this.cacheTags,
        varyHeaders: varyHeaders ?? this.varyHeaders,
      );
}

class ApiUploadRequestOptions extends ApiRequestOptions {
  const ApiUploadRequestOptions({
    super.headers,
    super.cookies,
    super.noAuth,
    super.retry,
    super.retryUnsafeRequest,
    super.idempotencyKey,
    super.cancelToken,
    super.operationId,
    super.invalidateCacheTags,
    super.invalidateCachePaths,
    super.clearActiveSessionCache,
    this.onSendProgress,
  });

  final ProgressCallback? onSendProgress;

  @override
  ApiUploadRequestOptions copyWith({
    Map<String, String>? headers,
    Map<String, String>? cookies,
    bool? noAuth,
    bool? retry,
    bool clearRetry = false,
    bool? retryUnsafeRequest,
    String? idempotencyKey,
    CancelToken? cancelToken,
    String? operationId,
    List<String>? invalidateCacheTags,
    List<String>? invalidateCachePaths,
    bool? clearActiveSessionCache,
    ProgressCallback? onSendProgress,
  }) =>
      ApiUploadRequestOptions(
        headers: headers ?? this.headers,
        cookies: cookies ?? this.cookies,
        noAuth: noAuth ?? this.noAuth,
        retry: clearRetry ? null : retry ?? this.retry,
        retryUnsafeRequest: retryUnsafeRequest ?? this.retryUnsafeRequest,
        idempotencyKey: idempotencyKey ?? this.idempotencyKey,
        cancelToken: cancelToken ?? this.cancelToken,
        operationId: operationId ?? this.operationId,
        invalidateCacheTags: invalidateCacheTags ?? this.invalidateCacheTags,
        invalidateCachePaths: invalidateCachePaths ?? this.invalidateCachePaths,
        clearActiveSessionCache:
            clearActiveSessionCache ?? this.clearActiveSessionCache,
        onSendProgress: onSendProgress ?? this.onSendProgress,
      );
}
