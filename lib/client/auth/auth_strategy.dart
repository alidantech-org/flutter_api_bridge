import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../cookies/cookie_manager.dart';

/// Minimal secure key/value abstraction so applications can replace or test
/// credential persistence without changing generated clients.
abstract interface class ApiCredentialStorage {
  const ApiCredentialStorage();

  Future<String?> read({required String key});
  Future<void> write({required String key, required String? value});
  Future<void> delete({required String key});
}

class FlutterApiCredentialStorage implements ApiCredentialStorage {
  const FlutterApiCredentialStorage({
    this.storage = const FlutterSecureStorage(),
  });

  final FlutterSecureStorage storage;

  @override
  Future<String?> read({required String key}) => storage.read(key: key);

  @override
  Future<void> write({required String key, required String? value}) =>
      storage.write(key: key, value: value);

  @override
  Future<void> delete({required String key}) => storage.delete(key: key);
}

/// Connection-scoped facilities available to authentication strategies.
class AuthStrategyContext {
  const AuthStrategyContext({
    required this.connectionKey,
    required this.storageNamespace,
    required this.cookies,
    required this.secureStorage,
  });

  final String connectionKey;
  final String storageNamespace;
  final ApiCookieManager cookies;
  final ApiCredentialStorage secureStorage;

  String secureKey(String name) =>
      'flutter_api_bridge.$storageNamespace.auth.${name.trim()}';
}

/// Base transport-auth strategy.
///
/// Refresh endpoints remain generated-package/application concerns. Strategies
/// only restore, apply, persist, and clear transport credentials.
abstract class AuthStrategy {
  const AuthStrategy();

  Future<void> initialize(AuthStrategyContext context) async {}

  Future<void> apply(
    RequestOptions options,
    AuthStrategyContext context,
  );

  Future<bool> hasCredentials(AuthStrategyContext context) async => false;

  Future<void> saveCredentials(
    String? credential,
    AuthStrategyContext context,
  ) async {}

  Future<void> clearCredentials(AuthStrategyContext context) async {}

  Future<void> onUnauthorized(AuthStrategyContext context) async {}
}

/// No automatic authorization header. Per-session or per-request headers may
/// still be supplied by the caller.
class NoAuthStrategy extends AuthStrategy {
  const NoAuthStrategy();

  @override
  Future<void> apply(
    RequestOptions options,
    AuthStrategyContext context,
  ) async {}
}

/// Persistent bearer-token authentication backed by platform secure storage.
class BearerStrategy extends AuthStrategy {
  const BearerStrategy({
    this.tokenKey = 'access_token',
    this.headerName = 'Authorization',
    this.scheme = 'Bearer',
  });

  final String tokenKey;
  final String headerName;
  final String scheme;

  String _key(AuthStrategyContext context) => context.secureKey(tokenKey);

  Future<String?> getToken(AuthStrategyContext context) async {
    final value = await context.secureStorage.read(key: _key(context));
    final clean = value?.trim();
    return clean == null || clean.isEmpty ? null : clean;
  }

  @override
  Future<void> apply(
    RequestOptions options,
    AuthStrategyContext context,
  ) async {
    final token = await getToken(context);
    if (token == null) return;
    options.headers.putIfAbsent(
      headerName,
      () => scheme.trim().isEmpty ? token : '${scheme.trim()} $token',
    );
  }

  @override
  Future<bool> hasCredentials(AuthStrategyContext context) async =>
      (await getToken(context)) != null;

  @override
  Future<void> saveCredentials(
    String? credential,
    AuthStrategyContext context,
  ) async {
    final value = credential?.trim();
    if (value == null || value.isEmpty) {
      throw ArgumentError('Bearer authentication requires a token.');
    }
    await context.secureStorage.write(key: _key(context), value: value);
  }

  @override
  Future<void> clearCredentials(AuthStrategyContext context) =>
      context.secureStorage.delete(key: _key(context));
}

/// Browser-like persistent cookie authentication.
///
/// When [sessionCookieNames] is empty, any non-expired cookie applicable to the
/// configured API origin is enough to restore transport authentication. The
/// generated package should validate the session by calling its typed account
/// bootstrap endpoint; a 401 will expire the bridge session.
class CookieStrategy extends AuthStrategy {
  const CookieStrategy({
    this.sessionCookieNames = const <String>[],
  });

  final List<String> sessionCookieNames;

  @override
  Future<void> apply(
    RequestOptions options,
    AuthStrategyContext context,
  ) async {
    // Dio's cookie interceptor applies all eligible persisted cookies.
  }

  @override
  Future<bool> hasCredentials(AuthStrategyContext context) async {
    if (sessionCookieNames.isEmpty) {
      return context.cookies.hasAny();
    }
    return context.cookies.hasAnyNamed(sessionCookieNames);
  }

  @override
  Future<void> clearCredentials(AuthStrategyContext context) =>
      context.cookies.clearAll();
}

/// Static API-key authentication.
class ApiKeyStrategy extends AuthStrategy {
  const ApiKeyStrategy({
    required this.apiKey,
    this.headerName = 'x-api-key',
  });

  final String apiKey;
  final String headerName;

  @override
  Future<void> apply(
    RequestOptions options,
    AuthStrategyContext context,
  ) async {
    final value = apiKey.trim();
    if (value.isNotEmpty) {
      options.headers.putIfAbsent(headerName, () => value);
    }
  }

  @override
  Future<bool> hasCredentials(AuthStrategyContext context) async =>
      apiKey.trim().isNotEmpty;
}
