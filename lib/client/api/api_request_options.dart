/// Authentication behavior for one API request.
enum ApiAuthPolicy {
  /// Apply credentials when available and allow one configured refresh retry.
  automatic,

  /// Never attach credentials and never refresh after a 401.
  none,
}

class ApiRequestOptions {
  const ApiRequestOptions({
    this.headers,
    this.noAuth = false,
    this.authPolicy = ApiAuthPolicy.automatic,
    this.retryOnUnauthorized = true,
  });

  /// Convenience for login, signup, password reset, health, and other public
  /// endpoints. A failed login must never trigger refresh of an older session.
  const ApiRequestOptions.unauthenticated({this.headers})
    : noAuth = true,
      authPolicy = ApiAuthPolicy.none,
      retryOnUnauthorized = false;

  final Map<String, String>? headers;

  /// Backwards-compatible alias retained for existing generated clients.
  final bool noAuth;

  final ApiAuthPolicy authPolicy;

  /// At most one retry is attempted, and only when credentials were actually
  /// attached to the failed request.
  final bool retryOnUnauthorized;

  bool get usesAuthentication {
    return !noAuth && authPolicy != ApiAuthPolicy.none;
  }
}

class ApiGetRequestOptions extends ApiRequestOptions {
  const ApiGetRequestOptions({
    super.headers,
    super.noAuth,
    super.authPolicy,
    super.retryOnUnauthorized,
    this.cache = true,
    this.cacheTtl,
    this.forceRefresh = false,
    this.invalidateCache = false,
  });

  const ApiGetRequestOptions.unauthenticated({
    Map<String, String>? headers,
    this.cache = true,
    this.cacheTtl,
    this.forceRefresh = false,
    this.invalidateCache = false,
  }) : super.unauthenticated(headers: headers);

  final bool cache;
  final Duration? cacheTtl;
  final bool forceRefresh;
  final bool invalidateCache;
}