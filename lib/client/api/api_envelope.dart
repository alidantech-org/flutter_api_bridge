// lib/server/api/api_envelope.dart
//
// Shared response envelope for extracting common fields from API responses.
// Used internally by ApiProvider to parse success, message, and raw data.

class ApiEnvelope {
  final bool success;
  final String message;
  final Map<String, dynamic>? raw;

  const ApiEnvelope({required this.success, required this.message, this.raw});

  factory ApiEnvelope.fromResponse(dynamic responseBody) {
    if (responseBody is Map) {
      final map = Map<String, dynamic>.from(responseBody);
      return ApiEnvelope(
          success: map['success'] == true,
          message: map['message']?.toString() ?? '',
          raw: map);
    }

    return const ApiEnvelope(success: true, message: '', raw: null);
  }

  ApiEnvelope copyWith(
      {bool? success, String? message, Map<String, dynamic>? raw}) {
    return ApiEnvelope(
        success: success ?? this.success,
        message: message ?? this.message,
        raw: raw ?? this.raw);
  }
}
