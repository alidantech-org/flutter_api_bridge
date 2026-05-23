// lib/server/cookies/cookie_events.dart
import 'dart:async';

/// Emitted whenever any cookie is added or updated.
class CookieChangedEvent {
  const CookieChangedEvent(
      {required this.name, required this.value, required this.domain});
  final String name;
  final String value;
  final String domain;
}

/// Emitted when all cookies are cleared.
class CookiesClearedEvent {
  const CookiesClearedEvent({required this.domain});
  final String domain;
}

/// Central event bus for all cookie activity.
/// Screens and providers can listen to any stream here.
class CookieEvents {
  CookieEvents._();

  static final _changedController =
      StreamController<CookieChangedEvent>.broadcast();
  static final _clearedController =
      StreamController<CookiesClearedEvent>.broadcast();

  /// Fires when any cookie is set or updated.
  static Stream<CookieChangedEvent> get onCookieChanged =>
      _changedController.stream;

  /// Fires when all cookies for a domain are cleared.
  static Stream<CookiesClearedEvent> get onCookiesCleared =>
      _clearedController.stream;

  /// Fires only when a specific named cookie changes.
  static Stream<CookieChangedEvent> onCookieSet(String name) =>
      _changedController.stream.where((e) => e.name == name);

  // Internal emitters — called by CookieManager only
  static void emitChanged(CookieChangedEvent event) =>
      _changedController.add(event);
  static void emitCleared(CookiesClearedEvent event) =>
      _clearedController.add(event);

  static Future<void> dispose() async {
    await _changedController.close();
    await _clearedController.close();
  }
}
