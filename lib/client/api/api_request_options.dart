class ApiRequestOptions {
  const ApiRequestOptions({
    this.headers,
    this.noAuth = false,
  });

  final Map<String, String>? headers;
  final bool noAuth;
}

class ApiGetRequestOptions extends ApiRequestOptions {
  const ApiGetRequestOptions({
    super.headers,
    super.noAuth,
    this.cache = true,
    this.cacheTtl,
    this.forceRefresh = false,
    this.invalidateCache = false,
  });

  final bool cache;
  final Duration? cacheTtl;
  final bool forceRefresh;
  final bool invalidateCache;
}
