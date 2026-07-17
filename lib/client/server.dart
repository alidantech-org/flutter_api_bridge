// lib/server/server.dart
//
// Backwards-compatible legacy entry point plus the modern named-connection API.

import 'package:hive_flutter/hive_flutter.dart';

import 'api/api_cache.dart';
import 'api/api_client.dart';
import 'auth/auth_strategy.dart';
import 'cookies/cookie_manager.dart';
import 'server_config.dart';

// ── Modern generated-client runtime ──────────────────────────────────────────

export 'api/api_bridge_config.dart';
export 'api/api_connection.dart';
export 'auth/api_auth.dart';
export 'auth/auth_config.dart';
export 'auth/auth_session.dart';
export 'flutter_api_bridge_runtime.dart';
export 'logging/api_logging.dart';

// ── Shared request/result APIs ────────────────────────────────────────────────

export 'api/api_cache.dart';
export 'api/api_envelope.dart';
export 'api/api_provider.dart';
export 'api/api_request.dart';
export 'api/api_request_options.dart';
export 'api/api_result.dart';
export 'upload/upload_provider.dart';
export 'upload/upload_progress.dart';

// ── Legacy APIs retained for existing applications ──────────────────────────

export 'api/api_client.dart'
    show ApiClient, AuthEvents, UnauthorizedEvent, ForbiddenEvent;
export 'auth/auth_strategy.dart';
export 'cookies/cookie_events.dart';
export 'cookies/cookie_manager.dart';
export 'server_config.dart';

/// Legacy global API initialization facade.
///
/// New generated API packages should use [FlutterApiBridge.configure] with an
/// [ApiBridgeConfig]. This class remains available to avoid breaking existing
/// applications that still use [ApiClient] and Riverpod's `apiProvider`.
class Server {
  Server._();

  static Future<void> init({
    required String baseUrl,
    required AuthStrategy authStrategy,
    String defaultVersion = '',
    Duration defaultCacheTtl = const Duration(minutes: 5),
    String? apiKey,
  }) async {
    await Hive.initFlutter();

    ServerConfig.baseUrl = baseUrl;
    ServerConfig.defaultCacheTtl = defaultCacheTtl;
    ServerConfig.apiKey = apiKey;

    await ApiCache.init();
    await CookieManager.init(baseUrl);
    ApiClient.init(baseUrl: baseUrl, authStrategy: authStrategy);
  }

  static Future<void> clearCache() => ApiCache.clearAll();

  static Future<void> clearAuth({required String tokenKey}) async {
    await BearerStrategy.clearToken(key: tokenKey);
    ApiClient.reset();
  }

  static Future<void> logout({required String tokenKey}) async {
    await clearCache();
    await clearAuth(tokenKey: tokenKey);
    await CookieManager.clearAll();
  }
}