import 'dart:async';

import '../auth/auth_strategy.dart';
import '../logging/api_logger.dart';

/// Controls whether a request may use cached data.
enum ApiCachePolicy {
  /// Always use the network and never read or write cache.
  disabled,

  /// Return a fresh cache entry first, then use the network on a miss.
  cacheFirst,

  /// Try the network first and use a valid cache entry if the network fails.
  networkFirst,

  /// Return cached data immediately, including stale data, when available.
  cacheOnly,

  /// Always use the network but store successful eligible responses.
  refresh,

  /// Try the network and allow stale cached data when the network fails.
  networkWithStaleFallback,
}

/// Persistent cache configuration for one API connection.
class ApiCacheConfig {
  const ApiCacheConfig({
    this.enabled = true,
    this.defaultPolicy = ApiCachePolicy.networkFirst,
    this.defaultTtl = const Duration(minutes: 5),
    this.allowStaleOnNetworkError = true,
    this.clearPreviousSessionOnChange = true,
    this.maxEntries = 1000,
  });

  final bool enabled;
  final ApiCachePolicy defaultPolicy;
  final Duration defaultTtl;
  final bool allowStaleOnNetworkError;
  final bool clearPreviousSessionOnChange;
  final int maxEntries;
}

/// Retry behavior for one API connection.
class ApiRetryConfig {
  const ApiRetryConfig({
    this.enabled = true,
    this.maxAttempts = 3,
    this.baseDelay = const Duration(milliseconds: 300),
    this.maxDelay = const Duration(seconds: 8),
    this.retryStatusCodes = const <int>{408, 425, 429, 500, 502, 503, 504},
  });

  final bool enabled;
  final int maxAttempts;
  final Duration baseDelay;
  final Duration maxDelay;
  final Set<int> retryStatusCodes;
}

/// Stable application and installation identity attached to each request.
class ApiClientIdentity {
  const ApiClientIdentity({
    required this.applicationName,
    this.applicationVersion,
    this.buildNumber,
    this.platform,
    this.installationId,
    this.locale,
    this.extraHeaders = const <String, String>{},
  });

  final String applicationName;
  final String? applicationVersion;
  final String? buildNumber;
  final String? platform;
  final String? installationId;
  final String? locale;
  final Map<String, String> extraHeaders;

  String get userAgent {
    final version = applicationVersion?.trim();
    final primary = version == null || version.isEmpty
        ? applicationName.trim()
        : '${applicationName.trim()}/$version';
    final details = <String>[
      if (platform != null && platform!.trim().isNotEmpty) platform!.trim(),
      if (buildNumber != null && buildNumber!.trim().isNotEmpty)
        'build ${buildNumber!.trim()}',
    ];
    if (details.isEmpty) return primary;
    return '$primary (${details.join('; ')})';
  }

  Map<String, String> toHeaders() => <String, String>{
        'User-Agent': userAgent,
        'X-Client-Name': applicationName,
        if (applicationVersion != null && applicationVersion!.trim().isNotEmpty)
          'X-Client-Version': applicationVersion!.trim(),
        if (buildNumber != null && buildNumber!.trim().isNotEmpty)
          'X-Client-Build': buildNumber!.trim(),
        if (platform != null && platform!.trim().isNotEmpty)
          'X-Client-Platform': platform!.trim(),
        if (installationId != null && installationId!.trim().isNotEmpty)
          'X-Installation-Id': installationId!.trim(),
        if (locale != null && locale!.trim().isNotEmpty)
          'Accept-Language': locale!.trim(),
        ...extraHeaders,
      };
}

typedef ApiClientIdentityProvider = FutureOr<ApiClientIdentity?> Function();

/// Full runtime configuration for a named generated API package connection.
class ApiBridgeConfig {
  const ApiBridgeConfig({
    required this.baseUri,
    this.auth = const CookieStrategy(),
    this.cookiesEnabled = true,
    this.defaultHeaders = const <String, String>{},
    this.cache = const ApiCacheConfig(),
    this.retry = const ApiRetryConfig(),
    this.logging = const ApiLoggingConfig(),
    this.logger = const DeveloperApiLogger(),
    this.clientIdentity,
    this.connectTimeout = const Duration(seconds: 15),
    this.sendTimeout = const Duration(seconds: 30),
    this.receiveTimeout = const Duration(seconds: 30),
  });

  final Uri baseUri;
  final AuthStrategy auth;
  final bool cookiesEnabled;
  final Map<String, String> defaultHeaders;
  final ApiCacheConfig cache;
  final ApiRetryConfig retry;
  final ApiLoggingConfig logging;
  final ApiLogger logger;
  final ApiClientIdentityProvider? clientIdentity;
  final Duration connectTimeout;
  final Duration sendTimeout;
  final Duration receiveTimeout;
}
