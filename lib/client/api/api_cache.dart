// lib/server/api/api_cache.dart
import 'package:hive_flutter/hive_flutter.dart';

const _kHiveBox = 'server_cache';

class _MemoryEntry {
  _MemoryEntry({required this.data, required this.expiresAt});
  final dynamic data;
  final DateTime expiresAt;
  bool get isExpired => DateTime.now().isAfter(expiresAt);
}

class _HiveEntry {
  _HiveEntry({required this.data, required this.expiresAtMs});
  final dynamic data;
  final int expiresAtMs; // stored as ms since epoch for Hive compatibility
  bool get isExpired => DateTime.now().millisecondsSinceEpoch > expiresAtMs;

  Map<String, dynamic> toMap() => {'data': data, 'expiresAtMs': expiresAtMs};

  static _HiveEntry fromMap(Map map) => _HiveEntry(
        data: map['data'],
        expiresAtMs: map['expiresAtMs'] as int,
      );
}

/// Two-level cache for GET responses.
///
/// - L1 (memory): instant reads, cleared on app restart.
/// - L2 (Hive): persistent across restarts, slower than memory.
///
/// On read: L1 first → L2 fallback → miss.
/// On write: both levels updated simultaneously.
/// On invalidation: both levels cleared.
class ApiCache {
  ApiCache._();

  static final Map<String, _MemoryEntry> _memory = {};

  static Box? _box;

  /// Internal — called by [Server.init].
  static Future<void> init() async {
    _box = await Hive.openBox(_kHiveBox);
  }

  // ── Read ───────────────────────────────────────────────────────────────────

  /// Returns cached data for [key] or null on miss/expiry.
  static dynamic read(String key) {
    // L1
    final mem = _memory[key];
    if (mem != null) {
      if (!mem.isExpired) return mem.data;
      _memory.remove(key); // evict expired
    }

    // L2
    final raw = _box?.get(key);
    if (raw != null) {
      final entry = _HiveEntry.fromMap(raw as Map);
      if (!entry.isExpired) {
        // Warm L1 from L2
        _memory[key] = _MemoryEntry(
            data: entry.data,
            expiresAt: DateTime.fromMillisecondsSinceEpoch(entry.expiresAtMs));
        return entry.data;
      }
      _box?.delete(key); // evict expired from Hive
    }

    return null;
  }

  // ── Write ──────────────────────────────────────────────────────────────────

  /// Store [data] under [key] with the given [ttl].
  static Future<void> write(String key, dynamic data, Duration ttl) async {
    final expiresAt = DateTime.now().add(ttl);

    // L1
    _memory[key] = _MemoryEntry(data: data, expiresAt: expiresAt);

    // L2
    await _box?.put(
      key,
      _HiveEntry(data: data, expiresAtMs: expiresAt.millisecondsSinceEpoch)
          .toMap(),
    );
  }

  // ── Invalidation ───────────────────────────────────────────────────────────

  /// Remove a single cache entry by exact [key].
  static Future<void> invalidate(String key) async {
    _memory.remove(key);
    await _box?.delete(key);
  }

  /// Remove all entries whose key contains [pattern].
  /// Useful for invalidating a whole endpoint family e.g. `/v1/brands`.
  static Future<void> invalidateWhere(String pattern) async {
    final memKeys = _memory.keys.where((k) => k.contains(pattern)).toList();
    for (final k in memKeys) {
      _memory.remove(k);
    }

    final hiveKeys =
        _box?.keys.where((k) => k.toString().contains(pattern)).toList() ?? [];
    for (final k in hiveKeys) {
      await _box?.delete(k);
    }
  }

  /// Clear everything — both L1 and L2.
  static Future<void> clearAll() async {
    _memory.clear();
    await _box?.clear();
  }
}
