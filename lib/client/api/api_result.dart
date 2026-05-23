// lib/server/api/api_result.dart

/// The result of every API call — success or error.
/// Never throws. Screens pattern-match on this.
///
/// [T] is the parsed model type.
/// [message] is the raw server message — use for snackbars.
/// [data] is the parsed model — null on error.
/// [error] is the error message — null on success.
/// [statusCode] is the HTTP status code.
sealed class ApiResult<T> {
  const ApiResult();

  /// Whether the request succeeded.
  bool get isSuccess => this is ApiSuccess<T>;

  /// Whether the request failed.
  bool get isError => this is ApiError<T>;

  /// Convenience: get data or null.
  T? get dataOrNull => switch (this) {
        ApiSuccess<T> s => s.data,
        ApiError<T> _ => null,
      };

  /// Convenience: get message regardless of outcome.
  String get message => switch (this) {
        ApiSuccess<T> s => s.message,
        ApiError<T> e => e.message,
      };

  /// Pattern-match helper — mirrors Riverpod's AsyncValue.when()
  R when<R>({
    required R Function(T? data, String message, int statusCode) success,
    required R Function(String error, String message, int? statusCode) error,
  }) =>
      switch (this) {
        ApiSuccess<T> s => success(s.data, s.message, s.statusCode),
        ApiError<T> e => error(e.error, e.message, e.statusCode),
      };

  /// Pattern-match helper — only handle success, ignore error.
  void ifSuccess(void Function(T? data, String message) callback) {
    if (this case ApiSuccess<T> s) callback(s.data, s.message);
  }

  /// Pattern-match helper — only handle error.
  void ifError(void Function(String error, String message) callback) {
    if (this case ApiError<T> e) callback(e.error, e.message);
  }
}

/// A successful API response.
final class ApiSuccess<T> extends ApiResult<T> {
  const ApiSuccess(
      {required this.message, required this.statusCode, this.data, this.raw});

  /// Server message e.g. "Login successful" — use in snackbars.
  final String message;

  /// HTTP status code e.g. 200, 201.
  final int statusCode;

  /// Parsed model — null if parsing failed or no data was returned.
  final T? data;

  /// Full raw response map — available if screen needs extra fields.
  final Map<String, dynamic>? raw;
}

/// A failed API response.
final class ApiError<T> extends ApiResult<T> {
  const ApiError(
      {required this.message, required this.error, this.statusCode, this.raw});

  /// Server message if available, otherwise a generic fallback.
  final String message;

  /// Error detail — logged as warning, shown if needed.
  final String error;

  /// HTTP status code — null if request never reached the server.
  final int? statusCode;

  /// Full raw error response map if the server returned one.
  final Map<String, dynamic>? raw;
}
