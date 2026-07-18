import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// Severity retained for backward compatibility with custom [ApiLogger]s.
enum ApiLogLevel { debug, info, warning, error }

/// Controls which package events are emitted.
enum ApiLoggingLevel { none, errors, basic, detailed }

enum ApiLogEventType {
  request,
  response,
  failure,
  retry,
  cache,
  auth,
  lifecycle,
}

/// Client-only logging controls for one request.
class ApiCallLogOptions {
  const ApiCallLogOptions({
    this.enabled = true,
    this.requestHeaders = false,
    this.requestBody = false,
    this.responseHeaders = false,
    this.responseBody = false,
    this.queryParameters = false,
    this.cookies = false,
  });

  final bool enabled;
  final bool requestHeaders;
  final bool requestBody;
  final bool responseHeaders;
  final bool responseBody;
  final bool queryParameters;
  final bool cookies;
}

class ApiResolvedLogOptions {
  const ApiResolvedLogOptions({
    required this.enabled,
    required this.level,
    required this.requestHeaders,
    required this.requestBody,
    required this.responseHeaders,
    required this.responseBody,
    required this.queryParameters,
    required this.cookies,
    required this.showDuration,
    required this.showRequestId,
    required this.prettyPrintBodies,
    required this.useAnsi,
    required this.redactor,
  });

  final bool enabled;
  final ApiLoggingLevel level;
  final bool requestHeaders;
  final bool requestBody;
  final bool responseHeaders;
  final bool responseBody;
  final bool queryParameters;
  final bool cookies;
  final bool showDuration;
  final bool showRequestId;
  final bool prettyPrintBodies;
  final bool useAnsi;
  final ApiLogRedactor redactor;
}

/// Structured package event delivered to [ApiLogger] implementations.
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
    this.maxAttempts,
    this.retryDelay,
    this.source,
    this.code,
    this.data = const <String, Object?>{},
    this.error,
    this.stackTrace,
    this.options,
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
  final int? maxAttempts;
  final Duration? retryDelay;
  final String? source;
  final String? code;
  final Map<String, Object?> data;
  final Object? error;
  final StackTrace? stackTrace;
  final ApiResolvedLogOptions? options;
}

class ApiRequestLogEvent extends ApiLogEvent {
  const ApiRequestLogEvent({
    required super.timestamp,
    required super.method,
    required super.path,
    required super.operationId,
    required super.requestId,
    required super.attempt,
    required super.maxAttempts,
    required super.options,
    super.data,
  }) : super(
          level: ApiLogLevel.debug,
          type: ApiLogEventType.request,
          message: 'API request',
        );
}

class ApiResponseLogEvent extends ApiLogEvent {
  const ApiResponseLogEvent({
    required super.timestamp,
    required super.method,
    required super.path,
    required super.operationId,
    required super.requestId,
    required super.statusCode,
    required super.duration,
    required super.source,
    required super.options,
    super.attempt,
    super.data,
  }) : super(
          level: ApiLogLevel.info,
          type: ApiLogEventType.response,
          message: 'API response',
        );
}

class ApiErrorLogEvent extends ApiLogEvent {
  const ApiErrorLogEvent({
    required super.timestamp,
    required super.method,
    required super.path,
    required super.operationId,
    required super.requestId,
    required super.duration,
    required super.options,
    super.statusCode,
    super.attempt,
    super.code,
    super.data,
    super.error,
    super.stackTrace,
  }) : super(
          level: ApiLogLevel.error,
          type: ApiLogEventType.failure,
          message: 'API request failed',
        );
}

class ApiRetryLogEvent extends ApiLogEvent {
  const ApiRetryLogEvent({
    required super.timestamp,
    required super.operationId,
    required super.attempt,
    required super.maxAttempts,
    required super.retryDelay,
    required super.options,
    super.requestId,
    super.code,
    super.data,
  }) : super(
          level: ApiLogLevel.warning,
          type: ApiLogEventType.retry,
          message: 'API request will retry',
        );
}

