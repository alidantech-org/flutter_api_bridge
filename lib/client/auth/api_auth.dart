import 'dart:async';

import '../logging/api_logger.dart';
import 'auth_strategy.dart';

/// Transport authentication state owned by the bridge.
enum AuthSessionStatus {
  initializing,
  anonymous,
  authenticated,
  refreshing,
  expired,
}

/// Immutable transport session snapshot.
class AuthSession {
  const AuthSession({
    required this.status,
    required this.changedAt,
    this.reason,
  });

  factory AuthSession.initializing() => AuthSession(
        status: AuthSessionStatus.initializing,
        changedAt: DateTime.now().toUtc(),
      );

  final AuthSessionStatus status;
  final DateTime changedAt;
  final String? reason;

  bool get isAuthenticated =>
      status == AuthSessionStatus.authenticated ||
      status == AuthSessionStatus.refreshing;
}

/// Owns credential/session transitions for one configured API connection.
///
/// Login endpoints remain application-specific. After a generated login call
/// succeeds, the consumer explicitly calls [completeAuthentication].
class ApiAuth {
  ApiAuth({
    required AuthStrategy strategy,
    ApiLogger logger = const DeveloperApiLogger(),
    ApiLoggingConfig logging = const ApiLoggingConfig(),
  })  : _strategy = strategy,
        _logger = logger,
        _logging = logging;

  final AuthStrategy _strategy;
  final ApiLogger _logger;
  final ApiLoggingConfig _logging;
  final StreamController<AuthSession> _changes =
      StreamController<AuthSession>.broadcast(sync: true);

  AuthSession _current = AuthSession.initializing();
  bool _disposed = false;

  AuthSession get current => _current;
  Stream<AuthSession> get changes => _changes.stream;

  /// Restores transport auth from persisted credentials.
  Future<AuthSession> initialize() async {
    final authenticated = await _strategy.hasCredentials();
    _set(
      AuthSession(
        status: authenticated
            ? AuthSessionStatus.authenticated
            : AuthSessionStatus.anonymous,
        changedAt: DateTime.now().toUtc(),
        reason: authenticated ? 'credentials_restored' : 'no_credentials',
      ),
    );
    return _current;
  }

  /// Completes bridge authentication after an application login succeeds.
  ///
  /// For bearer auth, pass [credential]. Cookie auth persists through Dio's
  /// cookie jar and therefore does not require a credential value here.
  Future<void> completeAuthentication({String? credential}) async {
    await _strategy.saveCredentials(credential);
    _set(
      AuthSession(
        status: AuthSessionStatus.authenticated,
        changedAt: DateTime.now().toUtc(),
        reason: 'login_completed',
      ),
    );
  }

  void beginRefresh() {
    if (!_current.isAuthenticated) return;
    _set(
      AuthSession(
        status: AuthSessionStatus.refreshing,
        changedAt: DateTime.now().toUtc(),
        reason: 'refresh_started',
      ),
    );
  }

  Future<void> completeRefresh({String? credential}) async {
    await _strategy.saveCredentials(credential);
    _set(
      AuthSession(
        status: AuthSessionStatus.authenticated,
        changedAt: DateTime.now().toUtc(),
        reason: 'refresh_completed',
      ),
    );
  }

  /// Expires the session once. Repeated 401 responses do not emit loops.
  Future<void> expire({String reason = 'unauthorized'}) async {
    if (_current.status == AuthSessionStatus.expired ||
        _current.status == AuthSessionStatus.anonymous) {
      return;
    }
    await _strategy.onUnauthorized();
    _set(
      AuthSession(
        status: AuthSessionStatus.expired,
        changedAt: DateTime.now().toUtc(),
        reason: reason,
      ),
    );
  }

  Future<void> clear({String reason = 'logout'}) async {
    await _strategy.clearCredentials();
    _set(
      AuthSession(
        status: AuthSessionStatus.anonymous,
        changedAt: DateTime.now().toUtc(),
        reason: reason,
      ),
    );
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _changes.close();
  }

  void _set(AuthSession next) {
    if (_disposed) return;
    if (_current.status == next.status && _current.reason == next.reason) return;
    _current = next;
    _changes.add(next);
    if (_logging.enabled) {
      _logger.log(
        ApiLogEvent(
          level: next.status == AuthSessionStatus.expired
              ? ApiLogLevel.warning
              : ApiLogLevel.info,
          type: ApiLogEventType.auth,
          message: 'Authentication state changed',
          timestamp: next.changedAt,
          data: <String, Object?>{
            'status': next.status.name,
            if (next.reason != null) 'reason': next.reason,
          },
        ),
      );
    }
  }
}
