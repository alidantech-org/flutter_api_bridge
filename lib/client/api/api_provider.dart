// lib/server/api/api_provider.dart
import 'dart:developer' as dev;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../server_config.dart';
import 'api_cache.dart';
import 'api_client.dart';
import 'api_normalizer.dart';
import 'api_request.dart';
import 'api_result.dart';

// ─── Provider ──────────────────────────────────────────────────────────────────

final apiProvider = StateNotifierProvider<ApiNotifier, AsyncValue<ApiResult<dynamic>>>(
  (ref) => ApiNotifier(),
);

// ─── Notifier ──────────────────────────────────────────────────────────────────

class ApiNotifier extends StateNotifier<AsyncValue<ApiResult<dynamic>>> {
  ApiNotifier() : super(const AsyncValue.loading()) {
    state = const AsyncValue.data(
      ApiError(message: '', error: '', statusCode: null),
    );
  }

  // ── Public entry point ─────────────────────────────────────────────────────

  /// Execute any [ApiRequest].
  /// Always returns an [ApiResult] — never throws.
  Future<ApiResult<T>> send<T>(ApiRequest<T> request) async {
    return switch (request) {
      GetRequest<T> r => _get(r),
      PostRequest<T> r => _mutate(r, 'POST', r.body),
      PutRequest<T> r => _mutate(r, 'PUT', r.body),
      PatchRequest<T> r => _mutate(r, 'PATCH', r.body),
      DeleteRequest<T> r => _mutate(r, 'DELETE', r.body),
      UploadRequest<T> r => _upload(r),
      // ignore: unreachable_switch_case
      _ => _unsupported<T>(request),
    };
  }

  // ── GET with cache ─────────────────────────────────────────────────────────

  Future<ApiResult<T>> _get<T>(GetRequest<T> request) async {
    try {
      if (request.invalidateCache) {
        await ApiCache.invalidate(request.cacheKey);
      }

      if (request.cache && !request.forceRefresh) {
        final cached = ApiCache.read(request.cacheKey);
        final cachedRaw = asResponseMap(cached);

        if (cachedRaw != null) {
          final result = _parse<T>(
            responseBody: cachedRaw,
            statusCode: 200,
            fromJson: request.fromJson,
            fullRaw: cachedRaw,
          );

          state = AsyncValue.data(result);
          return result;
        }
      }

      state = const AsyncValue.loading();

      final dio = ApiClient.instance(request.version);

      final response = await dio.get(
        request.endpoint,
        queryParameters: buildDioQueryParameters(request.query),
        options: _options(
          headers: request.headers,
          noAuth: request.noAuth,
        ),
      );

      final raw = asResponseMap(response.data);

      if (request.cache && raw != null) {
        final ttl = request.cacheTtl ?? ServerConfig.defaultCacheTtl;
        await ApiCache.write(request.cacheKey, raw, ttl);
      }

      final result = _parse<T>(
        responseBody: response.data,
        statusCode: response.statusCode ?? 200,
        fromJson: request.fromJson,
        fullRaw: raw,
      );

      state = AsyncValue.data(result);
      return result;
    } on DioException catch (e) {
      return _handleDioError<T>(e);
    } catch (e, stackTrace) {
      return _handleUnexpected<T>(e, stackTrace);
    }
  }

  // ── Mutations: POST / PUT / PATCH / DELETE ─────────────────────────────────

  Future<ApiResult<T>> _mutate<T>(
    ApiRequest<T> request,
    String method,
    Object? body,
  ) async {
    try {
      state = const AsyncValue.loading();

      final dio = ApiClient.instance(request.version);

      final response = await dio.request(
        request.endpoint,
        data: _prepareBody(body),
        queryParameters: buildDioQueryParameters(request.query),
        options: _options(
          method: method,
          headers: request.headers,
          noAuth: request.noAuth,
        ),
      );

      final raw = asResponseMap(response.data);

      final result = _parse<T>(
        responseBody: response.data,
        statusCode: response.statusCode ?? 200,
        fromJson: request.fromJson,
        fullRaw: raw,
      );

      state = AsyncValue.data(result);
      return result;
    } on DioException catch (e) {
      return _handleDioError<T>(e);
    } catch (e, stackTrace) {
      return _handleUnexpected<T>(e, stackTrace);
    }
  }

  // ── Multipart upload ───────────────────────────────────────────────────────

