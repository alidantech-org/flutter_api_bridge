import 'package:flutter_api_bridge/flutter_api_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ApiLogRedactor', () {
    final redactor = ApiLogRedactor(
      const ApiLoggingConfig(
        enabled: true,
        logRequestHeaders: true,
        logRequestBody: true,
      ),
    );

    test('redacts credential-bearing headers', () {
      final headers = redactor.headers(<String, dynamic>{
        'Authorization': 'Bearer secret-token',
        'Cookie': 'refresh_token=secret',
        'x-api-key': 'secret-key',
        'Accept': 'application/json',
      });

      expect(headers['Authorization'], ApiLogRedactor.redacted);
      expect(headers['Cookie'], ApiLogRedactor.redacted);
      expect(headers['x-api-key'], ApiLogRedactor.redacted);
      expect(headers['Accept'], 'application/json');
    });

    test('redacts nested authentication and password fields', () {
      final body =
          redactor.body(<String, Object?>{
                'email': 'person@example.com',
                'password': 'unsafe-password',
                'profile': <String, Object?>{
                  'access_token': 'unsafe-access',
                  'refreshToken': 'unsafe-refresh',
                  'displayName': 'Safe Name',
                },
              })!
              as Map<String, Object?>;
      final profile = body['profile']! as Map<String, Object?>;

      expect(body['email'], 'person@example.com');
      expect(body['password'], ApiLogRedactor.redacted);
      expect(profile['access_token'], ApiLogRedactor.redacted);
      expect(profile['refreshToken'], ApiLogRedactor.redacted);
      expect(profile['displayName'], 'Safe Name');
    });

    test('parses and redacts JSON strings before logging', () {
      final body =
          redactor.body('{"password":"unsafe","message":"safe"}')!
              as Map<String, Object?>;

      expect(body['password'], ApiLogRedactor.redacted);
      expect(body['message'], 'safe');
    });

    test('removes query and fragment values from URIs', () {
      final uri = redactor.uri(
        Uri.parse(
          'https://api.example.com/reset?token=unsafe&email=user@example.com#secret',
        ),
      );

      expect(uri.toString(), 'https://api.example.com/reset');
    });
  });

  test('ApiLogger sends only redacted metadata to custom sinks', () {
    final events = <ApiLogEvent>[];
    final logger = ApiLogger(
      connectionKey: 'test',
      config: ApiLoggingConfig(
        enabled: true,
        minimumLevel: ApiLogLevel.trace,
        sink: events.add,
      ),
    );

    logger.log(
      ApiLogLevel.info,
      ApiLogCategory.authentication,
      'Authentication updated',
      metadata: const <String, Object?>{
        'accessToken': 'unsafe',
        'status': 'authenticated',
      },
    );

    expect(events, hasLength(1));
    expect(events.single.metadata['accessToken'], ApiLogRedactor.redacted);
    expect(events.single.metadata['status'], 'authenticated');
  });
}