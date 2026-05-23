// lib/server/auth/auth_strategy.dart
import 'package:dio/dio.dart';
import 'package:hive_flutter/hive_flutter.dart';

// ─── Abstract strategy ─────────────────────────────────────────────────────────

/// Base auth strategy. Implement to add custom auth behaviour.
/// The [ApiClient] calls [apply] before every non-noAuth request.
abstract class AuthStrategy {
  const AuthStrategy();

  /// Attach auth credentials to [options] before the request is sent.
  Future<void> apply(RequestOptions options);

  /// Called when the API layer receives a 401.
  /// Use to trigger token refresh or logout in your app provider.
  Future<void> onUnauthorized() async {}
}

// ─── Bearer token strategy ─────────────────────────────────────────────────────

/// Reads the JWT access token from memory (fast) with a Hive fallback
/// (persistent). Attaches it as `Authorization: Bearer <token>`.
///
/// The app creator saves the token after login:
/// ```dart
/// await BearerStrategy.saveToken(token);
/// ```
class BearerStrategy extends AuthStrategy {
  BearerStrategy({required this.tokenKey});

  /// Hive box key used to persist the token.
  /// Must match the key used when saving after login.
  /// e.g. `'access_token'`
  final String tokenKey;

  // L1 — in-memory cache so Hive is not hit on every request
  static String? _memoryToken;

  /// Persist and cache the token. Call this after a successful login.
  static Future<void> saveToken(String token, {required String key}) async {
    _memoryToken = token;
    final box = await Hive.openBox<String>('server_auth');
    await box.put(key, token);
  }

  /// Clear the token from memory and Hive. Call this on logout.
  static Future<void> clearToken({required String key}) async {
    _memoryToken = null;
    final box = await Hive.openBox<String>('server_auth');
    await box.delete(key);
  }

  /// Read the current token — memory first, then Hive.
  Future<String?> _getToken() async {
    if (_memoryToken != null) return _memoryToken;
    final box = await Hive.openBox<String>('server_auth');
    final stored = box.get(tokenKey);
    if (stored != null) _memoryToken = stored; // warm the memory cache
    return stored;
  }

  @override
  Future<void> apply(RequestOptions options) async {
    final token = await _getToken();
    if (token != null) {
      options.headers['Authorization'] = 'Bearer $token';
    }
  }
}

// ─── Cookie strategy ───────────────────────────────────────────────────────────

/// Relies on Dio's CookieJar to attach cookies automatically.
/// No manual header injection needed — the CookieJar intercepts every request.
///
/// Use this when your backend sets HttpOnly cookies on login.
class CookieStrategy extends AuthStrategy {
  const CookieStrategy();

  @override
  Future<void> apply(RequestOptions options) async {
    // CookieJar handles everything — nothing to do here.
  }
}

// ─── API key strategy (future) ────────────────────────────────────────────────

/// Attaches a static API key to every request as an `x-api-key` header.
/// The key is a compile-time constant — never stored dynamically.
///
/// Individual requests opt out via `noAuth: true`.
///
/// @Deprecated — not yet implemented on the backend.
/// Uncomment and configure once backend API key support is ready.
class ApiKeyStrategy extends AuthStrategy {
  const ApiKeyStrategy({required this.apiKey});

  /// The API key constant. Pass from your app-level config.
  final String apiKey;

  @override
  Future<void> apply(RequestOptions options) async {
    options.headers['x-api-key'] = apiKey;
  }
}