class ApiCacheLogEvent extends ApiLogEvent {
  const ApiCacheLogEvent({
    required super.timestamp,
    required super.operationId,
    required super.source,
    required super.options,
    super.data,
  }) : super(
          level: ApiLogLevel.debug,
          type: ApiLogEventType.cache,
          message: 'API cache event',
        );
}

class ApiAuthLogEvent extends ApiLogEvent {
  const ApiAuthLogEvent({
    required super.timestamp,
    required super.options,
    required super.data,
    super.level = ApiLogLevel.info,
  }) : super(
          type: ApiLogEventType.auth,
          message: 'Authentication state changed',
        );
}

abstract interface class ApiLogger {
  const ApiLogger();

  void log(ApiLogEvent event);
}

typedef ApiLogSink = void Function(ApiLogEvent event);

class CallbackApiLogger implements ApiLogger {
  const CallbackApiLogger(this.sink);

  final ApiLogSink sink;

  @override
  void log(ApiLogEvent event) => sink(event);
}

class DeveloperApiLogger implements ApiLogger {
  const DeveloperApiLogger({
    this.name = 'flutter_api_bridge',
    this.formatter = const ApiLogFormatter(),
  });

  final String name;
  final ApiLogFormatter formatter;

  @override
  void log(ApiLogEvent event) {
    try {
      developer.log(
        formatter.format(event),
        name: name,
        level: switch (event.level) {
          ApiLogLevel.debug => 500,
          ApiLogLevel.info => 800,
          ApiLogLevel.warning => 900,
          ApiLogLevel.error => 1000,
        },
        time: event.timestamp,
      );
    } catch (_) {
      // Diagnostics must never affect a request.
    }
  }
}

class ApiLoggingConfig {
  const ApiLoggingConfig({
    this.enabled = true,
    this.level = ApiLoggingLevel.basic,
    this.logRequestHeaders = false,
    this.logRequestBody = false,
    this.logResponseHeaders = false,
    this.logResponseBody = false,
    this.logQueryParameters = false,
    this.logCookies = false,
    this.showDuration = true,
    this.showRequestId = false,
    this.prettyPrintBodies = true,
    this.useAnsi = false,
    this.sensitiveKeys = defaultSensitiveKeys,
    this.maxDepth = 6,
    this.maxCollectionItems = 30,
    this.maxStringLength = 500,
  });

  final bool enabled;
  final ApiLoggingLevel level;
  final bool logRequestHeaders;
  final bool logRequestBody;
  final bool logResponseHeaders;
  final bool logResponseBody;
  final bool logQueryParameters;
  final bool logCookies;
  final bool showDuration;
  final bool showRequestId;
  final bool prettyPrintBodies;
  final bool useAnsi;
  final Set<String> sensitiveKeys;
  final int maxDepth;
  final int maxCollectionItems;
  final int maxStringLength;

  ApiResolvedLogOptions resolve([ApiCallLogOptions? call]) {
    final callEnabled = call?.enabled ?? true;
    return ApiResolvedLogOptions(
      enabled: enabled && level != ApiLoggingLevel.none && callEnabled,
      level: level,
      requestHeaders: call?.requestHeaders ?? logRequestHeaders,
      requestBody: call?.requestBody ?? logRequestBody,
      responseHeaders: call?.responseHeaders ?? logResponseHeaders,
      responseBody: call?.responseBody ?? logResponseBody,
      queryParameters: call?.queryParameters ?? logQueryParameters,
      cookies: call?.cookies ?? logCookies,
      showDuration: showDuration,
      showRequestId: showRequestId,
      prettyPrintBodies: prettyPrintBodies,
      useAnsi: useAnsi,
      redactor: ApiLogRedactor(
        sensitiveKeys,
        maxDepth: maxDepth,
        maxCollectionItems: maxCollectionItems,
        maxStringLength: maxStringLength,
      ),
    );
  }

