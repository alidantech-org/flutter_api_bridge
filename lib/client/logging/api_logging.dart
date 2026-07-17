import 'dart:convert';
import 'dart:developer' as developer;

import 'package:dio/dio.dart';

/// Severity used by bridge-owned structured logs.
enum ApiLogLevel { trace, debug, info, warning, error, off }

/// High-level source of a bridge log event.
enum ApiLogCategory {
  lifecycle,
  request,
  response,
  authentication,
  refresh,
  cache,
  parsing,
}

/// Receives one already-redacted structured log event.
typedef ApiLogSink = void Function(ApiLogEvent event);

/// Logging behavior for one configured API connection.
///
/// Logging is disabled by default. Applications can enable it in development
/// and provide a custom [sink] for Crashlytics, Sentry, OpenTelemetry, or their
/// own console adapter.
class ApiLoggingConfig {
  const ApiLoggingConfig({
    this.enabled = false,
    this.minimumLevel = ApiLogLevel.info,
    this.sink,
    this.logRequestHeaders = false,
    this.logResponseHeaders = false,
    this.logRequestBody = false,
    this.logResponseBody = false,
    this.includeStackTrace = false,
    this.maxValueLength = 2048,
    this.redactedHeaders = const <String>{
      'authorization',
      'cookie',
      'set-cookie',
      'proxy-authorization',
      'x-api-key',
      'api-key',
    },
    this.redactedFields = const <String>{
      'password',
      'passwordconfirmation',
      'currentpassword',
      'newpassword',
      'passcode',
      'pin',
      'secret',
      'clientsecret',
      'token',
      'accesstoken',
      'refreshtoken',
      'temporarytoken',
      'idtoken',
      'authorization',
      'cookie',
    },
  });

  final bool enabled;
  final ApiLogLevel minimumLevel;
  final ApiLogSink? sink;
  final bool logRequestHeaders;
  final bool logResponseHeaders;
  final bool logRequestBody;
  final bool logResponseBody;
  final bool includeStackTrace;
  final int maxValueLength;
  final Set<String> redactedHeaders;
  final Set<String> redactedFields;

  bool allows(ApiLogLevel level) {
    if (!enabled || level == ApiLogLevel.off) return false;
    return level.index >= minimumLevel.index;
  }
}

/// One structured bridge log record.
class ApiLogEvent {
  const ApiLogEvent({
    required this.timestamp,
    required this.level,
    required this.category,
    required this.connectionKey,
    required this.message,
    this.requestId,
    this.method,
    this.uri,
    this.statusCode,
    this.duration,
    this.metadata = const <String, Object?>{},
    this.error,
    this.stackTrace,
  });

  final DateTime timestamp;
  final ApiLogLevel level;
  final ApiLogCategory category;
  final String connectionKey;
  final String message;
  final String? requestId;
  final String? method;
  final Uri? uri;
  final int? statusCode;
  final Duration? duration;
  final Map<String, Object?> metadata;
  final Object? error;
  final StackTrace? stackTrace;

  @override
  String toString() {
    final parts = <String>[
      '[${category.name}]',
      message,
      if (method != null) method!,
      if (uri != null) uri.toString(),
      if (statusCode != null) 'status=$statusCode',
      if (duration != null) 'durationMs=${duration!.inMilliseconds}',
      if (requestId != null) 'requestId=$requestId',
      if (metadata.isNotEmpty) 'metadata=$metadata',
    ];
    return parts.join(' ');
  }
}

/// Emits redacted log records for one named API connection.
class ApiLogger {
  ApiLogger({
    required this.connectionKey,
    required this.config,
  }) : redactor = ApiLogRedactor(config);

  final String connectionKey;
  final ApiLoggingConfig config;
  final ApiLogRedactor redactor;

