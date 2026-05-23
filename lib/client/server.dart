// lib/server/server.dart
//
// Single barrel export + initialisation entry point.
// Call [Server.init] once in main() before runApp().

import 'package:hive_flutter/hive_flutter.dart';
import 'api/api_cache.dart';
import 'api/api_client.dart';
import 'auth/auth_strategy.dart';
import 'cookies/cookie_manager.dart';
import 'server_config.dart';

// ── Public exports ───────────────────────────────────────────────────────────────

export 'api/api_client.dart'
    show ApiClient, AuthEvents, UnauthorizedEvent, ForbiddenEvent;
export 'api/api_cache.dart';
export 'api/api_envelope.dart';
export 'api/api_provider.dart';
export 'api/api_request.dart';
export 'api/api_request_options.dart';
export 'api/api_result.dart';
export 'auth/auth_strategy.dart';
export 'cookies/cookie_events.dart';
export 'cookies/cookie_manager.dart';
export 'server_config.dart';
export 'upload/upload_provider.dart';
export 'upload/upload_progress.dart';

// ── Initialisation ─────────────────────────────────────────────────────────────

class Server {
  Server._();

  /// Initialise the entire server layer.
  /// Call once in [main] before [runApp].
  ///
  /// ```dart
  /// await Server.init(
  ///   baseUrl: 'https://api.example.com',
  ///   authStrategy: BearerStrategy(tokenKey: 'access_token'),
  ///   defaultCacheTtl: Duration(minutes: 5),
  /// );
  /// ```
  static Future<void> init({
    required String baseUrl,
    required AuthStrategy authStrategy,
    String defaultVersion = '',
    Duration defaultCacheTtl = const Duration(minutes: 5),
    String? apiKey,
  }) async {
    // 1. Hive
    await Hive.initFlutter();

    // 2. Config
    ServerConfig.baseUrl = baseUrl;
    ServerConfig.defaultCacheTtl = defaultCacheTtl;
    ServerConfig.apiKey = apiKey;

    // 3. Cache
    await ApiCache.init();

    // 4. Cookies
    await CookieManager.init(baseUrl);

    // 5. Dio clients
    ApiClient.init(baseUrl: baseUrl, authStrategy: authStrategy);
  }

  /// Clear all cached API responses — call on logout.
  static Future<void> clearCache() => ApiCache.clearAll();

  /// Clear auth token and Dio instances — call on logout.
  static Future<void> clearAuth({required String tokenKey}) async {
    await BearerStrategy.clearToken(key: tokenKey);
    ApiClient.reset();
  }

  /// Full reset — cache + auth + cookies. Call on logout.
  static Future<void> logout({required String tokenKey}) async {
    await clearCache();
    await clearAuth(tokenKey: tokenKey);
    await CookieManager.clearAll();
  }
}