  static const Set<String> defaultSensitiveKeys = <String>{
    'authorization',
    'proxyauthorization',
    'cookie',
    'setcookie',
    'password',
    'passwordconfirmation',
    'currentpassword',
    'newpassword',
    'confirmpassword',
    'token',
    'accesstoken',
    'refreshtoken',
    'idtoken',
    'sessiontoken',
    'apikey',
    'secret',
    'clientsecret',
    'otp',
    'pin',
    'signature',
    'credential',
  };
}

class ApiLogFormatter {
  const ApiLogFormatter();

  String format(ApiLogEvent event) {
    final options = event.options;
    final redactor = options?.redactor ??
        const ApiLogRedactor(ApiLoggingConfig.defaultSensitiveKeys);
    final data = redactor.redact(event.data);
    final safeData =
        data is Map<String, Object?> ? data : const <String, Object?>{};
    final summary = switch (event.type) {
      ApiLogEventType.request => _request(event),
      ApiLogEventType.response => _response(event, options),
      ApiLogEventType.failure => _error(event, safeData, options),
      ApiLogEventType.retry => _retry(event),
      ApiLogEventType.cache => _cache(event, safeData),
      ApiLogEventType.auth => _auth(safeData),
      ApiLogEventType.lifecycle => 'LIFECYCLE: ${event.message}',
    };
    final metadata = _metadata(event, safeData, options);
    if (metadata.isEmpty) return summary;
    return '$summary\n${metadata.map((line) => '  ↳ $line').join('\n')}';
  }

  String _request(ApiLogEvent event) =>
      'REQ: ${_operation(event)} · ${event.method ?? '-'} · ${event.path ?? '-'}';

  String _response(ApiLogEvent event, ApiResolvedLogOptions? options) {
    final duration = options?.showDuration != false && event.duration != null
        ? ' · ${event.duration!.inMilliseconds}ms'
        : '';
    return 'RES: ${_operation(event)} · ${event.method ?? '-'} · ${event.path ?? '-'} · ${event.statusCode ?? '-'}$duration';
  }

  String _error(
    ApiLogEvent event,
    Map<String, Object?> data,
    ApiResolvedLogOptions? options,
  ) {
    final duration = options?.showDuration != false && event.duration != null
        ? ' · ${event.duration!.inMilliseconds}ms'
        : '';
    return 'ERR: ${_operation(event)} · ${event.method ?? '-'} · ${event.path ?? '-'} · ${event.statusCode ?? '-'}$duration';
  }

  String _retry(ApiLogEvent event) {
    final attempt = event.attempt ?? 1;
    final total = event.maxAttempts ?? attempt;
    final delay = event.retryDelay?.inMilliseconds ?? 0;
    return 'RETRY: ${_operation(event)} · attempt $attempt/$total · in ${delay}ms';
  }

  String _cache(ApiLogEvent event, Map<String, Object?> data) =>
      'CACHE: ${_operation(event)} · ${data['cache'] ?? 'hit'}';

  String _auth(Map<String, Object?> data) =>
      'AUTH: ${data['status'] ?? 'unknown'}';

  List<String> _metadata(
    ApiLogEvent event,
    Map<String, Object?> data,
    ApiResolvedLogOptions? options,
  ) {
    final output = <String>[];
    if (event.type == ApiLogEventType.request && event.attempt != null) {
      output.add('attempt=${event.attempt}');
    }
    if (event.source != null) output.add('source=${event.source}');
    if (options?.showRequestId == true && event.requestId != null) {
      output.add('request=${_shorten(event.requestId!)}');
    }
    if (event.code != null) output.add('code=${event.code}');
    for (final entry in data.entries) {
      if (entry.key == 'status' ||
          event.type == ApiLogEventType.cache && entry.key == 'cache' ||
          entry.key == 'body' && entry.value == null) {
        continue;
      }
      output.add('${entry.key}=${_render(entry.value, options)}');
    }
    return output;
  }

  String _render(Object? value, ApiResolvedLogOptions? options) {
    if (value is Map || value is Iterable) {
      try {
        if (options?.prettyPrintBodies == true) {
          return const JsonEncoder.withIndent('  ').convert(value);
        }
        return jsonEncode(value);
      } catch (_) {
        return value.toString();
      }
    }
    final text = value?.toString() ?? 'null';
    return text.contains(RegExp(r'\s')) ? jsonEncode(text) : text;
  }

