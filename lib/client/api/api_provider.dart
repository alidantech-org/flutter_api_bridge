import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../server.dart';

final apiProvider =
    StateNotifierProvider<ApiNotifier, AsyncValue<ApiResult<dynamic>>>(
  (ref) => ApiNotifier(),
);

class ApiNotifier extends StateNotifier<AsyncValue<ApiResult<dynamic>>> {
  ApiNotifier()
      : super(
          const AsyncValue.data(
            ApiError(message: '', error: '', statusCode: null),
          ),
        );

  Future<ApiResult<T>> send<T>(ApiRequest<T> request) async {
    state = const AsyncValue.loading();
    final result = await Server.connection.execute(request);
    state = AsyncValue.data(result);
    return result;
  }

  void reset() {
    state = const AsyncValue.data(
      ApiError(message: '', error: '', statusCode: null),
    );
  }
}
