import 'package:hive_flutter/hive_flutter.dart';

import 'auth_config.dart';

/// Internal persisted bearer credentials.
///
/// This type is intentionally not exposed through [AuthSession].
class StoredAuthCredentials {
  const StoredAuthCredentials({
    this.accessToken,
    this.refreshToken,
    this.expiresAt,
  });

  final String? accessToken;
  final String? refreshToken;
  final DateTime? expiresAt;

  bool get hasAccessToken => accessToken?.trim().isNotEmpty == true;
  bool get hasRefreshToken => refreshToken?.trim().isNotEmpty == true;

  bool hasUsableAccessToken(DateTime now, Duration skew) {
    if (!hasAccessToken) return false;
    final expiry = expiresAt;
    if (expiry == null) return true;
    return expiry.isAfter(now.add(skew));
  }

  StoredAuthCredentials merge({
    String? accessToken,
    String? refreshToken,
    DateTime? expiresAt,
  }) {
    return StoredAuthCredentials(
      accessToken: accessToken ?? this.accessToken,
      refreshToken: refreshToken ?? this.refreshToken,
      expiresAt: expiresAt ?? this.expiresAt,
    );
  }
}

abstract interface class AuthCredentialStore {
  Future<void> initialize();

  Future<StoredAuthCredentials> read();

  Future<void> write(StoredAuthCredentials credentials);

  Future<void> clear();
}

/// Hive-backed bearer credential store isolated by connection key.
class HiveAuthCredentialStore implements AuthCredentialStore {
  HiveAuthCredentialStore({required this.connectionKey, required this.config});

  static const String _boxName = 'flutter_api_bridge_auth';

  final String connectionKey;
  final AuthConfig config;

  Box<dynamic>? _box;

  String get _prefix => '$connectionKey.';

  String get _accessKey => '$_prefix${config.accessTokenStorageKey}';

  String get _refreshKey => '$_prefix${config.refreshTokenStorageKey}';

  String get _expiryKey => '${_prefix}access_token_expires_at';

  @override
  Future<void> initialize() async {
    _box ??= await Hive.openBox<dynamic>(_boxName);
  }

  @override
  Future<StoredAuthCredentials> read() async {
    await initialize();
    final box = _box!;
    final access = box.get(_accessKey);
    final refresh = box.get(_refreshKey);
    final expiryRaw = box.get(_expiryKey);

    DateTime? expiry;
    if (expiryRaw is int) {
      expiry = DateTime.fromMillisecondsSinceEpoch(expiryRaw, isUtc: true);
    } else if (expiryRaw is String) {
      expiry = DateTime.tryParse(expiryRaw)?.toUtc();
    }

    return StoredAuthCredentials(
      accessToken: access is String && access.trim().isNotEmpty ? access : null,
      refreshToken: refresh is String && refresh.trim().isNotEmpty
          ? refresh
          : null,
      expiresAt: expiry,
    );
  }

  @override
  Future<void> write(StoredAuthCredentials credentials) async {
    await initialize();
    final box = _box!;

    await _putOrDelete(box, _accessKey, credentials.accessToken);
    await _putOrDelete(box, _refreshKey, credentials.refreshToken);

    final expiry = credentials.expiresAt;
    if (expiry == null) {
      await box.delete(_expiryKey);
    } else {
      await box.put(_expiryKey, expiry.toUtc().millisecondsSinceEpoch);
    }
  }

  @override
  Future<void> clear() async {
    await initialize();
    final box = _box!;
    await box.deleteAll(<String>[_accessKey, _refreshKey, _expiryKey]);
  }

  Future<void> _putOrDelete(Box<dynamic> box, String key, String? value) async {
    final clean = value?.trim();
    if (clean == null || clean.isEmpty) {
      await box.delete(key);
    } else {
      await box.put(key, clean);
    }
  }
}

/// Lightweight in-memory store useful for tests and ephemeral connections.
class MemoryAuthCredentialStore implements AuthCredentialStore {
  MemoryAuthCredentialStore([this.credentials = const StoredAuthCredentials()]);

  StoredAuthCredentials credentials;

  @override
  Future<void> initialize() async {}

  @override
  Future<StoredAuthCredentials> read() async => credentials;

  @override
  Future<void> write(StoredAuthCredentials credentials) async {
    this.credentials = credentials;
  }

  @override
  Future<void> clear() async {
    credentials = const StoredAuthCredentials();
  }
}
