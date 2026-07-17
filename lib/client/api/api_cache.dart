// lib/server/api/api_cache.dart
import 'dart:convert';

import 'package:hive_flutter/hive_flutter.dart';

const _kHiveBox = 'server_cache';
const _kCacheKeyPrefix = 'cache_v1';
const _kMaxHiveKeyLength = 240;

class _MemoryEntry {
  _MemoryEntry({
    required this.originalKey,
    required this.data,
    required this.expiresAt,
  });

  final String originalKey;
  final dynamic data;
  final DateTime expiresAt;

  bool get isExpired => DateTime.now().isAfter(expiresAt);
}

class _HiveEntry {
  _HiveEntry({
    required this.originalKey,
    required this.data,
    required this.expiresAtMs,
  });

  final String originalKey;
  final dynamic data;
  final int expiresAtMs;

  bool get isExpired => DateTime.now().millisecondsSinceEpoch > expiresAtMs;

  Map<String, dynamic> toMap() => {
    'originalKey': originalKey,
    'data': ApiCache._normalizeForHive(data),
    'expiresAtMs': expiresAtMs,
  };

  static _HiveEntry? fromMap(dynamic value) {
    if (value is! Map) return null;

    final expiresAtMs = value['expiresAtMs'];

    if (expiresAtMs is! int) return null;

    final originalKey = value['originalKey']?.toString() ?? '';

    return _HiveEntry(
      originalKey: originalKey,
      data: ApiCache._normalizeFromHive(value['data']),
      expiresAtMs: expiresAtMs,
    );
  }
}

/// Two-level cache for GET responses.
///
/// - L1 memory: instant reads, cleared on app restart.
/// - L2 Hive: persistent across restarts.
///
/// Hive has a key limit, so raw request cache keys are converted into
/// deterministic short keys:
///
/// same raw key -> same safe key
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
    final safeKey = _safeKey(key);

    // L1
    final mem = _memory[safeKey];

    if (mem != null) {
      if (!mem.isExpired) return mem.data;

      _memory.remove(safeKey);
    }

    // L2
    final raw = _box?.get(safeKey);
    final entry = _HiveEntry.fromMap(raw);

    if (entry != null) {
      if (!entry.isExpired) {
        _memory[safeKey] = _MemoryEntry(
          originalKey: entry.originalKey,
          data: entry.data,
          expiresAt: DateTime.fromMillisecondsSinceEpoch(entry.expiresAtMs),
        );

        return entry.data;
      }

      _box?.delete(safeKey);
    }

    return null;
  }

  // ── Write ──────────────────────────────────────────────────────────────────

  /// Store [data] under [key] with the given [ttl].
  static Future<void> write(String key, dynamic data, Duration ttl) async {
    final safeKey = _safeKey(key);
    final expiresAt = DateTime.now().add(ttl);

    // L1
    _memory[safeKey] = _MemoryEntry(
      originalKey: key,
      data: data,
      expiresAt: expiresAt,
    );

    // L2
    await _box?.put(
      safeKey,
      _HiveEntry(
        originalKey: key,
        data: data,
        expiresAtMs: expiresAt.millisecondsSinceEpoch,
      ).toMap(),
    );
  }

  // ── Invalidation ───────────────────────────────────────────────────────────

  /// Remove a single cache entry by exact original [key].
  static Future<void> invalidate(String key) async {
    final safeKey = _safeKey(key);

    _memory.remove(safeKey);
    await _box?.delete(safeKey);
  }

  /// Remove all entries whose original key contains [pattern].
  /// Useful for invalidating a whole endpoint family e.g. `/v1/brands`.
  static Future<void> invalidateWhere(String pattern) async {
    final memKeys = _memory.entries
        .where((entry) => entry.value.originalKey.contains(pattern))
        .map((entry) => entry.key)
        .toList();

    for (final key in memKeys) {
      _memory.remove(key);
    }

    final box = _box;
    if (box == null) return;

    final hiveKeys = box.keys.toList();

    for (final hiveKey in hiveKeys) {
      final raw = box.get(hiveKey);
      final entry = _HiveEntry.fromMap(raw);

      if (entry == null) continue;

      if (entry.originalKey.contains(pattern)) {
        await box.delete(hiveKey);
      }
    }
  }

  /// Clear everything — both L1 and L2.
  static Future<void> clearAll() async {
    _memory.clear();
    await _box?.clear();
  }

  // ── Key safety ─────────────────────────────────────────────────────────────

  static String _safeKey(String key) {
    final raw = key.trim();

    if (raw.isEmpty) {
      return '$_kCacheKeyPrefix:empty';
    }

    final hash = _fnv1a64(raw);
    final readable = _readablePart(raw);

    final candidate = '$_kCacheKeyPrefix:$hash:$readable';

    if (candidate.length <= _kMaxHiveKeyLength) {
      return candidate;
    }

    return '$_kCacheKeyPrefix:$hash';
  }

  static String _readablePart(String key) {
    final safe = key
        .replaceAll(RegExp(r'[^a-zA-Z0-9._~/-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_');

    if (safe.length <= 100) return safe;

    return safe.substring(0, 100);
  }

  /// Deterministic 64-bit FNV-1a hash.
  ///
  /// Same input string always produces the same output.
  static String _fnv1a64(String input) {
    const int fnvPrime = 0x100000001b3;
    const int fnvOffset = 0xcbf29ce484222325;
    const int mask64 = 0xffffffffffffffff;

    var hash = fnvOffset;

    for (final byte in utf8.encode(input)) {
      hash ^= byte;
      hash = (hash * fnvPrime) & mask64;
    }

    return hash.toRadixString(16).padLeft(16, '0');
  }

  // ── Hive value safety ──────────────────────────────────────────────────────

  static dynamic _normalizeForHive(dynamic value) {
    if (value == null) return null;

    if (value is String || value is num || value is bool) {
      return value;
    }

    if (value is DateTime) {
      return value.toIso8601String();
    }

    if (value is Enum) {
      return _enumWireValue(value);
    }

    if (value is Map) {
      final output = <String, dynamic>{};

      for (final entry in value.entries) {
        final key = entry.key?.toString();

        if (key == null || key.isEmpty) continue;

        output[key] = _normalizeForHive(entry.value);
      }

      return output;
    }

    if (value is Iterable) {
      return value.map(_normalizeForHive).toList();
    }

    try {
      final json = value.toJson();
      return _normalizeForHive(json);
    } catch (_) {
      return value.toString();
    }
  }

  static dynamic _normalizeFromHive(dynamic value) {
    if (value is Map<String, dynamic>) {
      return value.map((key, val) => MapEntry(key, _normalizeFromHive(val)));
    }

    if (value is Map) {
      return value.map(
        (key, val) => MapEntry(key.toString(), _normalizeFromHive(val)),
      );
    }

    if (value is List) {
      return value.map(_normalizeFromHive).toList();
    }

    return value;
  }

  static String _enumWireValue(Enum value) {
    final raw = value.toString();
    final dotIndex = raw.indexOf('.');

    if (dotIndex < 0) return raw;

    return raw.substring(dotIndex + 1);
  }
}
