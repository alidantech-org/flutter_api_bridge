import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../config/api_bridge_config.dart';

enum ApiCacheSource { memory, hive }

class ApiCacheRead {
  const ApiCacheRead({
    required this.data,
    required this.source,
    required this.isStale,
    required this.storedAt,
    required this.expiresAt,
  });

  final dynamic data;
  final ApiCacheSource source;
  final bool isStale;
  final DateTime storedAt;
  final DateTime expiresAt;
}

class _CacheEntry {
  _CacheEntry({
    required this.originalKey,
    required this.sessionHash,
    required this.data,
    required this.tags,
    required this.storedAtMs,
    required this.expiresAtMs,
    required this.lastAccessedAtMs,
  });

  final String originalKey;
  final String sessionHash;
  final dynamic data;
  final List<String> tags;
  final int storedAtMs;
  final int expiresAtMs;
  int lastAccessedAtMs;

  bool get isStale => DateTime.now().millisecondsSinceEpoch > expiresAtMs;

  Map<String, dynamic> toMap() => <String, dynamic>{
        'originalKey': originalKey,
        'sessionHash': sessionHash,
        'data': ApiCache._normalizeForHive(data),
        'tags': tags,
        'storedAtMs': storedAtMs,
        'expiresAtMs': expiresAtMs,
        'lastAccessedAtMs': lastAccessedAtMs,
      };

  static _CacheEntry? fromMap(dynamic value) {
    if (value is! Map) return null;
    final originalKey = value['originalKey']?.toString();
    final sessionHash = value['sessionHash']?.toString();
    final storedAtMs = value['storedAtMs'];
    final expiresAtMs = value['expiresAtMs'];
    final lastAccessedAtMs = value['lastAccessedAtMs'];
    if (originalKey == null ||
        sessionHash == null ||
        storedAtMs is! int ||
        expiresAtMs is! int ||
        lastAccessedAtMs is! int) {
      return null;
    }
    return _CacheEntry(
      originalKey: originalKey,
      sessionHash: sessionHash,
      data: ApiCache._normalizeFromHive(value['data']),
      tags: value['tags'] is Iterable
          ? (value['tags'] as Iterable)
              .map((item) => item.toString())
              .toList(growable: false)
          : const <String>[],
      storedAtMs: storedAtMs,
      expiresAtMs: expiresAtMs,
      lastAccessedAtMs: lastAccessedAtMs,
    );
  }
}

/// Connection-scoped, session-partitioned L1 memory + L2 Hive cache.
class ApiCache {
  ApiCache._({
    required this.connectionKey,
    required this.config,
    required Box<dynamic> box,
  }) : _box = box;

  final String connectionKey;
  final ApiCacheConfig config;
  final Box<dynamic> _box;
  final Map<String, _CacheEntry> _memory = <String, _CacheEntry>{};

  String _activeSessionId = 'anonymous';
  String _activeSessionHash = _hash('anonymous');

  String get activeSessionId => _activeSessionId;

  static Future<ApiCache> create({
    required String connectionKey,
    required Uri baseUri,
    required ApiCacheConfig config,
  }) async {
    final connectionHash = _hash(
      '$connectionKey|${baseUri.scheme}://${baseUri.authority}',
    ).substring(0, 24);
    final box = await Hive.openBox<dynamic>('fab_cache_$connectionHash');
    return ApiCache._(
      connectionKey: connectionKey,
      config: config,
      box: box,
    );
  }

  Future<void> startSession({
    required String sessionId,
    Map<String, Object?> metadata = const <String, Object?>{},
    bool? clearPreviousOnChange,
  }) async {
    final clean = sessionId.trim();
    if (clean.isEmpty) {
      throw ArgumentError.value(sessionId, 'sessionId', 'Cannot be empty.');
    }
    final previousId = _activeSessionId;
    final previousHash = _activeSessionHash;
    final nextHash = _hash(clean);
    final changed = previousHash != nextHash;
    if (changed &&
        (clearPreviousOnChange ?? config.clearPreviousSessionOnChange)) {
      await _clearSessionHash(previousHash);
    }
    _activeSessionId = clean;
    _activeSessionHash = nextHash;
    if (metadata.isNotEmpty) {
      await _box.put(
        '__session__:$nextHash',
        <String, dynamic>{
          'sessionHash': nextHash,
          'metadata': _normalizeForHive(metadata),
          'updatedAtMs': DateTime.now().millisecondsSinceEpoch,
          if (previousId != clean) 'previousSessionChanged': true,
        },
      );
    }
  }

  String keyFor({
    required String method,
    required String path,
    String query = '',
    Map<String, String> varyHeaders = const <String, String>{},
    String? operationId,
  }) {
    final headers = varyHeaders.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final raw = <String>[
      method.toUpperCase(),
      path,
      query,
      if (operationId != null) operationId,
      for (final entry in headers)
        '${entry.key.toLowerCase()}:${entry.value}',
    ].join('|');
    return raw;
  }

  String _storageKey(String originalKey, [String? sessionHash]) =>
      'entry:${sessionHash ?? _activeSessionHash}:${_hash(originalKey)}';

