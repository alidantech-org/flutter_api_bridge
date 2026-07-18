import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../logging/api_logger.dart';
import 'auth_strategy.dart';

enum AuthSessionStatus {
  initializing,
  anonymous,
  authenticated,
  expired,
}

class AuthSession {
  const AuthSession({
    required this.status,
    required this.changedAt,
    this.sessionId,
    this.reason,
  });

  factory AuthSession.initializing() => AuthSession(
        status: AuthSessionStatus.initializing,
        changedAt: DateTime.now().toUtc(),
      );

  final AuthSessionStatus status;
  final DateTime changedAt;
  final String? sessionId;
  final String? reason;

  bool get isAuthenticated => status == AuthSessionStatus.authenticated;
}

/// Connection-scoped transport authentication and manual override state.
class ApiAuth {
  ApiAuth({
    required AuthStrategy strategy,
    required AuthStrategyContext context,
    ApiLogger logger = const DeveloperApiLogger(),
    ApiLoggingConfig logging = const ApiLoggingConfig(),
  })  : _strategy = strategy,
        _context = context,
        _logger = logger,
        _logging = logging;

  final AuthStrategy _strategy;
  final AuthStrategyContext _context;
  final ApiLogger _logger;
  final ApiLoggingConfig _logging;
  final StreamController<AuthSession> _changes =
      StreamController<AuthSession>.broadcast(sync: true);

  AuthSession _current = AuthSession.initializing();
  Map<String, String> _sessionHeaders = const <String, String>{};
  Future<void>? _expireFuture;
  bool _disposed = false;

  AuthSession get current => _current;
  Stream<AuthSession> get changes => _changes.stream;
  Map<String, String> get sessionHeaders =>
      Map<String, String>.unmodifiable(_sessionHeaders);

  String get _sessionIdKey => _context.secureKey('session_id');
  String get _expiredReasonKey => _context.secureKey('expired_reason');
  String _headersKey(String sessionId) =>
      _context.secureKey('session_headers.$sessionId');

  Future<AuthSession> initialize() async {
    await _strategy.initialize(_context);
    final restoredSessionId =
        await _context.secureStorage.read(key: _sessionIdKey);
    if (restoredSessionId != null && restoredSessionId.trim().isNotEmpty) {
      await _restoreHeaders(restoredSessionId.trim());
    }

    final authenticated =
        await _strategy.hasCredentials(_context) || _sessionHeaders.isNotEmpty;
    final expiredReason =
        await _context.secureStorage.read(key: _expiredReasonKey);

    if (!authenticated) {
      await _context.secureStorage.delete(key: _expiredReasonKey);
    }

    final hasExpiredMarker = authenticated &&
        expiredReason != null &&
        expiredReason.trim().isNotEmpty;

    _set(
      AuthSession(
        status: hasExpiredMarker
            ? AuthSessionStatus.expired
            : authenticated
                ? AuthSessionStatus.authenticated
                : AuthSessionStatus.anonymous,
        changedAt: DateTime.now().toUtc(),
        sessionId: authenticated ? restoredSessionId?.trim() : null,
        reason: hasExpiredMarker
            ? expiredReason.trim()
            : authenticated
                ? 'credentials_restored'
                : 'no_credentials',
      ),
    );
    return _current;
  }

  /// Starts or updates a transport user session after application login.
  ///
  /// The generated package can call this at any nesting depth. Cookie login
  /// requires no credential; bearer login passes [bearerToken].
  Future<void> initializeUserSession({
    required String sessionId,
    String? bearerToken,
    Map<String, String>? authHeaders,
  }) async {
    await _waitForExpiry();
    final cleanSessionId = sessionId.trim();
    if (cleanSessionId.isEmpty) {
      throw ArgumentError.value(sessionId, 'sessionId', 'Cannot be empty.');
    }

    if (bearerToken != null) {
      await _strategy.saveCredentials(bearerToken, _context);
    }

    await _context.secureStorage.write(
      key: _sessionIdKey,
      value: cleanSessionId,
    );
    await _context.secureStorage.delete(key: _expiredReasonKey);

    if (authHeaders != null) {
      _sessionHeaders = _cleanHeaders(authHeaders);
      await _context.secureStorage.write(
        key: _headersKey(cleanSessionId),
        value: jsonEncode(_sessionHeaders),
      );
    } else {
      await _restoreHeaders(cleanSessionId);
    }

    _set(
      AuthSession(
        status: AuthSessionStatus.authenticated,
        changedAt: DateTime.now().toUtc(),
        sessionId: cleanSessionId,
        reason: 'user_session_initialized',
      ),
    );
  }

