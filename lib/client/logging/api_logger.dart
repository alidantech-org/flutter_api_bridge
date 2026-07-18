import 'dart:developer' as developer;

enum ApiLogLevel { debug, info, warning, error }

enum ApiLogEventType {
  request,
  response,
  failure,
  retry,
  cache,
  auth,
  lifecycle,
}

class ApiLogEvent {
  const ApiLogEvent({
    required this.level,
    required this.type,
    required this.message,
    required this.timestamp,
    this.method,
    this.path,
    this.statusCode,
    this.duration,
    this.requestId,
    this.operationId,
    this.attempt,
    this.data = const <String, Object?>{},
    this.error,
    this.stackTrace,
  });

  final ApiLogLevel level;
  final ApiLogEventType type;
  final String message;
  final DateTime timestamp;
  final String? method;
  final String? path;
  final int? statusCode;
  final Duration? duration;
  final String? requestId;
  final String? operationId;
  final int? attempt;
  final Map<String, Object?> data;
  final Object? error;
  final StackTrace? stackTrace;
}

abstract interface class ApiLogger {
  const ApiLogger();

  void log(ApiLogEvent event);
}

class DeveloperApiLogger implements ApiLogger {
  const DeveloperApiLogger({this.name = 'flutter_api_bridge'});

  final String name;

  @override
  void log(ApiLogEvent event) {
    const redactor = ApiLogRedactor(ApiLoggingConfig.defaultSensitiveKeys);
    final safeData = redactor.redact(event.data);
    final details = <String>[
      event.type.name,
      if (event.operationId != null) event.operationId!,
      if (event.method != null) event.method!,
      if (event.path != null) event.path!,
      if (event.statusCode != null) 'HTTP ${event.statusCode}',
      if (event.duration != null) '${event.duration!.inMilliseconds}ms',
      if (event.attempt != null) 'attempt ${event.attempt}',
      if (event.requestId != null) 'request ${event.requestId}',
      if (safeData is Map && safeData.isNotEmpty) safeData.toString(),
    ].join(' · ');

    developer.log(
      details.isEmpty ? event.message : '${event.message} | $details',
      name: name,
      level: switch (event.level) {
        ApiLogLevel.debug => 500,
        ApiLogLevel.info => 800,
        ApiLogLevel.warning => 900,
        ApiLogLevel.error => 1000,
      },
      error: event.error,
      stackTrace: event.stackTrace,
      time: event.timestamp,
    );
  }
}

class ApiLoggingConfig {
  const ApiLoggingConfig({
    this.enabled = true,
    this.logRequestHeaders = false,
    this.logRequestBody = false,
    this.logResponseBody = false,
    this.sensitiveKeys = defaultSensitiveKeys,
  });

  final bool enabled;
  final bool logRequestHeaders;
  final bool logRequestBody;
  final bool logResponseBody;
  final Set<String> sensitiveKeys;

  static const Set<String> defaultSensitiveKeys = <String>{
    'authorization',
    'proxy-authorization',
    'cookie',
    'set-cookie',
    'password',
    'currentpassword',
    'newpassword',
    'confirmpassword',
    'token',
    'accesstoken',
    'refreshtoken',
    'idtoken',
    'apikey',
    'api-key',
    'x-api-key',
    'secret',
    'clientsecret',
    'otp',
    'code',
  };
}

class ApiLogRedactor {
  const ApiLogRedactor(this.sensitiveKeys);

  final Set<String> sensitiveKeys;

  Object? redact(Object? value) {
    if (value is Map) {
      return <String, Object?>{
        for (final entry in value.entries)
          entry.key.toString(): _isSensitive(entry.key.toString())
              ? '[REDACTED]'
              : redact(entry.value),
      };
    }
    if (value is Iterable) {
      return value.map(redact).toList(growable: false);
    }
    return value;
  }

  bool _isSensitive(String key) {
    final normalized =
        key.toLowerCase().replaceAll(RegExp(r'[^a-z0-9-]'), '');
    return sensitiveKeys.any((candidate) {
      final normalizedCandidate = candidate
          .toLowerCase()
          .replaceAll(RegExp(r'[^a-z0-9-]'), '');
      return normalized == normalizedCandidate ||
          normalized.contains(normalizedCandidate);
    });
  }
}
