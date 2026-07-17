import 'package:dio/dio.dart';
import 'package:hive_flutter/hive_flutter.dart';

/// Base transport-auth strategy.
///
/// Application-specific login and refresh endpoints do not belong here. A
/// generated client performs those calls, then [ApiAuth] asks the strategy to
/// persist or clear the resulting transport credential.
abstract class AuthStrategy {
  const AuthStrategy();

  /// Attach credentials before a protected request is sent.
  Future<void> apply(RequestOptions options);

  /// Whether persisted transport credentials are currently available.
  Future<bool> hasCredentials() async => false;

  /// Persist a credential after application authentication succeeds.
  /// Cookie strategies may ignore [credential] because Dio persists cookies.
  Future<void> saveCredentials(String? credential) async {}

  /// Remove locally persisted transport credentials.
  Future<void> clearCredentials() async {}

  /// Called once when the bridge transitions to an expired session.
  Future<void> onUnauthorized() async {}
}

/// Persistent bearer-token authentication.
class BearerStrategy extends AuthStrategy {
  BearerStrategy({required this.tokenKey});

  final String tokenKey;

  static final Map<String, String> _memoryTokens = <String, String>{};

  static Future<void> saveToken(String token, {required String key}) async {
    final clean = token.trim();
    if (clean.isEmpty) {
      throw ArgumentError.value(token, 'token', 'Bearer token cannot be empty.');
    }
    _memoryTokens[key] = clean;
    final box = await Hive.openBox<String>('server_auth');
    await box.put(key, clean);
  }

  static Future<void> clearToken({required String key}) async {
    _memoryTokens.remove(key);
    final box = await Hive.openBox<String>('server_auth');
    await box.delete(key);
  }

  Future<String?> getToken() async {
    final memory = _memoryTokens[tokenKey];
    if (memory != null && memory.isNotEmpty) return memory;

    final box = await Hive.openBox<String>('server_auth');
    final stored = box.get(tokenKey)?.trim();
    if (stored != null && stored.isNotEmpty) {
      _memoryTokens[tokenKey] = stored;
      return stored;
    }
    return null;
  }

  @override
  Future<void> apply(RequestOptions options) async {
    final token = await getToken();
    if (token != null) {
      options.headers['Authorization'] = 'Bearer $token';
    }
  }

  @override
  Future<bool> hasCredentials() async => (await getToken()) != null;

  @override
  Future<void> saveCredentials(String? credential) async {
    final value = credential?.trim();
    if (value == null || value.isEmpty) {
      throw ArgumentError('Bearer authentication requires a credential.');
    }
    await saveToken(value, key: tokenKey);
  }

  @override
  Future<void> clearCredentials() => clearToken(key: tokenKey);
}

/// Cookie authentication managed by Dio's persistent cookie jar.
class CookieStrategy extends AuthStrategy {
  const CookieStrategy({this.sessionCookieNames = const <String>[]});

  /// Cookie names that indicate a restorable authenticated session.
  /// Leave empty when the server uses an opaque cookie setup and call
  /// `auth.completeAuthentication()` explicitly after login.
  final List<String> sessionCookieNames;

  @override
  Future<void> apply(RequestOptions options) async {
    // CookieManager's interceptor attaches cookies.
  }

  @override
  Future<bool> hasCredentials() async {
    if (sessionCookieNames.isEmpty) return false;
    final box = await Hive.openBox<String>('server_auth_cookie_state');
    return sessionCookieNames.any((name) => box.get(name) == 'present');
  }

  @override
  Future<void> saveCredentials(String? credential) async {
    if (sessionCookieNames.isEmpty) return;
    final box = await Hive.openBox<String>('server_auth_cookie_state');
    for (final name in sessionCookieNames) {
      await box.put(name, 'present');
    }
  }

  @override
  Future<void> clearCredentials() async {
    if (sessionCookieNames.isEmpty) return;
    final box = await Hive.openBox<String>('server_auth_cookie_state');
    for (final name in sessionCookieNames) {
      await box.delete(name);
    }
  }
}

/// Static API-key authentication.
class ApiKeyStrategy extends AuthStrategy {
  const ApiKeyStrategy({required this.apiKey});

  final String apiKey;

  @override
  Future<void> apply(RequestOptions options) async {
    options.headers['x-api-key'] = apiKey;
  }

  @override
  Future<bool> hasCredentials() async => apiKey.trim().isNotEmpty;
}