  String _operation(ApiLogEvent event) =>
      event.operationId?.trim().isNotEmpty == true
          ? event.operationId!.trim()
          : 'unknown';

  String _shorten(String value) =>
      value.length <= 12 ? value : '${value.substring(0, 12)}...';
}

class ApiLogRedactor {
  const ApiLogRedactor(
    this.sensitiveKeys, {
    this.maxDepth = 6,
    this.maxCollectionItems = 30,
    this.maxStringLength = 500,
  });

  final Set<String> sensitiveKeys;
  final int maxDepth;
  final int maxCollectionItems;
  final int maxStringLength;

  Object? redact(Object? value) => _redact(
        value,
        depth: 0,
        seen: HashSet<Object>.identity(),
      );

  Object? _redact(
    Object? value, {
    required int depth,
    required Set<Object> seen,
  }) {
    if (value == null || value is num || value is bool) return value;
    if (value is String) return _safeString(value);
    if (value is Uri) return _safeUri(value).toString();
    if (value is Uint8List || value is ByteBuffer || value is ByteData) {
      final length = value is Uint8List ? value.length : null;
      return '[BINARY${length == null ? '' : ' $length bytes'}]';
    }
    if (value is Stream) return '[STREAM]';
    if (value is MultipartFile) {
      return <String, Object?>{
        'type': 'file',
        'filename':
            value.filename == null ? null : _safeString(value.filename!),
        'size': value.length,
      };
    }
    if (value is FormData) {
      return <String, Object?>{
        'type': 'multipart',
        'fields': value.fields.length,
        'files': value.files.length,
        'size': value.files
            .fold<int>(0, (total, entry) => total + entry.value.length),
      };
    }
    if (depth >= maxDepth) return '[MAX_DEPTH]';
    if (!seen.add(value)) return '[CIRCULAR]';
    try {
      if (value is Map) {
        final output = <String, Object?>{};
        var count = 0;
        for (final entry in value.entries) {
          if (count >= maxCollectionItems) {
            output['...'] = '[TRUNCATED ${value.length - count} items]';
            break;
          }
          final key = entry.key.toString();
          output[key] = _isSensitive(key)
              ? '[REDACTED]'
              : _redact(entry.value, depth: depth + 1, seen: seen);
          count += 1;
        }
        return output;
      }
      if (value is Iterable) {
        if (value is List<int>) return '[BINARY ${value.length} bytes]';
        final output = <Object?>[];
        final iterator = value.iterator;
        while (output.length < maxCollectionItems && iterator.moveNext()) {
          output.add(_redact(iterator.current, depth: depth + 1, seen: seen));
        }
        if (iterator.moveNext()) output.add('[TRUNCATED]');
        return output;
      }
      return _safeString(value.toString());
    } finally {
      seen.remove(value);
    }
  }

  bool _isSensitive(String key) {
    final normalized = _normalizeKey(key);
    return sensitiveKeys.any((candidate) {
      final expected = _normalizeKey(candidate);
      return normalized == expected || normalized.contains(expected);
    });
  }

  String _normalizeKey(String key) =>
      key.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');

  String _safeString(String value) {
    final uri = Uri.tryParse(value);
    final safe =
        uri != null && uri.hasScheme ? _safeUri(uri).toString() : value;
    if (safe.length <= maxStringLength) return safe;
    return '${safe.substring(0, maxStringLength)}...[TRUNCATED]';
  }

  Uri _safeUri(Uri uri) {
    if (!uri.hasQuery) return uri.replace(userInfo: '');
    final query = <String, String>{};
    for (final entry in uri.queryParameters.entries) {
      query[entry.key] = _isSensitive(entry.key) ? '[REDACTED]' : entry.value;
    }
    return uri.replace(userInfo: '', queryParameters: query);
  }
}