  Future<ApiCacheRead?> read(
    String originalKey, {
    bool allowStale = false,
  }) async {
    if (!config.enabled) return null;
    final key = _storageKey(originalKey);
    var entry = _memory[key];
    var source = ApiCacheSource.memory;
    if (entry == null) {
      entry = _CacheEntry.fromMap(_box.get(key));
      source = ApiCacheSource.hive;
      if (entry != null) _memory[key] = entry;
    }
    if (entry == null) return null;
    if (entry.sessionHash != _activeSessionHash) return null;
    if (entry.isStale && !allowStale) return null;
    entry.lastAccessedAtMs = DateTime.now().millisecondsSinceEpoch;
    if (source == ApiCacheSource.hive) {
      await _box.put(key, entry.toMap());
    }
    return ApiCacheRead(
      data: entry.data,
      source: source,
      isStale: entry.isStale,
      storedAt: DateTime.fromMillisecondsSinceEpoch(entry.storedAtMs),
      expiresAt: DateTime.fromMillisecondsSinceEpoch(entry.expiresAtMs),
    );
  }

  Future<void> write(
    String originalKey,
    dynamic data, {
    required Duration ttl,
    Iterable<String> tags = const <String>[],
  }) async {
    if (!config.enabled) return;
    final now = DateTime.now();
    final cleanTags = tags
        .map((tag) => tag.trim())
        .where((tag) => tag.isNotEmpty)
        .toSet()
        .toList(growable: false);
    final entry = _CacheEntry(
      originalKey: originalKey,
      sessionHash: _activeSessionHash,
      data: data,
      tags: cleanTags,
      storedAtMs: now.millisecondsSinceEpoch,
      expiresAtMs: now.add(ttl).millisecondsSinceEpoch,
      lastAccessedAtMs: now.millisecondsSinceEpoch,
    );
    final key = _storageKey(originalKey);
    _memory[key] = entry;
    await _box.put(key, entry.toMap());
    await _evictIfNeeded();
  }

  Future<void> invalidate(String originalKey) async {
    final key = _storageKey(originalKey);
    _memory.remove(key);
    await _box.delete(key);
  }

  Future<void> invalidateWhere(String pattern) async {
    final clean = pattern.trim();
    if (clean.isEmpty) return;
    await _deleteMatching(
      (entry) => entry.sessionHash == _activeSessionHash &&
          entry.originalKey.contains(clean),
    );
  }

  Future<void> invalidateTags(Iterable<String> tags) async {
    final expected = tags
        .map((tag) => tag.trim())
        .where((tag) => tag.isNotEmpty)
        .toSet();
    if (expected.isEmpty) return;
    await _deleteMatching(
      (entry) => entry.sessionHash == _activeSessionHash &&
          entry.tags.any(expected.contains),
    );
  }

  Future<void> clearActiveSession() => _clearSessionHash(_activeSessionHash);

  Future<void> clearSession(String sessionId) =>
      _clearSessionHash(_hash(sessionId.trim()));

  Future<void> clearAll() async {
    _memory.clear();
    await _box.clear();
  }

  Future<void> _clearSessionHash(String sessionHash) async {
    await _deleteMatching((entry) => entry.sessionHash == sessionHash);
    await _box.delete('__session__:$sessionHash');
  }

  Future<void> _deleteMatching(bool Function(_CacheEntry entry) matches) async {
    final keys = _box.keys.toList(growable: false);
    for (final key in keys) {
      if (key is! String || !key.startsWith('entry:')) continue;
      final entry = _CacheEntry.fromMap(_box.get(key));
      if (entry == null || !matches(entry)) continue;
      _memory.remove(key);
      await _box.delete(key);
    }
  }

  Future<void> _evictIfNeeded() async {
    if (config.maxEntries <= 0) return;
    final entries = <MapEntry<dynamic, _CacheEntry>>[];
    for (final key in _box.keys) {
      if (key is! String || !key.startsWith('entry:')) continue;
      final entry = _CacheEntry.fromMap(_box.get(key));
      if (entry != null) {
        entries.add(MapEntry<dynamic, _CacheEntry>(key, entry));
      }
    }
    final overflow = entries.length - config.maxEntries;
    if (overflow <= 0) return;
    entries.sort(
      (a, b) =>
          a.value.lastAccessedAtMs.compareTo(b.value.lastAccessedAtMs),
    );
    for (final item in entries.take(overflow)) {
      _memory.remove(item.key);
      await _box.delete(item.key);
    }
  }

  static String _hash(String value) =>
      sha256.convert(utf8.encode(value)).toString();

  static dynamic _normalizeForHive(dynamic value) {
    if (value == null || value is String || value is num || value is bool) {
      return value;
    }
    if (value is DateTime) return value.toIso8601String();
    if (value is Enum) return value.name;
    if (value is Map) {
      return <String, dynamic>{
        for (final entry in value.entries)
          entry.key.toString(): _normalizeForHive(entry.value),
      };
    }
    if (value is Iterable) {
      return value.map(_normalizeForHive).toList(growable: false);
    }
    try {
      return _normalizeForHive(value.toJson());
    } catch (_) {
      throw ArgumentError(
        'Cache values must be JSON/Hive compatible. Unsupported: '
        '${value.runtimeType}',
      );
    }
  }

  static dynamic _normalizeFromHive(dynamic value) {
    if (value is Map) {
      return value.map(
        (key, item) => MapEntry(key.toString(), _normalizeFromHive(item)),
      );
    }
    if (value is List) {
      return value.map(_normalizeFromHive).toList(growable: false);
    }
    return value;
  }
}
