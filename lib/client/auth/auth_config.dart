import 'package:dio/dio.dart';

import 'auth_session.dart';

/// Credential transport used by one API connection.
enum AuthTransport {
  /// Authentication is not managed by the bridge.
  none,

  /// HttpOnly or application cookies are persisted in a connection-scoped jar.
  cookies,

  /// Access and refresh tokens are persisted in a connection-scoped store.
  bearer,
}

/// Result returned by a custom refresh callback.
class AuthRefreshResult {
  const AuthRefreshResult.success({
    this.accessToken,
    this.refreshToken,
    this.expiresAt,
  })  : success = true,
        reason = null;

  const AuthRefreshResult.failure({this.reason})
      : success = false,
        accessToken = null,
        refreshToken = null,
        expiresAt = null;

  final bool success;
  final String? accessToken;
  final String? refreshToken;
  final DateTime? expiresAt;
  final String? reason;
}

/// Context passed only to the trusted connection-level refresh adapter.
///
/// The refresh credential is deliberately available here rather than through
/// [AuthSession], widgets, providers, or generated response models. The supplied
/// Dio instance shares the connection's cookie jar and safe logging, but has no
/// unauthorized retry interceptor, so refresh cannot recurse forever.
class AuthRefreshContext {
  const AuthRefreshContext({
    required Dio client,
    required this.session,
    this.refreshToken,
  }) : _client = client;

  final Dio _client;
  final AuthSession session;
  final String? refreshToken;

  Future<Response<dynamic>> request({
    required String path,
    String method = 'POST',
    Object? data,
    Map<String, dynamic>? queryParameters,
    Map<String, dynamic>? headers,
  }) {
    return _client.request<dynamic>(
      path,
      data: data,
      queryParameters: queryParameters,
      options: Options(
        method: method,
        headers: headers,
        extra: const <String, Object?>{
          'bridge.skipAuthRefresh': true,
          'bridge.noAuth': true,
        },
      ),
    );
  }
}

typedef AuthRefreshCallback = Future<AuthRefreshResult> Function(
    AuthRefreshContext context);

/// Authentication behavior for one connection.
///
/// The default is cookie authentication using the common `access_token` and
/// `refresh_token` cookie names. A successful login response is never inspected
/// or treated as authentication. Cookie auth becomes active only after the
/// configured access cookie is actually persisted. Bearer auth becomes active
/// only after [ApiAuth.establish] is called with validated credentials.
class AuthConfig {
  const AuthConfig({
    this.transport = AuthTransport.cookies,
    this.accessCookieName = 'access_token',
    this.refreshCookieName = 'refresh_token',
    this.additionalAuthCookieNames = const <String>{'temp_token'},
    this.accessTokenStorageKey = 'access_token',
    this.refreshTokenStorageKey = 'refresh_token',
    this.authorizationHeader = 'Authorization',
    this.authorizationScheme = 'Bearer',
    this.refreshPath,
    this.refreshMethod = 'POST',
    this.refresh,
    this.refreshOnInitialize = false,
    this.refreshOnUnauthorized = true,
    this.clearOnRefreshFailure = true,
    this.expirySkew = const Duration(seconds: 30),
    this.unauthorizedStatusCodes = const <int>{401},
  });

  final AuthTransport transport;

  /// Cookie names used only when [transport] is [AuthTransport.cookies].
  final String accessCookieName;
  final String refreshCookieName;
  final Set<String> additionalAuthCookieNames;

  /// Persistence keys used only when [transport] is [AuthTransport.bearer].
  final String accessTokenStorageKey;
  final String refreshTokenStorageKey;
  final String authorizationHeader;
  final String authorizationScheme;

  /// Optional simple refresh endpoint. Cookie-based APIs usually only need this
  /// path because the refresh cookie is attached automatically.
  final String? refreshPath;
  final String refreshMethod;

  /// Optional custom refresh callback. Bearer APIs can call the refresh endpoint
  /// and return validated replacement credentials without exposing that logic to
  /// widgets or generated login DTOs.
  final AuthRefreshCallback? refresh;

  final bool refreshOnInitialize;
  final bool refreshOnUnauthorized;
  final bool clearOnRefreshFailure;
  final Duration expirySkew;
  final Set<int> unauthorizedStatusCodes;

  bool get isEnabled => transport != AuthTransport.none;

  bool get canRefreshAutomatically {
    return refresh != null ||
        (refreshPath != null && refreshPath!.trim().isNotEmpty);
  }
}
