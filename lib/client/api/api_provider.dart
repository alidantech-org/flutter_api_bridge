// lib/server/api/api_provider.dart
import 'dart:developer' as dev;
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'api_cache.dart';
import 'api_client.dart';
import 'api_request.dart';
import 'api_result.dart';
import '../server_config.dart';

// ─── Provider ──────────────────────────────────────────────────────────────────

/// Single API notifier. One instance per screen via [apiProvider.family]
/// or shared globally — your choice.
///
/// Usage — call [ApiNotifier.send] from a screen or button handler:
/// ```dart
/// final result = await ref.read(apiProvider.notifier).send(
///   PostRequest<ResolveEmailResponse>(
///     endpoint: V1.auth.postResolveEmail,
///     version: ApiVersion.v1,
///     noAuth: true,
///     body: body.toJson(),
///     fromJson: ResolveEmailResponse.fromJson,
///   ),
/// );
/// ```
///
/// fromJson always receives the full backend response body.
/// Feature DTOs are responsible for extracting endpoint-specific fields.
final apiProvider =
    StateNotifierProvider<ApiNotifier, AsyncValue<ApiResult<dynamic>>>(
        (ref) => ApiNotifier());

// ─── Notifier ──────────────────────────────────────────────────────────────────

class ApiNotifier extends StateNotifier<AsyncValue<ApiResult<dynamic>>> {
  ApiNotifier() : super(const AsyncValue.loading()) {
    // Start idle — not loading
    state = const AsyncValue.data(
        ApiError(message: '', error: '', statusCode: null));
  }

  // ── Public entry point ─────────────────────────────────────────────────────

  /// Execute any [ApiRequest] (except upload — use [UploadNotifier] for that).
  /// Always returns an [ApiResult] — never throws.
  Future<ApiResult<T>> send<T>(ApiRequest<T> request) async {
    return switch (request) {
      GetRequest<T> r => _get(r),
      PostRequest<T> r => _mutate(r, 'POST', r.body),
      PutRequest<T> r => _mutate(r, 'PUT', r.body),
      PatchRequest<T> r => _mutate(r, 'PATCH', r.body),
      DeleteRequest<T> r => _mutate(r, 'DELETE', r.body),
      _ =>
        throw ArgumentError('Unsupported request type: ${request.runtimeType}'),
    };
  }

  // ── GET with cache ─────────────────────────────────────────────────────────

  Future<ApiResult<T>> _get<T>(GetRequest<T> request) async {
    // Manual invalidation requested by screen
    if (request.invalidateCache) await ApiCache.invalidate(request.cacheKey);

    // Cache read
    if (request.cache && !request.forceRefresh) {
      final cached = ApiCache.read(request.cacheKey);
      if (cached != null) {
        final result = _parse<T>(
            cached, 200, request.fromJson, cached as Map<String, dynamic>?);
        state = AsyncValue.data(result);
        return result;
      }
    }

    state = const AsyncValue.loading();

    try {
      final dio = ApiClient.instance(request.version);
      final response = await dio.get(
        request.endpoint,
        queryParameters: request.query,
        options: Options(
            headers: request.headers, extra: {'noAuth': request.noAuth}),
      );

      final raw = response.data as Map<String, dynamic>?;

      // Write to cache
      if (request.cache && raw != null) {
        final ttl = request.cacheTtl ?? ServerConfig.defaultCacheTtl;
        await ApiCache.write(request.cacheKey, raw, ttl);
      }

      final result =
          _parse<T>(raw, response.statusCode ?? 200, request.fromJson, raw);

      state = AsyncValue.data(result);
      return result;
    } on DioException catch (e) {
      return _handleDioError<T>(e);
    } catch (e) {
      return _handleUnexpected<T>(e);
    }
  }

  // ── Mutations (POST / PUT / PATCH / DELETE) ────────────────────────────────

  Future<ApiResult<T>> _mutate<T>(
      ApiRequest<T> request, String method, Map<String, dynamic>? body) async {
    state = const AsyncValue.loading();

    try {
      final dio = ApiClient.instance(request.version);
      final response = await dio.request(
        request.endpoint,
        data: body,
        queryParameters: request.query,
        options: Options(
            method: method,
            headers: request.headers,
            extra: {'noAuth': request.noAuth}),
      );

      final raw = response.data as Map<String, dynamic>?;
      final result =
          _parse<T>(raw, response.statusCode ?? 200, request.fromJson, raw);

      state = AsyncValue.data(result);
      return result;
    } on DioException catch (e) {
      return _handleDioError<T>(e);
    } catch (e) {
      return _handleUnexpected<T>(e);
    }
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  ApiResult<T> _parse<T>(
    dynamic responseBody,
    int statusCode,
    T Function(dynamic)? fromJson,
    Map<String, dynamic>? fullRaw,
  ) {
    final message = fullRaw?['message'] as String? ?? '';

    // If no fromJson or no data to parse, return success with null data
    if (fromJson == null) {
      return ApiSuccess<T>(
          message: message, statusCode: statusCode, data: null, raw: fullRaw);
    }

    if (responseBody == null) {
      return ApiSuccess<T>(
          message: message, statusCode: statusCode, data: null, raw: fullRaw);
    }

    try {
      final parsed = fromJson(responseBody);
      return ApiSuccess<T>(
          message: message, statusCode: statusCode, data: parsed, raw: fullRaw);
    } catch (e) {
      dev.log('[api] Parse error for full response body: $e',
          name: 'server', level: 900);
      return ApiError<T>(
          message: message,
          error: 'Failed to parse response: $e',
          statusCode: statusCode,
          raw: fullRaw);
    }
  }

  ApiResult<T> _handleDioError<T>(DioException e) {
    final raw = e.response?.data as Map<String, dynamic>?;
    final message = raw?['message'] as String? ?? 'Request failed';
    final error = e.message ?? 'DioException';
    dev.log('[api] DioError: $message — $error', name: 'server', level: 900);
    final result = ApiError<T>(
        message: message,
        error: error,
        statusCode: e.response?.statusCode,
        raw: raw);
    state = AsyncValue.data(result);
    return result;
  }

  ApiResult<T> _handleUnexpected<T>(Object e) {
    dev.log('[api] Unexpected: $e', name: 'server', level: 1000);
    final result = ApiError<T>(
        message: 'An unexpected error occurred', error: e.toString());
    state = AsyncValue.data(result);
    return result;
  }

  /// Reset state to idle.
  void reset() {
    state = const AsyncValue.data(
        ApiError(message: '', error: '', statusCode: null));
  }
}
