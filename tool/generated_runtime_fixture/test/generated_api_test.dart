import 'package:flutter_test/flutter_test.dart';
import 'package:generated_runtime_fixture/generated_api.dart';

void main() {
  test('application imports bridge controls through generated package', () {
    const options = ApiGetRequestOptions(
      cache: false,
      forceRefresh: true,
      cookies: <String, String>{'preview': 'yes'},
      headers: <String, String>{'X-Tenant': 'company-7'},
    );

    final generated = options.copyWith(operationId: 'things.list');

    expect(GeneratedApi.connectionKey, 'generated_api_fixture');
    expect(generated.operationId, 'things.list');
    expect(generated.cache, isFalse);
    expect(generated.forceRefresh, isTrue);
    expect(generated.cookies?['preview'], 'yes');
    expect(generated.headers?['X-Tenant'], 'company-7');
  });

  test('generated package exposes production runtime configuration', () {
    const cache = ApiCacheConfig(
      defaultPolicy: ApiCachePolicy.networkWithStaleFallback,
    );
    const retry = ApiRetryConfig(maxAttempts: 3);
    const identity = ApiClientIdentity(
      applicationName: 'RiderescueDriver',
      applicationVersion: '1.0.0',
      platform: 'android',
    );
    const upload = ApiUploadRequestOptions(
      operationId: 'things.upload',
      idempotencyKey: 'upload-1',
    );

    expect(cache.defaultPolicy, ApiCachePolicy.networkWithStaleFallback);
    expect(retry.maxAttempts, 3);
    expect(identity.userAgent, contains('RiderescueDriver/1.0.0'));
    expect(upload.operationId, 'things.upload');
    expect(upload.idempotencyKey, 'upload-1');
  });
}
