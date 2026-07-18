import 'dart:io';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:crypto/crypto.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart' as dio_cookie;
import 'package:path_provider/path_provider.dart';

/// Connection-scoped persistent cookie manager.
///
/// Dio captures every eligible `Set-Cookie` response and automatically adds
/// all matching cookies to future requests, including after process restarts.
class ApiCookieManager {
  ApiCookieManager._({
    required this.baseUri,
    required PersistCookieJar jar,
  }) : _jar = jar;

  final Uri baseUri;
  final PersistCookieJar _jar;

  /// In-memory cookie jar for tests and non-persistent tooling.
  factory ApiCookieManager.memory({required Uri baseUri}) => ApiCookieManager._(
        baseUri: baseUri,
        jar: PersistCookieJar(ignoreExpires: false),
      );

  static Future<ApiCookieManager> create({
    required String connectionKey,
    required Uri baseUri,
  }) async {
    final root = await getApplicationSupportDirectory();
    final namespace = sha256
        .convert(
            '$connectionKey|${baseUri.scheme}://${baseUri.authority}'.codeUnits)
        .toString();
    final directory = Directory(
      '${root.path}${Platform.pathSeparator}flutter_api_bridge'
      '${Platform.pathSeparator}cookies${Platform.pathSeparator}$namespace',
    );
    await directory.create(recursive: true);
    final jar = PersistCookieJar(
      ignoreExpires: false,
      storage: FileStorage(directory.path),
    );
    return ApiCookieManager._(baseUri: baseUri, jar: jar);
  }

  dio_cookie.CookieManager get interceptor => dio_cookie.CookieManager(_jar);

  Future<List<Cookie>> all({Uri? uri}) => _jar.loadForRequest(uri ?? baseUri);

  Future<bool> hasAny({Uri? uri}) async {
    final cookies = await all(uri: uri);
    return cookies.any((cookie) => cookie.value.trim().isNotEmpty);
  }

  Future<bool> hasAnyNamed(
    Iterable<String> names, {
    Uri? uri,
  }) async {
    final expected = names
        .map((name) => name.trim())
        .where((name) => name.isNotEmpty)
        .toSet();
    if (expected.isEmpty) return hasAny(uri: uri);
    final cookies = await all(uri: uri);
    return cookies.any(
      (cookie) =>
          expected.contains(cookie.name) && cookie.value.trim().isNotEmpty,
    );
  }

  Future<void> save(
    Iterable<Cookie> cookies, {
    Uri? uri,
  }) async {
    final values = cookies.toList(growable: false);
    if (values.isEmpty) return;
    await _jar.saveFromResponse(uri ?? baseUri, values);
  }

  Future<void> setValues(
    Map<String, String> cookies, {
    Uri? uri,
  }) async {
    await save(
      cookies.entries.map((entry) => Cookie(entry.key, entry.value)),
      uri: uri,
    );
  }

  /// Builds a request-only cookie header without persisting the overrides.
  Future<String?> mergedHeader({
    required Uri uri,
    Map<String, String> overrides = const <String, String>{},
  }) async {
    final values = <String, String>{
      for (final cookie in await all(uri: uri)) cookie.name: cookie.value,
      ...overrides,
    };
    values.removeWhere(
      (key, value) => key.trim().isEmpty || value.trim().isEmpty,
    );
    if (values.isEmpty) return null;
    return values.entries
        .map((entry) => '${entry.key}=${entry.value}')
        .join('; ');
  }

  Future<void> clearAll() => _jar.deleteAll();
}
