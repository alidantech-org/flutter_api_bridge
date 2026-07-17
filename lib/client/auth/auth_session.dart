/// Authentication lifecycle owned by one API connection.
enum AuthSessionStatus {
  /// The connection has not restored its persisted credentials yet.
  unknown,

  /// Persisted credentials are currently being restored.
  restoring,

  /// No usable access credential is available.
  unauthenticated,

  /// A usable access credential is available.
  authenticated,

  /// One shared refresh operation is in progress.
  refreshing,

  /// The access credential is no longer usable. A refresh credential may still
  /// exist, but the connection is not authenticated until refresh succeeds.
  expired,
}

/// Public, token-free authentication state for one configured connection.
///
/// Access tokens, refresh tokens, cookies, and API keys are deliberately never
/// exposed through this object.
class AuthSession {
  const AuthSession({
    required this.status,
    required this.hasAccessCredential,
    required this.hasRefreshCredential,
    required this.revision,
    this.expiresAt,
    this.reason,
  });

  const AuthSession.unknown()
      : status = AuthSessionStatus.unknown,
        hasAccessCredential = false,
        hasRefreshCredential = false,
        revision = 0,
        expiresAt = null,
        reason = null;

  final AuthSessionStatus status;
  final bool hasAccessCredential;
  final bool hasRefreshCredential;
  final int revision;
  final DateTime? expiresAt;
  final String? reason;

  /// Refreshing preserves the authenticated application shell while the bridge
  /// serializes and completes one token refresh.
  bool get isAuthenticated {
    return status == AuthSessionStatus.authenticated ||
        status == AuthSessionStatus.refreshing;
  }

  bool get isRestoring => status == AuthSessionStatus.restoring;

  bool get isRefreshing => status == AuthSessionStatus.refreshing;

  bool get canRefresh => hasRefreshCredential;

  bool get isTerminallyUnauthenticated {
    return status == AuthSessionStatus.unauthenticated && !hasRefreshCredential;
  }

  AuthSession copyWith({
    AuthSessionStatus? status,
    bool? hasAccessCredential,
    bool? hasRefreshCredential,
    int? revision,
    DateTime? expiresAt,
    String? reason,
    bool clearExpiresAt = false,
    bool clearReason = false,
  }) {
    return AuthSession(
      status: status ?? this.status,
      hasAccessCredential: hasAccessCredential ?? this.hasAccessCredential,
      hasRefreshCredential: hasRefreshCredential ?? this.hasRefreshCredential,
      revision: revision ?? this.revision,
      expiresAt: clearExpiresAt ? null : expiresAt ?? this.expiresAt,
      reason: clearReason ? null : reason ?? this.reason,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is AuthSession &&
        other.status == status &&
        other.hasAccessCredential == hasAccessCredential &&
        other.hasRefreshCredential == hasRefreshCredential &&
        other.revision == revision &&
        other.expiresAt == expiresAt &&
        other.reason == reason;
  }

  @override
  int get hashCode => Object.hash(
        status,
        hasAccessCredential,
        hasRefreshCredential,
        revision,
        expiresAt,
        reason,
      );

  @override
  String toString() {
    return 'AuthSession('
        'status: $status, '
        'hasAccessCredential: $hasAccessCredential, '
        'hasRefreshCredential: $hasRefreshCredential, '
        'expiresAt: $expiresAt, '
        'revision: $revision, '
        'reason: $reason)';
  }
}

/// Authentication failure observed by one connection.
class AuthFailureEvent {
  const AuthFailureEvent({
    required this.statusCode,
    required this.path,
    required this.requestId,
    required this.authWasApplied,
    this.reason,
  });

  final int statusCode;
  final String path;
  final String requestId;
  final bool authWasApplied;
  final String? reason;
}
