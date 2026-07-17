import 'dart:async';

import 'package:hive_flutter/hive_flutter.dart';

import 'api/api_bridge_config.dart';
import 'api/api_cache.dart';
import 'api/api_connection.dart';

/// Registry for isolated named API connections.
///
/// Generated SDK packages use a stable connection key and resolve the same
/// [ApiConnection] from widgets, background services, providers, and plain Dart
/// classes without coupling the bridge to a state-management framework.
class FlutterApiBridge {
  FlutterApiBridge._();

  static final Map<String, ApiConnection> _connections =
      <String, ApiConnection>{};
  static Future<void>? _initializeFuture;

  static Iterable<String> get connectionKeys =>
      List<String>.unmodifiable(_connections.keys);

  static Future<void> configure({
    required String key,
    required ApiBridgeConfig config,
    bool replace = true,
  }) async {
    final cleanKey = key.trim();
    if (cleanKey.isEmpty) {
      throw ArgumentError.value(key, 'key', 'must not be empty');
    }
    config.validate();
    await _ensureInitialized();

    final existing = _connections[cleanKey];
    if (existing != null && !replace) {
      throw StateError(
        'A flutter_api_bridge connection named "$cleanKey" already exists.',
      );
    }

    final created = await ApiConnection.create(key: cleanKey, config: config);
    _connections[cleanKey] = created;

    if (existing != null) {
      await existing.dispose();
    }
  }

  static ApiConnection? connection(String key) {
    return _connections[key.trim()];
  }

  static ApiConnection requireConnection(String key) {
    final cleanKey = key.trim();
    final connection = _connections[cleanKey];
    if (connection == null) {
      throw StateError(
        'No flutter_api_bridge connection named "$cleanKey" is configured. '
        'Call FlutterApiBridge.configure before using the generated API.',
      );
    }
    return connection;
  }

  static Future<void> removeConnection(String key) async {
    final connection = _connections.remove(key.trim());
    if (connection != null) await connection.dispose();
  }

  static Future<void> dispose() async {
    final connections = _connections.values.toList(growable: false);
    _connections.clear();
    await Future.wait(connections.map((connection) => connection.dispose()));
  }

  static Future<void> _ensureInitialized() {
    return _initializeFuture ??= _initializeStorage();
  }

  static Future<void> _initializeStorage() async {
    await Hive.initFlutter();
    await ApiCache.init();
  }
}
