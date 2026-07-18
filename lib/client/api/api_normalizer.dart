// lib/server/api/api_normalizer.dart

/// Normalizes generated DTO maps, query params, response bodies, and request bodies.
///
/// This file exists because generated `toJson()` methods can produce:
/// - Map<dynamic, dynamic>
/// - nested DTO instances
/// - nested Maps
/// - enums
/// - DateTime
/// - lists
/// - null/empty values
///
/// Dio needs safe `Map<String, dynamic>?` query params.
/// JSON bodies also need safe string-keyed maps.

Map<String, dynamic>? normalizeMap(Object? value) {
  if (value == null) return null;

  final jsonValue = tryToJson(value);
  final source = jsonValue ?? value;

  if (source is! Map) return null;

  final output = <String, dynamic>{};

  for (final entry in source.entries) {
    final key = entry.key?.toString();

    if (key == null || key.trim().isEmpty) continue;

    output[key] = normalizeValue(entry.value);
  }

  return output;
}

Map<String, dynamic>? normalizeQuery(Object? value) {
  final normalized = normalizeMap(value);

  if (normalized == null) return null;

  final cleaned = <String, dynamic>{};

  for (final entry in normalized.entries) {
    if (shouldSkipValue(entry.value)) continue;
    cleaned[entry.key] = entry.value;
  }

  if (cleaned.isEmpty) return null;

  return cleaned;
}

Map<String, dynamic>? buildDioQueryParameters(Object? query) {
  final normalized = normalizeQuery(query);

  if (normalized == null || normalized.isEmpty) return null;

  final output = <String, dynamic>{};

  for (final entry in normalized.entries) {
    flattenQueryEntry(
      output: output,
      key: entry.key,
      value: entry.value,
    );
  }

  if (output.isEmpty) return null;

  return output;
}

Object? normalizeBody(Object? body) {
  if (body == null) return null;

  final jsonValue = tryToJson(body);
  final source = jsonValue ?? body;

  if (source is Map) {
    return normalizeBodyMap(source);
  }

  if (source is Iterable) {
    return source.map(normalizeValue).toList();
  }

  return normalizeValue(source);
}

Map<String, dynamic> normalizeBodyMap(Map value) {
  final output = <String, dynamic>{};

  for (final entry in value.entries) {
    final key = entry.key?.toString();

    if (key == null || key.trim().isEmpty) continue;

    output[key] = normalizeValue(entry.value);
  }

  return output;
}

dynamic normalizeValue(dynamic value) {
  if (value == null) return null;

  if (value is DateTime) {
    return value.toIso8601String();
  }

  if (value is Enum) {
    return enumWireValue(value);
  }

  final jsonValue = tryToJson(value);

  if (jsonValue != null && !identical(jsonValue, value)) {
    return normalizeValue(jsonValue);
  }

  if (value is Map) {
    final output = <String, dynamic>{};

    for (final entry in value.entries) {
      final key = entry.key?.toString();

      if (key == null || key.trim().isEmpty) continue;

      final normalized = normalizeValue(entry.value);

      if (shouldSkipValue(normalized)) continue;

      output[key] = normalized;
    }

    return output;
  }

  if (value is Iterable && value is! String) {
    return value
        .map(normalizeValue)
        .where((item) => !shouldSkipValue(item))
        .toList();
  }

  return value;
}

void flattenQueryEntry({
  required Map<String, dynamic> output,
  required String key,
  required dynamic value,
}) {
  final normalizedValue = normalizeValue(value);

  if (shouldSkipValue(normalizedValue)) return;

  if (normalizedValue is Map) {
    for (final entry in normalizedValue.entries) {
      final nestedKey = entry.key?.toString();

      if (nestedKey == null || nestedKey.trim().isEmpty) continue;

      flattenQueryEntry(
        output: output,
        key: '$key.$nestedKey',
        value: entry.value,
      );
    }

    return;
  }

  if (normalizedValue is Iterable && normalizedValue is! String) {
    final items = normalizedValue
        .map(normalizeValue)
        .where((item) => !shouldSkipValue(item))
        .map((item) => item.toString())
        .toList();

    if (items.isEmpty) return;

    // CSV style:
    // fields=id,name,status
    // sort=sortOrder,-createdAt
    //
    // If your backend wants repeated keys instead:
    // output[key] = items;
    output[key] = items.join(',');
    return;
  }

  output[key] = normalizedValue;
}

String stableQueryString(Object? query) {
  final parameters = buildDioQueryParameters(query);

  if (parameters == null || parameters.isEmpty) return '';

  final parts = <String>[];
  final keys = parameters.keys.toList()..sort();

  for (final key in keys) {
    final value = parameters[key];

    if (shouldSkipValue(value)) continue;

    if (value is Iterable && value is! String) {
      for (final item in value) {
        if (shouldSkipValue(item)) continue;

        parts.add(
          '${Uri.encodeQueryComponent(key)}=${Uri.encodeQueryComponent(item.toString())}',
        );
      }

      continue;
    }

    parts.add(
      '${Uri.encodeQueryComponent(key)}=${Uri.encodeQueryComponent(value.toString())}',
    );
  }

  return parts.join('&');
}

Map<String, dynamic>? asResponseMap(dynamic value) {
  if (value == null) return null;

  final jsonValue = tryToJson(value);
  final source = jsonValue ?? value;

  if (source is Map<String, dynamic>) {
    return source;
  }

  if (source is Map) {
    return source.map(
      (key, val) => MapEntry(key.toString(), val),
    );
  }

  return null;
}

bool shouldSkipValue(dynamic value) {
  if (value == null) return true;

  if (value is String && value.trim().isEmpty) return true;

  if (value is Iterable && value is! String && value.isEmpty) return true;

  if (value is Map && value.isEmpty) return true;

  return false;
}

dynamic tryToJson(dynamic value) {
  if (value == null) return null;

  if (value is String ||
      value is num ||
      value is bool ||
      value is DateTime ||
      value is Enum ||
      value is Map ||
      value is Iterable) {
    return null;
  }

  try {
    final json = value.toJson();

    if (json == null) return null;

    if (json is Map ||
        json is Iterable ||
        json is String ||
        json is num ||
        json is bool) {
      return json;
    }

    return null;
  } catch (_) {
    return null;
  }
}

String enumWireValue(Enum value) {
  final raw = value.toString();
  final dotIndex = raw.indexOf('.');

  if (dotIndex < 0) return raw;

  return raw.substring(dotIndex + 1);
}
