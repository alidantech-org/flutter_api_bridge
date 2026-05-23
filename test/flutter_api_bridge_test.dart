import 'package:flutter_api_bridge/flutter_api_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ApiSuccess exposes parsed response details', () {
    const result = ApiSuccess<Map<String, Object?>>(
      message: 'Loaded',
      statusCode: 200,
      data: {'id': 1},
    );

    expect(result.isSuccess, isTrue);
    expect(result.isError, isFalse);
    expect(result.message, 'Loaded');
    expect(result.dataOrNull, {'id': 1});
  });

  test('UploadProgress reports ratios and completion', () {
    const progress = UploadProgress(sent: 75, total: 100);
    const done = UploadProgress.done(100);

    expect(progress.percent, 0.75);
    expect(progress.isDone, isFalse);
    expect(done.percent, 1);
    expect(done.isDone, isTrue);
  });
}
