/// App-level constants for the server layer.
/// Override these at [Server.init] — they are not compile-time constants
/// so they can be set from environment config or flavor files.
class ServerConfig {
  ServerConfig._();

  static String baseUrl = '';
  static Duration defaultCacheTtl = const Duration(minutes: 5);
  static String? apiKey; // future — set when backend supports it
}
