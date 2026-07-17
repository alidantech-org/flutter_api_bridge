import '../auth/auth_config.dart';
import '../logging/api_logging.dart';

/// Immutable configuration for one named API connection.
class ApiBridgeConfig {
  const ApiBridgeConfig({
    required this.baseUri,
    this.auth = const AuthConfig(),
    this.logging = const ApiLoggingConfig(),
    this.defaultHeaders = const <String, String>{
      'Accept': 'application/json',
      'Content-Type': 'application/json',
    },
    this.connectTimeout = const Duration(seconds: 15),
    this.sendTimeout = const Duration(seconds: 30),
    this.receiveTimeout = const Duration(seconds: 30),
    this.defaultCacheTtl = const Duration(minutes: 5),
    this.followRedirects = true,
    this.maxRedirects = 5,
  });

  final Uri baseUri;
  final AuthConfig auth;
  final ApiLoggingConfig logging;
  final Map<String, String> defaultHeaders;
  final Duration connectTimeout;
  final Duration sendTimeout;
  final Duration receiveTimeout;
  final Duration defaultCacheTtl;
  final bool followRedirects;
  final int maxRedirects;

  void validate() {
    if (!baseUri.hasScheme || baseUri.host.trim().isEmpty) {
      throw ArgumentError.value(
        baseUri,
        'baseUri',
        'must be an absolute HTTP or HTTPS URI',
      );
    }
    if (baseUri.scheme != 'http' && baseUri.scheme != 'https') {
      throw ArgumentError.value(
        baseUri.scheme,
        'baseUri.scheme',
        'must be http or https',
      );
    }
    if (connectTimeout <= Duration.zero ||
        sendTimeout <= Duration.zero ||
        receiveTimeout <= Duration.zero) {
      throw ArgumentError('Connection timeouts must be greater than zero.');
    }
    if (defaultCacheTtl < Duration.zero) {
      throw ArgumentError('defaultCacheTtl must not be negative.');
    }
    if (maxRedirects < 0) {
      throw ArgumentError.value(maxRedirects, 'maxRedirects');
    }
  }
}
