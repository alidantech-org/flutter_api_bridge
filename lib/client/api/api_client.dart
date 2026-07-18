import 'package:dio/dio.dart';

import '../server.dart';

/// Legacy raw Dio access.
///
/// Generated clients should execute typed requests through ApiConnection so
/// caching, retries, diagnostics, and invalidation remain active.
class ApiClient {
  ApiClient._();

  static Dio instance([String version = '']) => Server.connection.rawDio;

  static void reset() {}
}
