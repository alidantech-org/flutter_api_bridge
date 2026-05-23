// lib/server/upload/upload_provider.dart
import 'dart:async';
import 'dart:developer' as dev;
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../api/api_client.dart';
import '../api/api_request.dart';
import '../api/api_result.dart';
import 'upload_progress.dart';

// ─── Progress stream ───────────────────────────────────────────────────────────

final _progressController = StreamController<UploadProgress>.broadcast();

/// Watch this stream to show a real-time upload progress bar.
///
/// ```dart
/// final progress = ref.watch(uploadProgressStreamProvider);
/// ```
final uploadProgressStreamProvider =
    StreamProvider<UploadProgress>((_) => _progressController.stream);

// ─── Upload notifier ───────────────────────────────────────────────────────────

/// State: the result of the last upload (or null if none yet).
final uploadProvider =
    StateNotifierProvider<UploadNotifier, AsyncValue<ApiResult<dynamic>>>(
        (ref) => UploadNotifier());

class UploadNotifier extends StateNotifier<AsyncValue<ApiResult<dynamic>>> {
  UploadNotifier() : super(const AsyncValue.loading()) {
    // Start idle
    state = const AsyncValue.data(
        ApiError(message: '', error: '', statusCode: null));
  }

  CancelToken? _cancelToken;

  /// Execute an upload request.
  /// Progress is emitted on [uploadProgressStreamProvider].
  /// Returns the [ApiResult] and also updates state.
  Future<ApiResult<T>> upload<T>(UploadRequest<T> request) async {
    _cancelToken = CancelToken();
    state = const AsyncValue.loading();
    _progressController.add(const UploadProgress.idle());

    try {
      // Build FormData
      final formData = FormData();

      // Add extra string fields
      request.fields?.forEach((key, value) {
        formData.fields.add(MapEntry(key, value));
      });

      // Add files
      for (final file in request.files) {
        final entry = await file.toMultipart();
        formData.files.add(entry);
      }

      final dio = ApiClient.instance(request.version);

      final response = await dio.request(
        request.endpoint,
        data: formData,
        options: Options(
          method: request.method == UploadMethod.post ? 'POST' : 'PUT',
          headers: {'Content-Type': 'multipart/form-data', ...?request.headers},
          extra: {'noAuth': request.noAuth},
        ),
        cancelToken: _cancelToken,
        onSendProgress: (sent, total) {
          _progressController.add(UploadProgress(sent: sent, total: total));
          if (total > 0 && sent >= total) {
            _progressController.add(UploadProgress.done(total));
          }
        },
      );

      final raw = response.data as Map<String, dynamic>?;
      final message = raw?['message'] as String? ?? '';

      dynamic parsed;
      if (request.fromJson != null && raw != null) {
        try {
          parsed = request.fromJson!(raw);
        } catch (e) {
          dev.log('[upload] Parse error: $e', name: 'server', level: 900);
          parsed = null;
        }
      }

      final result = ApiSuccess<T>(
          message: message,
          statusCode: response.statusCode ?? 200,
          data: parsed,
          raw: raw);

      state = AsyncValue.data(result);
      return result;
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        final result = ApiError<T>(
            message: 'Upload cancelled', error: 'cancelled', statusCode: null);
        state = AsyncValue.data(result);
        return result;
      }

      final raw = e.response?.data as Map<String, dynamic>?;
      final message = raw?['message'] as String? ?? 'Upload failed';
      dev.log('[upload] Error: $message', name: 'server', level: 900);

      final result = ApiError<T>(
        message: message,
        error: e.message ?? 'DioException',
        statusCode: e.response?.statusCode,
        raw: raw,
      );
      state = AsyncValue.data(result);
      return result;
    } catch (e) {
      dev.log('[upload] Unexpected: $e', name: 'server', level: 1000);
      final result =
          ApiError<T>(message: 'Unexpected upload error', error: e.toString());
      state = AsyncValue.data(result);
      return result;
    }
  }

  /// Cancel the in-progress upload.
  void cancel() => _cancelToken?.cancel('Cancelled by user');

  @override
  void dispose() {
    _cancelToken?.cancel();
    super.dispose();
  }
}
