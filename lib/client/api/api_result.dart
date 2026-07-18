/// Origin of data returned by an API operation.
enum ApiDataSource {
  network,
  memoryCache,
  hiveCache,
  staleCache,
}

class ApiResultMetadata {
  const ApiResultMetadata({
    required this.source,
    this.isStale = false,
    this.isOfflineFallback = false,
    this.requestId,
    this.operationId,
    this.receivedAt,
    this.expiresAt,
    this.attempt = 1,
  });

  final ApiDataSource source;
  final bool isStale;
  final bool isOfflineFallback;
  final String? requestId;
  final String? operationId;
  final DateTime? receivedAt;
  final DateTime? expiresAt;
  final int attempt;
}

sealed class ApiResult<T> {
  const ApiResult();

  bool get isSuccess => this is ApiSuccess<T>;
  bool get isError => this is ApiError<T>;

  T? get dataOrNull => switch (this) {
        ApiSuccess<T> value => value.data,
        ApiError<T> _ => null,
      };

  String get message => switch (this) {
        ApiSuccess<T> value => value.message,
        ApiError<T> value => value.message,
      };

  ApiResultMetadata? get metadata => switch (this) {
        ApiSuccess<T> value => value.meta,
        ApiError<T> value => value.meta,
      };

  R when<R>({
    required R Function(T? data, String message, int statusCode) success,
    required R Function(String error, String message, int? statusCode) error,
  }) =>
      switch (this) {
        ApiSuccess<T> value =>
          success(value.data, value.message, value.statusCode),
        ApiError<T> value =>
          error(value.error, value.message, value.statusCode),
      };

  void ifSuccess(void Function(T? data, String message) callback) {
    if (this case ApiSuccess<T> value) callback(value.data, value.message);
  }

  void ifError(void Function(String error, String message) callback) {
    if (this case ApiError<T> value) callback(value.error, value.message);
  }
}

final class ApiSuccess<T> extends ApiResult<T> {
  const ApiSuccess({
    required this.message,
    required this.statusCode,
    this.data,
    this.raw,
    this.meta,
  });

  final String message;
  final int statusCode;
  final T? data;
  final Map<String, dynamic>? raw;
  final ApiResultMetadata? meta;
}

final class ApiError<T> extends ApiResult<T> {
  const ApiError({
    required this.message,
    required this.error,
    this.statusCode,
    this.raw,
    this.meta,
  });

  final String message;
  final String error;
  final int? statusCode;
  final Map<String, dynamic>? raw;
  final ApiResultMetadata? meta;
}