  void log(
    ApiLogLevel level,
    ApiLogCategory category,
    String message, {
    String? requestId,
    String? method,
    Uri? uri,
    int? statusCode,
    Duration? duration,
    Map<String, Object?> metadata = const <String, Object?>{},
    Object? error,
    StackTrace? stackTrace,
  }) {
    if (!config.allows(level)) return;

    final event = ApiLogEvent(
      timestamp: DateTime.now().toUtc(),
      level: level,
      category: category,
      connectionKey: connectionKey,
      message: message,
      requestId: requestId,
      method: method,
      uri: uri,
      statusCode: statusCode,
      duration: duration,
      metadata: redactor.metadata(metadata),
      error: redactor.value(error),
      stackTrace: config.includeStackTrace ? stackTrace : null,
    );

    final sink = config.sink;
    if (sink != null) {
      sink(event);
      return;
    }

    developer.log(
      event.toString(),
      name: 'flutter_api_bridge.$connectionKey',
      level: _developerLevel(level),
      error: event.error,
      stackTrace: event.stackTrace,
      time: event.timestamp,
    );
  }

  int _developerLevel(ApiLogLevel level) {
    return switch (level) {
      ApiLogLevel.trace => 400,
      ApiLogLevel.debug => 500,
      ApiLogLevel.info => 800,
      ApiLogLevel.warning => 900,
      ApiLogLevel.error => 1000,
      ApiLogLevel.off => 0,
    };
  }
}

/// Redacts credentials and sensitive body fields before anything reaches a
/// logging sink.
class ApiLogRedactor {
  ApiLogRedactor(this.config)
      : _headers = config.redactedHeaders.map(_normalizeKey).toSet(),
        _fields = config.redactedFields.map(_normalizeKey).toSet();

  static const String redacted = '<redacted>';

  final ApiLoggingConfig config;
  final Set<String> _headers;
  final Set<String> _fields;

  Map<String, Object?> headers(Map<String, dynamic>? source) {
    if (source == null || source.isEmpty) return const <String, Object?>{};

    return source.map((key, value) {
      final normalized = _normalizeKey(key);
      return MapEntry(
        key,
        _headers.contains(normalized) ? redacted : this.value(value),
      );
    });
  }

  Map<String, Object?> metadata(Map<String, Object?> source) {
    if (source.isEmpty) return const <String, Object?>{};
    return source.map((key, value) => MapEntry(key, _redactField(key, value)));
  }

  Object? body(Object? source) => value(source);

  Object? value(Object? source, {String? fieldName}) {
    if (fieldName != null && _isSensitiveField(fieldName)) return redacted;
    if (source == null || source is num || source is bool) return source;
    if (source is DateTime) return source.toUtc().toIso8601String();
    if (source is Uri) return source.toString();
    if (source is Enum) return source.name;
    if (source is MultipartFile) return '<multipart-file>';

    if (source is FormData) {
      return <String, Object?>{
        'fields': source.fields.map((entry) => MapEntry(entry.key, _redactField(entry.key, entry.value))).toList(),
        'files': source.files
            .map((entry) => <String, Object?>{
                  'field': entry.key,
                  'filename': entry.value.filename,
                  'length': entry.value.length,
                })
            .toList(),
      };
    }

    if (source is Map) {
      final output = <String, Object?>{};
      for (final entry in source.entries) {
        final key = entry.key.toString();
        output[key] = _redactField(key, entry.value);
      }
      return output;
    }

    if (source is Iterable) {
      return source.take(100).map((item) => value(item)).toList(growable: false);
    }

    if (source is String) {
      final text = source.trim();
      if (text.isEmpty) return text;

      if ((text.startsWith('{') && text.endsWith('}')) || (text.startsWith('[') && text.endsWith(']'))) {
        try {
          return value(jsonDecode(text));
        } catch (_) {
          // Non-JSON text is safely truncated below.
        }
      }
      return _truncate(text);
    }

    try {
      final dynamic json = (source as dynamic).toJson();
      return value(json);
    } catch (_) {
      return _truncate(source.toString());
    }
  }

  Object? _redactField(String key, Object? source) {
    if (_isSensitiveField(key)) return redacted;
    return value(source, fieldName: key);
  }

  bool _isSensitiveField(String key) {
    final normalized = _normalizeKey(key);
    if (_fields.contains(normalized)) return true;
    return normalized.contains('password') ||
        normalized.contains('secret') ||
        normalized.endsWith('token') ||
        normalized == 'authorization' ||
        normalized == 'cookie';
  }

  String _truncate(String value) {
    final limit = config.maxValueLength;
    if (limit <= 0 || value.length <= limit) return value;
    return '${value.substring(0, limit)}…';
  }

  static String _normalizeKey(String value) {
    return value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  }
}