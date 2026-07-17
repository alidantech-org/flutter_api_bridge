import 'dart:async';

import 'package:dio/dio.dart';

import '../cookies/connection_cookie_store.dart';
import '../logging/api_logging.dart';
import 'auth_config.dart';
import 'auth_session.dart';
import 'auth_storage.dart';

/// Owns authentication for one named API connection.
///
/// This class never parses application login DTOs. Cookie authentication is
/// derived from the connection's persisted cookie jar. Bearer authentication is
/// activated only by an explicit [establish] call after the application has
/// validated its login or refresh response.
class ApiAuth {
  ApiAuth({
    required this.connectionKey,
    required this.config,
    required ApiLogger logger,
    required Dio refreshClient,
    ConnectionCookieStore? cookies,
    AuthCredentialStore? credentialStore,
  }) : _logger = logger,
       _refreshClient = refreshClient,
       _cookies = cookies,
       _credentialStore = credentialStore;

  final String connectionKey;
  final AuthConfig config;
  final ApiLogger _logger;
  final Dio _refreshClient;
  final ConnectionCookieStore? _cookies;
  final AuthCredentialStore? _credentialStore;

  final StreamController<AuthSession> _changesController =
      StreamController<AuthSession>.broadcast(sync: true);
  final StreamController<AuthFailureEvent> _failuresController =
      StreamController<AuthFailureEvent>.broadcast(sync: true);

  AuthSession _current = const AuthSession.unknown();
  StoredAuthCredentials _credentials = const StoredAuthCredentials();
  Future<bool>? _refreshFuture;
  bool _initialized = false;
  bool _disposed = false;

  AuthSession get current => _current;

  Stream<AuthSession> get changes => _changesController.stream;

  Stream<AuthFailureEvent> get failures => _failuresController.stream;

  bool get isInitialized => _initialized;

  Future<void> initialize() async {
    _ensureNotDisposed();
    if (_initialized) return;

    _setSession(
      const AuthSession(
        status: AuthSessionStatus.restoring,
        hasAccessCredential: false,
        hasRefreshCredential: false,
        revision: 0,
      ),
      logMessage: 'Restoring persisted authentication',
    );

    final store = _credentialStore;
    if (store != null) await store.initialize();

    await synchronize(reason: 'initial_restore');
    _initialized = true;

    if (config.refreshOnInitialize &&
        current.canRefresh &&
        !current.isAuthenticated &&
        config.canRefreshAutomatically) {
      await refresh(reason: 'initial_restore');
    }
  }

  /// Re-reads the configured credential storage and updates [current].
  ///
  /// For cookie auth this is the operation that observes cookies persisted by
  /// Dio after login or refresh. HTTP status or response DTO shape is irrelevant.
  Future<AuthSession> synchronize({String? reason}) async {
    _ensureNotDisposed();

    final now = DateTime.now().toUtc();
    switch (config.transport) {
      case AuthTransport.none:
        _setSession(
          AuthSession(
            status: AuthSessionStatus.unauthenticated,
            hasAccessCredential: false,
            hasRefreshCredential: false,
            revision: _current.revision,
            reason: reason,
          ),
          logMessage: 'Authentication is disabled for this connection',
        );

      case AuthTransport.cookies:
        final cookies = _cookies;
        if (cookies == null) {
          throw StateError('Cookie auth requires a connection cookie store.');
        }

        final values =
            await Future.wait<AuthCookieSnapshot>(<Future<AuthCookieSnapshot>>[
              cookies.snapshot(config.accessCookieName),
              cookies.snapshot(config.refreshCookieName),
            ]);
        final access = values[0];
        final refresh = values[1];
        final hasAccess = access.isUsable(now, config.expirySkew);
        final hasRefresh = refresh.isUsable(now, Duration.zero);

        _setSession(
          AuthSession(
            status: hasAccess
                ? AuthSessionStatus.authenticated
                : hasRefresh
                ? AuthSessionStatus.expired
                : AuthSessionStatus.unauthenticated,
            hasAccessCredential: hasAccess,
            hasRefreshCredential: hasRefresh,
            revision: _current.revision,
            expiresAt: access.expiresAt,
            reason: reason,
          ),
          logMessage: 'Cookie authentication synchronized',
        );

      case AuthTransport.bearer:
        final store = _credentialStore;
        if (store == null) {
          throw StateError('Bearer auth requires a credential store.');
        }

        _credentials = await store.read();
        final hasAccess = _credentials.hasUsableAccessToken(
          now,
          config.expirySkew,
        );
        final hasRefresh = _credentials.hasRefreshToken;

        _setSession(
          AuthSession(
            status: hasAccess
                ? AuthSessionStatus.authenticated
                : hasRefresh
                ? AuthSessionStatus.expired
                : AuthSessionStatus.unauthenticated,
            hasAccessCredential: hasAccess,
            hasRefreshCredential: hasRefresh,
            revision: _current.revision,
            expiresAt: _credentials.expiresAt,
            reason: reason,
          ),
          logMessage: 'Bearer authentication synchronized',
        );
    }

    return _current;
  }

