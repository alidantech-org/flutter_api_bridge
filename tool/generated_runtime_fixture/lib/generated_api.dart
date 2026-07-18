library generated_api;

import 'package:flutter_api_bridge/flutter_api_bridge.dart';

export 'package:flutter_api_bridge/flutter_api_bridge.dart'
    show
        ApiAuth,
        ApiBridgeConfig,
        ApiCacheConfig,
        ApiCachePolicy,
        ApiClientIdentity,
        ApiClientIdentityProvider,
        ApiConnection,
        ApiDataSource,
        ApiGetRequestOptions,
        ApiLogger,
        ApiLoggingConfig,
        ApiRequestOptions,
        ApiResult,
        ApiRetryConfig,
        ApiUploadRequestOptions,
        AuthSession,
        AuthSessionStatus,
        AuthStrategy,
        BearerStrategy,
        CookieStrategy,
        DeveloperApiLogger,
        UploadFile;

/// Representative root facade emitted by a generated API package.
class GeneratedApi {
  GeneratedApi._(ApiConnection connection) : v1 = GeneratedV1Client(connection);

  static const String connectionKey = 'generated_api_fixture';

  static GeneratedApi? _instance;

  static Future<void> configure(
    ApiBridgeConfig config, {
    bool replace = true,
  }) async {
    await FlutterApiBridge.configure(
      key: connectionKey,
      config: config,
      replace: replace,
    );
    _instance = null;
  }

  static Future<void> initialize({
    required Uri baseUri,
    AuthStrategy auth = const CookieStrategy(),
    bool cookiesEnabled = true,
    Map<String, String> defaultHeaders = const <String, String>{},
    ApiCacheConfig cache = const ApiCacheConfig(),
    ApiRetryConfig retry = const ApiRetryConfig(),
    ApiLogger logger = const DeveloperApiLogger(),
    ApiLoggingConfig logging = const ApiLoggingConfig(),
    ApiClientIdentityProvider? clientIdentity,
  }) =>
      configure(
        ApiBridgeConfig(
          baseUri: baseUri,
          auth: auth,
          cookiesEnabled: cookiesEnabled,
          defaultHeaders: defaultHeaders,
          cache: cache,
          retry: retry,
          logger: logger,
          logging: logging,
          clientIdentity: clientIdentity,
        ),
      );

  static ApiConnection get connection =>
      FlutterApiBridge.requireConnection(connectionKey);

  static ApiAuth get auth => connection.auth;

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

  static Future<void> clearActiveSessionCache() =>
      connection.clearActiveSessionCache();

  static Future<void> clearSessionCache(String sessionId) =>
      connection.clearSessionCache(sessionId);

  static Future<void> clearAllCache() => connection.clearAllCache();

  static Future<void> logout() async {
    await connection.logout();
    _instance = null;
  }

  static GeneratedApi get instance => _instance ??= GeneratedApi._(connection);

  final GeneratedV1Client v1;
}

class GeneratedV1Client {
  GeneratedV1Client(ApiConnection connection)
      : things = GeneratedThingsFeature(connection);

  final GeneratedThingsFeature things;
}

class GeneratedThingsFeature {
  const GeneratedThingsFeature(this._connection);

  final ApiConnection _connection;

  Future<ApiResult<Map<String, dynamic>>> list({
    ApiGetRequestOptions? options,
  }) =>
      _connection.execute(
        GetRequest<Map<String, dynamic>>(
          endpoint: '/things',
          options: (options ?? const ApiGetRequestOptions()).copyWith(
            operationId: 'things.list',
          ),
          fromJson: (json) => Map<String, dynamic>.from(json as Map),
        ),
      );

  Future<ApiResult<void>> create({
    required Map<String, Object?> body,
    ApiRequestOptions? options,
  }) =>
      _connection.execute(
        PostRequest<void>(
          endpoint: '/things',
          body: body,
          options: (options ?? const ApiRequestOptions()).copyWith(
            operationId: 'things.create',
          ),
        ),
      );

  Future<ApiResult<void>> upload({
    required List<UploadFile> files,
    ApiUploadRequestOptions? options,
  }) =>
      _connection.execute(
        UploadRequest<void>(
          endpoint: '/things/upload',
          files: files,
          options: (options ?? const ApiUploadRequestOptions()).copyWith(
            operationId: 'things.upload',
          ),
        ),
      );
}
