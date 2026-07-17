import 'dart:io';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart' as dio_cookie;
import 'package:path_provider/path_provider.dart';

/// Token-free description of one persisted cookie credential.
class AuthCookieSnapshot {
  const AuthCookieSnapshot({required this.exists, this.expiresAt});

  final bool exists;
  final DateTime? expiresAt;

  bool isUsable(DateTime now, Duration skew) {
    if (!exists) return false;
    final expiry = expiresAt;
    if (expiry == null) return true;
    return expiry.isAfter(now.add(skew));
  }
}

/// Connection-scoped persistent cookie jar.
///
/// The legacy package used one global cookie jar for every backend. Generated
/// clients now resolve named connections, so cookie storage must be isolated by
/// connection key to prevent one API from authenticating another API.
class ConnectionCookieStore {
  ConnectionCookieStore._({
    required this.baseUri,
    required PersistCookieJar jar,
  }) : _jar = jar;

  final Uri baseUri;
  final PersistCookieJar _jar;

  static Future<ConnectionCookieStore> create({
    required String connectionKey,
    required Uri baseUri,
  }) async {
    final support = await getApplicationSupportDirectory();
    final safeKey = connectionKey.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    final directory = Directory(
      '${support.path}${Platform.pathSeparator}flutter_api_bridge${Platform.pathSeparator}$safeKey${Platform.pathSeparator}cookies',
    );
    await directory.create(recursive: true);

    return ConnectionCookieStore._(
      baseUri: baseUri,
      jar: PersistCookieJar(
        ignoreExpires: false,
        storage: FileStorage(directory.path),
      ),
    );
  }

  Interceptor get interceptor => dio_cookie.CookieManager(_jar);

  Future<List<Cookie>> all({Uri? uri}) {
    return _jar.loadForRequest(uri ?? baseUri);
  }

  Future<AuthCookieSnapshot> snapshot(String name) async {
    final cookie = await get(name);
    if (cookie == null || cookie.value.trim().isEmpty) {
      return const AuthCookieSnapshot(exists: false);
    }
    return AuthCookieSnapshot(exists: true, expiresAt: cookie.expires);
  }

  Future<Cookie?> get(String name) async {
    final cookies = await all();
    for (final cookie in cookies) {
      if (cookie.name == name) return cookie;
    }
    return null;
  }

  Future<bool> has(String name) async {
    final cookie = await get(name);
    return cookie != null && cookie.value.trim().isNotEmpty;
  }

  Future<void> set(Cookie cookie) {
    return _jar.saveFromResponse(baseUri, <Cookie>[cookie]);
  }

  Future<void> clearNames(Iterable<String> names) async {
    final targets = names.toSet();
    if (targets.isEmpty) return;

    final retained = (await all())
        .where((cookie) => !targets.contains(cookie.name))
        .toList(growable: false);

    await _jar.deleteAll();
    if (retained.isNotEmpty) {
      await _jar.saveFromResponse(baseUri, retained);
    }
  }

  Future<void> clearAll() => _jar.deleteAll();

  /// Rebuilds the Cookie header before retrying a request after refresh.
  /// This avoids reusing the stale header captured by the original 401.
  Future<void> attachTo(RequestOptions options) async {
    final cookies = await all(uri: options.uri);
    options.headers.remove(HttpHeaders.cookieHeader);
    if (cookies.isEmpty) return;

    options.headers[HttpHeaders.cookieHeader] =
        cookies.map((cookie) => '${cookie.name}=${cookie.value}').join('; ');
  }
}