  /// Explicitly commits validated bearer credentials.
  ///
  /// A successful login endpoint does not call this automatically. The
  /// application or generated SDK adapter calls it only after the response has
  /// been validated and the token fields have been extracted.
  Future<void> establish({
    required String accessToken,
    String? refreshToken,
    DateTime? expiresAt,
  }) async {
    _ensureNotDisposed();
    if (config.transport != AuthTransport.bearer) {
      throw StateError(
        'ApiAuth.establish is only valid for bearer authentication. '
        'Cookie authentication is restored with synchronize().',
      );
    }

    final cleanAccess = accessToken.trim();
    if (cleanAccess.isEmpty) {
      throw ArgumentError.value(
        accessToken,
        'accessToken',
        'must not be empty',
      );
    }

    final credentials = StoredAuthCredentials(
      accessToken: cleanAccess,
      refreshToken: refreshToken?.trim().isEmpty == true
          ? null
          : refreshToken?.trim(),
      expiresAt: expiresAt?.toUtc(),
    );

    await _credentialStore!.write(credentials);
    _credentials = credentials;
    await synchronize(reason: 'credentials_established');
  }

  /// Applies a usable bearer credential or records whether cookie auth is active.
  /// Returns true only when an access credential was actually available.
  Future<bool> apply(RequestOptions options) async {
    _ensureNotDisposed();
    if (!_initialized) await initialize();

    if (!config.isEnabled) {
      options.extra['bridge.authApplied'] = false;
      return false;
    }

    if (config.transport == AuthTransport.cookies) {
      final applied = current.hasAccessCredential && current.isAuthenticated;
      options.extra['bridge.authApplied'] = applied;
      return applied;
    }

    if (config.transport == AuthTransport.bearer) {
      final now = DateTime.now().toUtc();
      if (!_credentials.hasUsableAccessToken(now, config.expirySkew)) {
        await synchronize(reason: 'access_token_unavailable');
        options.extra['bridge.authApplied'] = false;
        return false;
      }

      final token = _credentials.accessToken!;
      final scheme = config.authorizationScheme.trim();
      options.headers[config.authorizationHeader] = scheme.isEmpty
          ? token
          : '$scheme $token';
      options.extra['bridge.authApplied'] = true;
      return true;
    }

    options.extra['bridge.authApplied'] = false;
    return false;
  }

  /// Runs at most one refresh operation for all concurrent unauthorized requests.
  Future<bool> refresh({String reason = 'unauthorized'}) {
    _ensureNotDisposed();
    final active = _refreshFuture;
    if (active != null) return active;

    final operation = _performRefresh(reason);
    _refreshFuture = operation;
    operation.whenComplete(() {
      if (identical(_refreshFuture, operation)) {
        _refreshFuture = null;
      }
    });
    return operation;
  }

  Future<bool> _performRefresh(String reason) async {
    if (!config.isEnabled ||
        !config.refreshOnUnauthorized ||
        !config.canRefreshAutomatically ||
        !current.hasRefreshCredential) {
      await markExpired(reason: 'refresh_unavailable');
      return false;
    }

    _setSession(
      current.copyWith(status: AuthSessionStatus.refreshing, reason: reason),
      logMessage: 'Refreshing authentication',
    );

    try {
      final callback = config.refresh;
      if (callback != null) {
        final result = await callback(
          AuthRefreshContext(
            client: _refreshClient,
            session: current,
            refreshToken: _credentials.refreshToken,
          ),
        );
        if (!result.success) {
          return _handleRefreshFailure(result.reason ?? 'refresh_failed');
        }

        if (config.transport == AuthTransport.bearer) {
          final access = result.accessToken?.trim();
          if (access == null || access.isEmpty) {
            return _handleRefreshFailure('refresh_returned_no_access_token');
          }

          final replacementRefresh = result.refreshToken?.trim();
          final credentials = StoredAuthCredentials(
            accessToken: access,
            refreshToken: replacementRefresh?.isNotEmpty == true
                ? replacementRefresh
                : _credentials.refreshToken,
            expiresAt: result.expiresAt?.toUtc(),
          );
          await _credentialStore!.write(credentials);
          _credentials = credentials;
        }
      } else {
        final path = config.refreshPath!.trim();
        final response = await _refreshClient.request<dynamic>(
          path,
          options: Options(
            method: config.refreshMethod,
            extra: const <String, Object?>{
              'bridge.skipAuthRefresh': true,
              'bridge.noAuth': true,
            },
          ),
        );

        final status = response.statusCode ?? 0;
        if (status < 200 || status >= 300) {
          return _handleRefreshFailure('refresh_http_$status');
        }

        if (config.transport == AuthTransport.bearer) {
          return _handleRefreshFailure(
            'bearer_refresh_requires_a_refresh_callback',
          );
        }
      }

      await synchronize(reason: 'refresh_succeeded');
      final success = current.isAuthenticated;
      if (!success) {
        return _handleRefreshFailure('refresh_did_not_restore_access');
      }

      _logger.log(
        ApiLogLevel.info,
        ApiLogCategory.refresh,
        'Authentication refresh completed',
      );
      return true;
    } catch (error, stackTrace) {
      _logger.log(
        ApiLogLevel.warning,
        ApiLogCategory.refresh,
        'Authentication refresh failed',
        error: error,
        stackTrace: stackTrace,
      );
      return _handleRefreshFailure('refresh_exception');
    }
  }