  /// Compatibility helper for callers that do not yet use session IDs.
  Future<void> completeAuthentication({String? credential}) async {
    await _waitForExpiry();
    if (credential != null) {
      await _strategy.saveCredentials(credential, _context);
    }
    await _context.secureStorage.delete(key: _expiredReasonKey);
    _set(
      AuthSession(
        status: AuthSessionStatus.authenticated,
        changedAt: DateTime.now().toUtc(),
        sessionId: _current.sessionId,
        reason: 'login_completed',
      ),
    );
  }

  Future<void> apply(RequestOptions options) async {
    final noAuth = options.extra['noAuth'] as bool? ?? false;
    if (noAuth) return;
    await _strategy.apply(options, _context);
    for (final entry in _sessionHeaders.entries) {
      options.headers.putIfAbsent(entry.key, () => entry.value);
    }
  }

  /// Expires the current session once, even when many requests return 401
  /// concurrently. Refresh orchestration remains generated/application owned.
  Future<void> expire({String reason = 'unauthorized'}) {
    if (_current.status == AuthSessionStatus.expired ||
        _current.status == AuthSessionStatus.anonymous) {
      return Future<void>.value();
    }
    final existing = _expireFuture;
    if (existing != null) return existing;

    final operation = _performExpire(reason);
    _expireFuture = operation;
    return operation.whenComplete(() {
      if (identical(_expireFuture, operation)) {
        _expireFuture = null;
      }
    });
  }

  Future<void> _performExpire(String reason) async {
    if (_current.status == AuthSessionStatus.expired ||
        _current.status == AuthSessionStatus.anonymous) {
      return;
    }
    await _strategy.onUnauthorized(_context);
    await _context.secureStorage.write(
      key: _expiredReasonKey,
      value: reason,
    );
    _set(
      AuthSession(
        status: AuthSessionStatus.expired,
        changedAt: DateTime.now().toUtc(),
        sessionId: _current.sessionId,
        reason: reason,
      ),
    );
  }

  Future<void> clear({String reason = 'logout'}) async {
    await _waitForExpiry();
    final sessionId = _current.sessionId;
    await _strategy.clearCredentials(_context);
    await _context.secureStorage.delete(key: _sessionIdKey);
    await _context.secureStorage.delete(key: _expiredReasonKey);
    if (sessionId != null) {
      await _context.secureStorage.delete(key: _headersKey(sessionId));
    }
    _sessionHeaders = const <String, String>{};
    _set(
      AuthSession(
        status: AuthSessionStatus.anonymous,
        changedAt: DateTime.now().toUtc(),
        reason: reason,
      ),
    );
  }

  Future<void> _waitForExpiry() async {
    final operation = _expireFuture;
    if (operation != null) await operation;
  }

  Future<void> _restoreHeaders(String sessionId) async {
    final encoded = await _context.secureStorage.read(
      key: _headersKey(sessionId),
    );
    if (encoded == null || encoded.trim().isEmpty) {
      _sessionHeaders = const <String, String>{};
      return;
    }
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is Map) {
        _sessionHeaders = _cleanHeaders(
          decoded.map(
            (key, value) => MapEntry(key.toString(), value.toString()),
          ),
        );
        return;
      }
    } catch (_) {
      // Corrupt optional header state is safely discarded.
    }
    _sessionHeaders = const <String, String>{};
  }

  Map<String, String> _cleanHeaders(Map<String, String> source) {
    final output = <String, String>{};
    for (final entry in source.entries) {
      final key = entry.key.trim();
      final value = entry.value.trim();
      if (key.isEmpty || value.isEmpty) continue;
      output[key] = value;
    }
    return output;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    await _waitForExpiry();
    _disposed = true;
    await _changes.close();
  }

  void _set(AuthSession next) {
    if (_disposed) return;
    if (_current.status == next.status &&
        _current.reason == next.reason &&
        _current.sessionId == next.sessionId) {
      return;
    }
    _current = next;
    _changes.add(next);
    final options = _logging.resolve();
    final importantFailure = next.status == AuthSessionStatus.expired;
    if (!options.enabled ||
        options.level == ApiLoggingLevel.errors && !importantFailure) {
      return;
    }
    try {
      _logger.log(
        ApiAuthLogEvent(
          level: importantFailure ? ApiLogLevel.warning : ApiLogLevel.info,
          timestamp: next.changedAt,
          options: options,
          data: options.redactor.redact(<String, Object?>{
            'status': next.status.name,
            if (next.reason != null) 'reason': next.reason,
          }) as Map<String, Object?>,
        ),
      );
    } catch (_) {
      // Diagnostics must never affect authentication state changes.
    }
  }
}
