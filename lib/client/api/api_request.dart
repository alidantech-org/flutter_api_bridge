import 'dart:async';

import 'package:dio/dio.dart';

import 'api_normalizer.dart';
import 'api_request_options.dart';

class UploadFile {
  const UploadFile.fromPath({
    required this.field,
    required this.path,
    this.filename,
  })  : bytes = null,
        stream = null,
        _length = null;

  const UploadFile.fromBytes({
    required this.field,
    required this.bytes,
    required this.filename,
  })  : path = null,
        stream = null,
        _length = null;

  const UploadFile.fromStream({
    required this.field,
    required this.stream,
    required this.filename,
    required int length,
  })  : path = null,
        bytes = null,
        _length = length;

  final String field;
  final String? filename;
  final String? path;
  final List<int>? bytes;
  final Stream<List<int>>? stream;
  final int? _length;

  int get length => _length ?? 0;

  Future<MapEntry<String, MultipartFile>> toMultipart() async {
    if (path != null) {
      return MapEntry(
        field,
        await MultipartFile.fromFile(path!, filename: filename),
      );
    }
    if (bytes != null) {
      return MapEntry(
        field,
        MultipartFile.fromBytes(bytes!, filename: filename),
      );
    }
    if (stream != null) {
      return MapEntry(
        field,
        MultipartFile.fromStream(
          () => stream!,
          length,
          filename: filename,
        ),
      );
    }
    throw StateError('UploadFile has no source: path, bytes, or stream.');
  }
}

sealed class ApiRequest<T> {
  const ApiRequest({
    required this.endpoint,
    this.version = '',
    this.fromJson,
    this.query,
    this.options,
  });

  final String endpoint;
  final String version;
  final T Function(dynamic json)? fromJson;
  final Object? query;
  final ApiRequestOptions? options;

  bool get noAuth => options?.noAuth ?? false;
  Map<String, String>? get headers => options?.headers;
  Map<String, String>? get cookies => options?.cookies;
  String? get operationId => options?.operationId;
  String get fullPath => '$version$endpoint';
}

class GetRequest<T> extends ApiRequest<T> {
  const GetRequest({
    required super.endpoint,
    super.fromJson,
    super.version,
    super.query,
    ApiGetRequestOptions? options,
  })  : getOptions = options,
        super(options: options);

  final ApiGetRequestOptions? getOptions;

  bool get cache => getOptions?.cache ?? true;
  Duration? get cacheTtl => getOptions?.cacheTtl;
  bool get forceRefresh => getOptions?.forceRefresh ?? false;
  bool get invalidateCache => getOptions?.invalidateCache ?? false;

  String get cacheKey {
    final queryString = stableQueryString(query);
    if (queryString.isEmpty) return fullPath;
    return '$fullPath?$queryString';
  }
}

class PostRequest<T> extends ApiRequest<T> {
  const PostRequest({
    required super.endpoint,
    super.fromJson,
    super.version,
    super.query,
    super.options,
    this.body,
  });

  final Object? body;
}

class PutRequest<T> extends ApiRequest<T> {
  const PutRequest({
    required super.endpoint,
    super.fromJson,
    super.version,
    super.query,
    super.options,
    this.body,
  });

  final Object? body;
}

class PatchRequest<T> extends ApiRequest<T> {
  const PatchRequest({
    required super.endpoint,
    super.fromJson,
    super.version,
    super.query,
    super.options,
    this.body,
  });

  final Object? body;
}

class DeleteRequest<T> extends ApiRequest<T> {
  const DeleteRequest({
    required super.endpoint,
    super.fromJson,
    super.version,
    super.query,
    super.options,
    this.body,
  });

  final Object? body;
}

class UploadRequest<T> extends ApiRequest<T> {
  const UploadRequest({
    required super.endpoint,
    super.fromJson,
    required this.files,
    super.version,
    super.query,
    ApiUploadRequestOptions? options,
    this.fields,
    this.method = UploadMethod.post,
  })  : uploadOptions = options,
        super(options: options);

  final List<UploadFile> files;
  final Map<String, String>? fields;
  final UploadMethod method;
  final ApiUploadRequestOptions? uploadOptions;
}

enum UploadMethod { post, put, patch }