  Future<bool> _handleRefreshFailure(String reason) async {
    if (config.clearOnRefreshFailure) {
      await clear(reason: reason);
    } else {
      await markExpired(reason: reason);
    }
    return false;
  }

  Future<void> markExpired({required String reason}) async {
    _ensureNotDisposed();
    _setSession(
      current.copyWith(
        status: current.hasRefreshCredential
            ? AuthSessionStatus.expired
            : AuthSessionStatus.unauthenticated,
        hasAccessCredential: false,
        reason: reason,
        clearExpiresAt: true,
      ),
      logMessage: 'Authentication access expired',
      level: ApiLogLevel.warning,
    );
  }

  void recordFailure(AuthFailureEvent event) {
    if (_disposed) return;
    _failuresController.add(event);
    _logger.log(
      event.statusCode == 403 ? ApiLogLevel.warning : ApiLogLevel.info,
      ApiLogCategory.authentication,
      event.statusCode == 403
          ? 'Authenticated request was forbidden'
          : 'Request was unauthorized',
      requestId: event.requestId,
      statusCode: event.statusCode,
      metadata: <String, Object?>{
        'path': event.path,
        'authWasApplied': event.authWasApplied,
        if (event.reason != null) 'reason': event.reason,
      },
    );
  }

  /// Clears only credentials owned by this connection.
  Future<void> clear({String reason = 'cleared'}) async {
    _ensureNotDisposed();

    switch (config.transport) {
      case AuthTransport.none:
        break;
      case AuthTransport.cookies:
        await _cookies!.clearNames(<String>{
          config.accessCookieName,
          config.refreshCookieName,
          ...config.additionalAuthCookieNames,
        });
      case AuthTransport.bearer:
        await _credentialStore!.clear();
        _credentials = const StoredAuthCredentials();
    }

    _setSession(
      AuthSession(
        status: AuthSessionStatus.unauthenticated,
        hasAccessCredential: false,
        hasRefreshCredential: false,
        revision: current.revision,
        reason: reason,
      ),
      logMessage: 'Authentication cleared',
    );
  }

  Future<void> prepareRetry(RequestOptions options) async {
    options.headers.remove(config.authorizationHeader);
    if (config.transport == AuthTransport.cookies) {
      await _cookies!.attachTo(options);
    }
    await apply(options);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _changesController.close();
    await _failuresController.close();
  }

  void _setSession(
    AuthSession next, {
    required String logMessage,
    ApiLogLevel level = ApiLogLevel.debug,
  }) {
    if (_hasSameCredentialState(_current, next)) return;

    final revised = next.copyWith(revision: _current.revision + 1);
    _current = revised;
    if (!_disposed) _changesController.add(revised);

    _logger.log(
      level,
      ApiLogCategory.authentication,
      logMessage,
      metadata: <String, Object?>{
        'status': revised.status.name,
        'hasAccessCredential': revised.hasAccessCredential,
        'hasRefreshCredential': revised.hasRefreshCredential,
        'expiresAt': revised.expiresAt,
        'reason': revised.reason,
        'revision': revised.revision,
      },
    );
  }

  bool _hasSameCredentialState(AuthSession current, AuthSession next) {
    return current.status == next.status &&
        current.hasAccessCredential == next.hasAccessCredential &&
        current.hasRefreshCredential == next.hasRefreshCredential &&
        current.expiresAt == next.expiresAt;
  }

  void _ensureNotDisposed() {
    if (_disposed) {
      throw StateError('ApiAuth for $connectionKey has been disposed.');
    }
  }
}
