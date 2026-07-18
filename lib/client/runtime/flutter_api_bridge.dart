import 'package:hive_flutter/hive_flutter.dart';

import '../config/api_bridge_config.dart';
import 'api_connection.dart';

/// Global registry of named, connection-scoped API runtimes.
///
/// Generated packages use a stable connection key and expose their own facade,
/// so applications normally do not import flutter_api_bridge directly.
class FlutterApiBridge {
  FlutterApiBridge._();

  static final Map<String, ApiConnection> _connections =
      <String, ApiConnection>{};
  static bool _hiveInitialized = false;

  static Iterable<String> get connectionKeys =>
      List<String>.unmodifiable(_connections.keys);

  static Future<ApiConnection> configure({
    required String key,
    required ApiBridgeConfig config,
    bool replace = true,
  }) async {
    if (!_hiveInitialized) {
      await Hive.initFlutter();
      _hiveInitialized = true;
    }
    final clean = key.trim();
    if (clean.isEmpty) {
      throw ArgumentError.value(key, 'key', 'Connection key cannot be empty.');
    }
    final existing = _connections[clean];
    if (existing != null && !replace) return existing;
    if (existing != null) await existing.dispose();
    final connection = await ApiConnection.create(key: clean, config: config);
    _connections[clean] = connection;
    return connection;
  }

  static ApiConnection? connection(String key) => _connections[key.trim()];

  static ApiConnection requireConnection(String key) {
    final connection = _connections[key.trim()];
    if (connection == null) {
      throw StateError(
        'API connection "$key" is not configured. '
        'Call the generated package configure method before use.',
      );
    }
    return connection;
  }

  static Future<void> removeConnection(String key) async {
    final connection = _connections.remove(key.trim());
    await connection?.dispose();
  }

  static Future<void> disposeAll() async {
    final values = _connections.values.toList(growable: false);
    _connections.clear();
    for (final connection in values) {
      await connection.dispose();
    }
  }
}
