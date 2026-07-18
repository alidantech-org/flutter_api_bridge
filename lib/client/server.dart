import 'auth/api_auth.dart';
import 'auth/auth_strategy.dart';
import 'config/api_bridge_config.dart';
import 'logging/api_logger.dart';
import 'runtime/api_connection.dart';
import 'runtime/flutter_api_bridge.dart';

export 'api/api_cache.dart';
export 'api/api_client.dart';
export 'api/api_envelope.dart';
export 'api/api_normalizer.dart';
export 'api/api_provider.dart';
export 'api/api_request.dart';
export 'api/api_request_options.dart';
export 'api/api_result.dart';
export 'auth/api_auth.dart';
export 'auth/auth_strategy.dart';
export 'config/api_bridge_config.dart';
export 'cookies/cookie_manager.dart';
export 'logging/api_logger.dart';
export 'runtime/api_connection.dart';
export 'runtime/flutter_api_bridge.dart';
export 'upload/upload_progress.dart';
export 'upload/upload_provider.dart';

/// Legacy default connection wrapper.
///
/// Generated packages should use [FlutterApiBridge] with their own stable key.
class Server {
  Server._();

  static const String connectionKey = 'default';

  static ApiConnection get connection =>
      FlutterApiBridge.requireConnection(connectionKey);
  static ApiAuth get auth => connection.auth;

  static Future<void> init({
    required String baseUrl,
    required AuthStrategy authStrategy,
    Duration defaultCacheTtl = const Duration(minutes: 5),
    ApiCachePolicy defaultCachePolicy = ApiCachePolicy.networkFirst,
    bool cookiesEnabled = true,
    Map<String, String> defaultHeaders = const <String, String>{},
    ApiRetryConfig retry = const ApiRetryConfig(),
    ApiLogger logger = const DeveloperApiLogger(),
    ApiLoggingConfig logging = const ApiLoggingConfig(),
    ApiClientIdentityProvider? clientIdentity,
  }) async {
    await FlutterApiBridge.configure(
      key: connectionKey,
      config: ApiBridgeConfig(
        baseUri: Uri.parse(baseUrl),
        auth: authStrategy,
        cookiesEnabled: cookiesEnabled,
        defaultHeaders: defaultHeaders,
        cache: ApiCacheConfig(
          defaultTtl: defaultCacheTtl,
          defaultPolicy: defaultCachePolicy,
        ),
        retry: retry,
        logger: logger,
        logging: logging,
        clientIdentity: clientIdentity,
      ),
    );
  }

  static Future<void> initializeUserSession({
    required String sessionId,
    String? bearerToken,
    Map<String, String>? authHeaders,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) =>
      connection.initializeUserSession(
        sessionId: sessionId,
        bearerToken: bearerToken,
        authHeaders: authHeaders,
        metadata: metadata,
      );

  static Future<void> clearCache() => connection.clearAllCache();
  static Future<void> clearSessionCache(String sessionId) =>
      connection.clearSessionCache(sessionId);
  static Future<void> logout() => connection.logout();
}
