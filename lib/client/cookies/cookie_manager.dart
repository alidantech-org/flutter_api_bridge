// lib/server/cookies/cookie_manager.dart
import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart' as dio_cm;
import 'package:path_provider/path_provider.dart';
import 'cookie_events.dart';

/// Wraps Dio's [PersistCookieJar] with helper methods and event emission.
///
/// Cookies set by the backend are handled automatically via the Dio interceptor.
/// Use the methods here when the app needs to inspect or clear cookies manually
/// e.g. after logout or to validate login cookies were received.
class CookieManager {
  CookieManager._();

  static PersistCookieJar? _jar;
  static String? _baseUrl;

  /// Internal — called by [Server.init].
  static Future<void> init(String baseUrl) async {
    _baseUrl = baseUrl;
    final dir = await getApplicationDocumentsDirectory();
    _jar = PersistCookieJar(storage: FileStorage('${dir.path}/.cookies/'));
  }

  /// The Dio interceptor — attach to the Dio instance in [ApiClient].
  static dio_cm.CookieManager get interceptor {
    _assertInit();
    return dio_cm.CookieManager(_jar!);
  }

  static Uri get _uri => Uri.parse(_baseUrl!);

  // ── Read ───────────────────────────────────────────────────────────────────

  /// Get all cookies for the base URL.
  static Future<List<Cookie>> all() async {
    _assertInit();
    return _jar!.loadForRequest(_uri);
  }

  /// Get a single cookie by name. Returns null if not found.
  static Future<Cookie?> get(String name) async {
    final cookies = await all();
    try {
      return cookies.firstWhere((c) => c.name == name);
    } catch (_) {
      return null;
    }
  }

  /// Get a cookie's value by name. Returns null if not found.
  static Future<String?> getValue(String name) async {
    final cookie = await get(name);
    return cookie?.value;
  }

  /// Returns true if a cookie with [name] exists and has a non-empty value.
  static Future<bool> has(String name) async {
    final value = await getValue(name);
    return value != null && value.isNotEmpty;
  }

  // ── Write ──────────────────────────────────────────────────────────────────

  /// Manually set a cookie — useful for app-side cookie injection.
  /// Emits [CookieEvents.onCookieChanged].
  static Future<void> set(Cookie cookie) async {
    _assertInit();
    await _jar!.saveFromResponse(_uri, [cookie]);
    CookieEvents.emitChanged(CookieChangedEvent(
        name: cookie.name, value: cookie.value, domain: _uri.host));
  }

  /// Convenience: set a cookie by name and value.
  static Future<void> setValue(String name, String value) async {
    await set(Cookie(name, value));
  }

  // ── Clear ──────────────────────────────────────────────────────────────────

  /// Clear all cookies for the base URL.
  /// Emits [CookieEvents.onCookiesCleared].
  static Future<void> clearAll() async {
    _assertInit();
    await _jar!.deleteAll();
    CookieEvents.emitCleared(CookiesClearedEvent(domain: _uri.host));
  }

  /// Clear a specific cookie by name.
  /// Emits [CookieEvents.onCookieChanged] with an empty value.
  static Future<void> clearByName(String name) async {
    final allCookies = await all();
    final updated = allCookies.where((c) => c.name != name).toList();
    await _jar!.deleteAll();
    if (updated.isNotEmpty) {
      await _jar!.saveFromResponse(_uri, updated);
    }
    CookieEvents.emitChanged(
        CookieChangedEvent(name: name, value: '', domain: _uri.host));
  }

  // ── Internal ───────────────────────────────────────────────────────────────

  static void _assertInit() {
    assert(_jar != null,
        'CookieManager not initialised. Call Server.init() first.');
  }
}