  Future<ApiResult<T>> _upload<T>(UploadRequest<T> request) async {
    try {
      state = const AsyncValue.loading();

      final dio = ApiClient.instance(request.version);
      final formData = await _buildUploadFormData(request);

      final response = await dio.request(
        request.endpoint,
        data: formData,
        queryParameters: buildDioQueryParameters(request.query),
        options: _options(
          method: request.method.httpMethod,
          headers: request.headers,
          noAuth: request.noAuth,
          contentType: Headers.multipartFormDataContentType,
        ),
      );

      final raw = asResponseMap(response.data);

      final result = _parse<T>(
        responseBody: response.data,
        statusCode: response.statusCode ?? 200,
        fromJson: request.fromJson,
        fullRaw: raw,
      );

      state = AsyncValue.data(result);
      return result;
    } on DioException catch (e) {
      return _handleDioError<T>(e);
    } catch (e, stackTrace) {
      return _handleUnexpected<T>(e, stackTrace);
    }
  }

  Future<FormData> _buildUploadFormData<T>(UploadRequest<T> request) async {
    final formData = FormData();

    final fields = request.fields;

    if (fields != null && fields.isNotEmpty) {
      formData.fields.addAll(fields.entries);
    }

    for (final file in request.files) {
      final entry = await file.toMultipart();
      formData.files.add(entry);
    }

    return formData;
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  Options _options({
    String? method,
    Map<String, String>? headers,
    required bool noAuth,
    String? contentType,
  }) {
    return Options(
      method: method,
      headers: headers,
      contentType: contentType,
      extra: {
        'noAuth': noAuth,
      },
    );
  }

  Object? _prepareBody(Object? body) {
    if (body == null) return null;

    if (body is FormData) return body;
    if (body is MultipartFile) return body;
    if (body is List<int>) return body;
    if (body is String) return body;
    if (body is num) return body;
    if (body is bool) return body;

    return normalizeBody(body);
  }

  String _extractMessage(Map<String, dynamic>? raw, {String fallback = ''}) {
    final value = raw?['message'];

    if (value is String) return value;

    if (value is List) {
      return value.whereType<String>().join(', ');
    }

    return fallback;
  }

  ApiResult<T> _parse<T>({
    required dynamic responseBody,
    required int statusCode,
    required T Function(dynamic json)? fromJson,
    required Map<String, dynamic>? fullRaw,
  }) {
    final message = _extractMessage(fullRaw);

    if (fromJson == null) {
      return ApiSuccess<T>(
        message: message,
        statusCode: statusCode,
        data: null,
        raw: fullRaw,
      );
    }

    if (responseBody == null) {
      return ApiSuccess<T>(
        message: message,
        statusCode: statusCode,
        data: null,
        raw: fullRaw,
      );
    }

    try {
      final parsed = fromJson(responseBody);

      return ApiSuccess<T>(
        message: message,
        statusCode: statusCode,
        data: parsed,
        raw: fullRaw,
      );
    } catch (e, stackTrace) {
      dev.log(
        '[api] Parse error: $e',
        name: 'server',
        level: 900,
        stackTrace: stackTrace,
      );

      return ApiError<T>(
        message: message.isEmpty ? 'Failed to parse response' : message,
        error: 'Failed to parse response: $e',
        statusCode: statusCode,
        raw: fullRaw,
      );
    }
  }

  ApiResult<T> _handleDioError<T>(DioException e) {
    final raw = asResponseMap(e.response?.data);

    final message = _extractMessage(
      raw,
      fallback: e.response?.statusMessage ?? 'Request failed',
    );

    final error = _extractDioError(e, raw);

    dev.log(
      '[api] DioError: $message — $error',
      name: 'server',
      level: 900,
    );

    final result = ApiError<T>(
      message: message,
      error: error,
      statusCode: e.response?.statusCode,
      raw: raw,
    );

    state = AsyncValue.data(result);
    return result;
  }

  String _extractDioError(DioException e, Map<String, dynamic>? raw) {
    final rawError = raw?['error'];

    if (rawError is String && rawError.trim().isNotEmpty) {
      return rawError;
    }

    final rawErrors = raw?['errors'];

    if (rawErrors is String && rawErrors.trim().isNotEmpty) {
      return rawErrors;
    }

    if (rawErrors is List && rawErrors.isNotEmpty) {
      return rawErrors.map((item) => item.toString()).join(', ');
    }

    return e.message ?? e.type.name;
  }

  ApiResult<T> _handleUnexpected<T>(Object e, [StackTrace? stackTrace]) {
    dev.log(
      '[api] Unexpected: $e',
      name: 'server',
      level: 1000,
      stackTrace: stackTrace,
    );

    final result = ApiError<T>(
      message: 'An unexpected error occurred',
      error: e.toString(),
    );

    state = AsyncValue.data(result);
    return result;
  }

  ApiResult<T> _unsupported<T>(ApiRequest<T> request) {
    final result = ApiError<T>(
      message: 'Unsupported request type',
      error: 'Unsupported request type: ${request.runtimeType}',
    );

    state = AsyncValue.data(result);
    return result;
  }

  /// Reset state to idle.
  void reset() {
    state = const AsyncValue.data(
      ApiError(message: '', error: '', statusCode: null),
    );
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
