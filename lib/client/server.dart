import 'package:hive_flutter/hive_flutter.dart';

import 'api/api_cache.dart';
import 'api/api_client.dart';
import 'auth/api_auth.dart';
import 'auth/auth_strategy.dart';
import 'cookies/cookie_manager.dart';
import 'logging/api_logger.dart';
import 'server_config.dart';

export 'api/api_client.dart'
    show ApiClient, AuthEvents, UnauthorizedEvent, ForbiddenEvent;
export 'api/api_cache.dart';
export 'api/api_envelope.dart';
export 'api/api_provider.dart';
export 'api/api_request.dart';
export 'api/api_request_options.dart';
export 'api/api_result.dart';
export 'auth/api_auth.dart';
export 'auth/auth_strategy.dart';
export 'cookies/cookie_events.dart';
export 'cookies/cookie_manager.dart';
export 'logging/api_logger.dart';
export 'server_config.dart';
export 'upload/upload_provider.dart';
export 'upload/upload_progress.dart';

/// Legacy global bridge entry point.
///
/// New generated clients should use connection-scoped APIs, but this class
/// remains supported while consumers migrate.
class Server {
  Server._();

  static ApiAuth? _auth;

  /// Authoritative transport-auth state for the configured server.
  static ApiAuth get auth {
    final value = _auth;
    if (value == null) {
      throw StateError('Server is not initialized. Call Server.init() first.');
    }
    return value;
  }

  static Future<void> init({
    required String baseUrl,
    required AuthStrategy authStrategy,
    String defaultVersion = '',
    Duration defaultCacheTtl = const Duration(minutes: 5),
    String? apiKey,
    ApiLogger logger = const DeveloperApiLogger(),
    ApiLoggingConfig logging = const ApiLoggingConfig(),
  }) async {
    await Hive.initFlutter();

    ServerConfig.baseUrl = baseUrl;
    ServerConfig.defaultCacheTtl = defaultCacheTtl;
    ServerConfig.apiKey = apiKey;

    await ApiCache.init();
    await CookieManager.init(baseUrl);

    final previousAuth = _auth;
    if (previousAuth != null) await previousAuth.dispose();

    final configuredAuth = ApiAuth(
      strategy: authStrategy,
      logger: logger,
      logging: logging,
    );
    _auth = configuredAuth;

    ApiClient.init(
      baseUrl: baseUrl,
      authStrategy: authStrategy,
      auth: configuredAuth,
      logger: logger,
      logging: logging,
    );

    await configuredAuth.initialize();
  }

  static Future<void> clearCache() => ApiCache.clearAll();

  /// Clears bridge-managed transport authentication.
  static Future<void> clearAuth({String? tokenKey}) async {
    final configuredAuth = _auth;
    if (configuredAuth != null) {
      await configuredAuth.clear();
    } else if (tokenKey != null) {
      // Compatibility for callers clearing before initialization.
      await BearerStrategy.clearToken(key: tokenKey);
    }
    ApiClient.reset();
  }

  /// Clears cache, credentials, and cookies.
  static Future<void> logout({String? tokenKey}) async {
    await clearCache();
    await clearAuth(tokenKey: tokenKey);
    await CookieManager.clearAll();
  }
}
