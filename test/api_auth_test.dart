import 'package:dio/dio.dart';
import 'package:flutter_api_bridge/flutter_api_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ApiAuth', () {
    test('restores an authenticated session when credentials exist', () async {
      final strategy = _FakeAuthStrategy(hasCredential: true);
      final logger = _RecordingLogger();
      final auth = ApiAuth(strategy: strategy, logger: logger);

      final session = await auth.initialize();

      expect(session.status, AuthSessionStatus.authenticated);
      expect(session.isAuthenticated, isTrue);
      expect(logger.events.last.type, ApiLogEventType.auth);
      await auth.dispose();
    });

    test('login completion explicitly persists credentials', () async {
      final strategy = _FakeAuthStrategy();
      final auth = ApiAuth(strategy: strategy);
      await auth.initialize();

      await auth.completeAuthentication(credential: 'access-token');

      expect(strategy.savedCredential, 'access-token');
      expect(auth.current.status, AuthSessionStatus.authenticated);
      await auth.dispose();
    });

    test('repeated unauthorized responses produce one expiry transition', () async {
      final strategy = _FakeAuthStrategy(hasCredential: true);
      final auth = ApiAuth(strategy: strategy);
      await auth.initialize();
      final statuses = <AuthSessionStatus>[];
      final subscription = auth.changes.listen((value) => statuses.add(value.status));

      await auth.expire();
      await auth.expire();

      expect(strategy.unauthorizedCalls, 1);
      expect(statuses.where((value) => value == AuthSessionStatus.expired), hasLength(1));
      await subscription.cancel();
      await auth.dispose();
    });

    test('clear removes credentials and becomes anonymous', () async {
      final strategy = _FakeAuthStrategy(hasCredential: true);
      final auth = ApiAuth(strategy: strategy);
      await auth.initialize();

      await auth.clear();

      expect(strategy.clearCalls, 1);
      expect(auth.current.status, AuthSessionStatus.anonymous);
      await auth.dispose();
    });
  });

  test('ApiLogRedactor removes nested secrets', () {
    const redactor = ApiLogRedactor(ApiLoggingConfig.defaultSensitiveKeys);

    final value = redactor.redact(<String, Object?>{
      'email': 'user@example.com',
      'password': 'secret',
      'headers': <String, String>{
        'Authorization': 'Bearer token',
        'Accept': 'application/json',
      },
      'nested': <Object?>[
        <String, String>{'refresh_token': 'refresh'},
      ],
    }) as Map<String, Object?>;

    expect(value['email'], 'user@example.com');
    expect(value['password'], '[REDACTED]');
    expect((value['headers'] as Map<String, Object?>)['Authorization'], '[REDACTED]');
    expect((value['headers'] as Map<String, Object?>)['Accept'], 'application/json');
    expect(((value['nested'] as List<Object?>).first as Map<String, Object?>)['refresh_token'], '[REDACTED]');
  });
}

class _FakeAuthStrategy extends AuthStrategy {
  _FakeAuthStrategy({this.hasCredential = false});

  bool hasCredential;
  String? savedCredential;
  int unauthorizedCalls = 0;
  int clearCalls = 0;

  @override
  Future<void> apply(RequestOptions options) async {}

  @override
  Future<bool> hasCredentials() async => hasCredential;

  @override
  Future<void> saveCredentials(String? credential) async {
    savedCredential = credential;
    hasCredential = true;
  }

  @override
  Future<void> clearCredentials() async {
    clearCalls += 1;
    hasCredential = false;
  }

  @override
  Future<void> onUnauthorized() async {
    unauthorizedCalls += 1;
  }
}

class _RecordingLogger implements ApiLogger {
  final List<ApiLogEvent> events = <ApiLogEvent>[];

  @override
  void log(ApiLogEvent event) => events.add(event);
}
