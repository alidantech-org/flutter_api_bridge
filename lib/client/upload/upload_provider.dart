import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../server.dart';

final _progressController = StreamController<UploadProgress>.broadcast();

final uploadProgressStreamProvider =
    StreamProvider<UploadProgress>((_) => _progressController.stream);

final uploadProvider =
    StateNotifierProvider<UploadNotifier, AsyncValue<ApiResult<dynamic>>>(
  (ref) => UploadNotifier(),
);

class UploadNotifier extends StateNotifier<AsyncValue<ApiResult<dynamic>>> {
  UploadNotifier()
      : super(
          const AsyncValue.data(
            ApiError(message: '', error: '', statusCode: null),
          ),
        );

  CancelToken? _cancelToken;

  Future<ApiResult<T>> upload<T>(UploadRequest<T> request) async {
    _cancelToken = CancelToken();
    state = const AsyncValue.loading();
    _progressController.add(const UploadProgress.idle());

    final original = request.uploadOptions;
    final options = ApiUploadRequestOptions(
      headers: original?.headers,
      cookies: original?.cookies,
      noAuth: original?.noAuth ?? false,
      retry: original?.retry,
      retryUnsafeRequest: original?.retryUnsafeRequest ?? false,
      idempotencyKey: original?.idempotencyKey,
      cancelToken: _cancelToken,
      operationId: original?.operationId,
      invalidateCacheTags:
          original?.invalidateCacheTags ?? const <String>[],
      invalidateCachePaths:
          original?.invalidateCachePaths ?? const <String>[],
      clearActiveSessionCache:
          original?.clearActiveSessionCache ?? false,
      onSendProgress: (sent, total) {
        _progressController.add(UploadProgress(sent: sent, total: total));
        original?.onSendProgress?.call(sent, total);
        if (total > 0 && sent >= total) {
          _progressController.add(UploadProgress.done(total));
        }
      },
    );

    final result = await Server.connection.execute(
      UploadRequest<T>(
        endpoint: request.endpoint,
        version: request.version,
        query: request.query,
        fromJson: request.fromJson,
        files: request.files,
        fields: request.fields,
        method: request.method,
        options: options,
      ),
    );
    state = AsyncValue.data(result);
    return result;
  }

  void cancel() => _cancelToken?.cancel('Cancelled by user');

  @override
  void dispose() {
    _cancelToken?.cancel();
    super.dispose();
  }
}
