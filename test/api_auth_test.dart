import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_api_bridge/client/auth/auth_storage.dart';
import 'package:flutter_api_bridge/flutter_api_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  ApiLogger logger() {
    return ApiLogger(
      connectionKey: 'test',
      config: const ApiLoggingConfig(enabled: false),
    );
  }

  test(
    'bearer auth remains unauthenticated until credentials are established',
    () async {
      final store = MemoryAuthCredentialStore();
      final auth = ApiAuth(
        connectionKey: 'test',
        config: const AuthConfig(transport: AuthTransport.bearer),
        logger: logger(),
        refreshClient: Dio(),
        credentialStore: store,
      );
      addTearDown(auth.dispose);

      await auth.initialize();

      expect(auth.current.status, AuthSessionStatus.unauthenticated);
      expect(auth.current.isAuthenticated, isFalse);

      // A response payload is not part of ApiAuth. Authentication changes only
      // through persisted cookies or this explicit bearer credential commit.
      await auth.establish(
        accessToken: 'validated-access-token',
        refreshToken: 'validated-refresh-token',
        expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      );

      expect(auth.current.status, AuthSessionStatus.authenticated);
      expect(auth.current.isAuthenticated, isTrue);
      expect(auth.current.hasRefreshCredential, isTrue);
    },
  );

  test(
    'concurrent unauthorized requests share one refresh operation',
    () async {
      final store = MemoryAuthCredentialStore(
        StoredAuthCredentials(
          accessToken: 'expired-access-token',
          refreshToken: 'refresh-token',
          expiresAt: DateTime.now().toUtc().subtract(
                const Duration(minutes: 1),
              ),
        ),
      );
      final completer = Completer<AuthRefreshResult>();
      var refreshCalls = 0;

      final auth = ApiAuth(
        connectionKey: 'test',
        config: AuthConfig(
          transport: AuthTransport.bearer,
          refresh: (context) {
            refreshCalls += 1;
            expect(context.session.status, AuthSessionStatus.refreshing);
            return completer.future;
          },
        ),
        logger: logger(),
        refreshClient: Dio(),
        credentialStore: store,
      );
      addTearDown(auth.dispose);

      await auth.initialize();
      expect(auth.current.status, AuthSessionStatus.expired);

      final first = auth.refresh();
      final second = auth.refresh();

      expect(identical(first, second), isTrue);
      expect(refreshCalls, 1);
      expect(auth.current.status, AuthSessionStatus.refreshing);

      final expiresAt = DateTime.now().toUtc().add(const Duration(hours: 1));
      completer.complete(
        AuthRefreshResult.success(
          accessToken: 'replacement-access-token',
          expiresAt: expiresAt,
        ),
      );

      expect(await first, isTrue);
      expect(await second, isTrue);
      expect(refreshCalls, 1);
      expect(auth.current.status, AuthSessionStatus.authenticated);
      expect(store.credentials.accessToken, 'replacement-access-token');
      expect(store.credentials.refreshToken, 'refresh-token');
      expect(store.credentials.expiresAt, expiresAt);
    },
  );

  test('failed refresh clears owned credentials predictably', () async {
    final store = MemoryAuthCredentialStore(
      StoredAuthCredentials(
        accessToken: 'expired-access-token',
        refreshToken: 'refresh-token',
        expiresAt: DateTime.now().toUtc().subtract(const Duration(minutes: 1)),
      ),
    );
    final auth = ApiAuth(
      connectionKey: 'test',
      config: AuthConfig(
        transport: AuthTransport.bearer,
        refresh: (_) async =>
            const AuthRefreshResult.failure(reason: 'refresh_rejected'),
      ),
      logger: logger(),
      refreshClient: Dio(),
      credentialStore: store,
    );
    addTearDown(auth.dispose);

    await auth.initialize();
    expect(await auth.refresh(), isFalse);

    expect(auth.current.status, AuthSessionStatus.unauthenticated);
    expect(auth.current.reason, 'refresh_rejected');
    expect(store.credentials.hasAccessToken, isFalse);
    expect(store.credentials.hasRefreshToken, isFalse);
  });

  test('unauthenticated request options cannot trigger refresh', () {
    const options = ApiRequestOptions.unauthenticated();

    expect(options.usesAuthentication, isFalse);
    expect(options.retryOnUnauthorized, isFalse);
    expect(options.noAuth, isTrue);
  });
}
