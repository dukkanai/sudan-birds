import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sudan_birds/domain.dart';
import 'package:sudan_birds/auth_config.dart';
import 'package:sudan_birds/mobile_oauth.dart';
import 'package:sudan_birds/secure_auth_storage.dart';
import 'secure_auth_storage_test.dart' show MemoryCredentials, MemoryFence;
import 'session_repository_test.dart' show session, a;

class PasswordHarness {
  PasswordHarness({
    Duration timeout = const Duration(seconds: 20),
    Future<void> Function(String)? install,
    bool logoutFails = false,
  }) {
    storage = SecureAuthStorage(memory, fence: MemoryFence());
    main = GoTrueClient(
      url: 'https://synthetic.invalid/auth/v1',
      autoRefreshToken: false,
      httpClient: MockClient(
        (_) async => http.Response('{}', logoutFails ? 503 : 200),
      ),
    );
    coordinator = MobileOAuthCoordinator(
      mainAuth: main,
      storage: storage,
      notice: (_) {},
      install: install,
      exchangeTimeout: timeout,
      createClient: (pkce) => GoTrueClient(
        url: 'https://synthetic.invalid/auth/v1',
        autoRefreshToken: false,
        asyncStorage: pkce,
        httpClient: MockClient((request) async {
          calls++;
          expect(request.url.queryParameters['grant_type'], 'password');
          expect(jsonDecode(request.body)['email'], 'trial@example.invalid');
          expect(
            jsonDecode(request.body)['password'],
            'synthetic-password-only',
          );
          if (!entered.isCompleted) entered.complete();
          return response.future;
        }),
      ),
    );
  }
  final memory = MemoryCredentials();
  final entered = Completer<void>();
  final response = Completer<http.Response>();
  late final SecureAuthStorage storage;
  late final GoTrueClient main;
  late final MobileOAuthCoordinator coordinator;
  int calls = 0;
  Future<bool> login() => coordinator.signInWithPassword(
    ' trial@example.invalid ',
    'synthetic-password-only',
  );
  void succeed() => response.complete(
    http.Response(
      jsonEncode(session(a)),
      200,
      headers: {'content-type': 'application/json'},
    ),
  );
  Future<void> dispose() async {
    await coordinator.dispose();
    main.dispose();
    await storage.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'password login installs and persists only session, not password',
    () async {
      final h = PasswordHarness();
      addTearDown(h.dispose);
      final login = h.login();
      await h.entered.future;
      h.succeed();
      expect(await login, true);
      expect(h.main.currentUser!.id, a);
      expect(h.storage.acceptsSessions, true);
      expect(
        h.memory.values.values.join(),
        isNot(contains('synthetic-password-only')),
      );
      expect(
        h.memory.values.values.join(),
        isNot(contains('trial@example.invalid')),
      );
    },
  );
  test(
    'invalid credentials are safe, clear local state and never install',
    () async {
      final h = PasswordHarness();
      addTearDown(h.dispose);
      final login = expectLater(
        h.login(),
        throwsA(
          isA<AppFailure>().having(
            (e) => e.message,
            'safe message',
            isNot(contains('PRIVATE')),
          ),
        ),
      );
      await h.entered.future;
      h.response.complete(
        http.Response(
          '{"error_code":"invalid_credentials","msg":"PRIVATE-password"}',
          400,
          headers: {'content-type': 'application/json'},
        ),
      );
      await login;
      expect(h.main.currentSession, isNull);
      expect(h.memory.values, isEmpty);
    },
  );
  for (final signout in [false, true]) {
    test(
      '${signout ? 'signout' : 'cancel'} rejects delayed password success',
      () async {
        final h = PasswordHarness();
        addTearDown(h.dispose);
        final login = expectLater(h.login(), throwsA(isA<AppFailure>()));
        await h.entered.future;
        if (signout) {
          await h.coordinator.signOut();
        } else {
          await h.coordinator.cancelSignIn();
        }
        h.succeed();
        await login;
        expect(h.main.currentSession, isNull);
        expect(h.memory.values, isEmpty);
        expect(h.storage.acceptsSessions, false);
      },
    );
  }
  test(
    'repeated password attempt does not dispatch a second request',
    () async {
      final h = PasswordHarness();
      addTearDown(h.dispose);
      final first = h.login();
      await h.entered.future;
      await expectLater(h.login(), throwsA(isA<AppFailure>()));
      expect(h.calls, 1);
      h.succeed();
      expect(await first, true);
    },
  );
  test('timeout cannot install eventual isolated-client success', () async {
    final h = PasswordHarness(timeout: const Duration(milliseconds: 10));
    addTearDown(h.dispose);
    final login = expectLater(h.login(), throwsA(isA<AppFailure>()));
    await h.entered.future;
    await login;
    h.succeed();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(h.main.currentSession, isNull);
    expect(h.memory.values, isEmpty);
  });
  test('malformed credentials rejected without network', () async {
    final h = PasswordHarness();
    addTearDown(h.dispose);
    await expectLater(
      h.coordinator.signInWithPassword('bad-email', ''),
      throwsA(isA<AppFailure>()),
    );
    expect(h.calls, 0);
  });
  test(
    'installation failure preserves safe storage/logout boundaries',
    () async {
      final h = PasswordHarness(
        install: (_) async {
          throw StateError('PRIVATE');
        },
      );
      addTearDown(h.dispose);
      final login = expectLater(h.login(), throwsA(isA<AppFailure>()));
      await h.entered.future;
      h.succeed();
      await login;
      expect(h.main.currentSession, isNull);
      expect(h.memory.values, isEmpty);
      expect(h.storage.acceptsSessions, false);
    },
  );
  test(
    'logout during password candidate persistence cannot restore identity',
    () async {
      final h = PasswordHarness();
      addTearDown(h.dispose);
      h.memory.pendingWrite = Completer<void>();
      final login = expectLater(h.login(), throwsA(isA<AppFailure>()));
      await h.entered.future;
      h.succeed();
      for (var i = 0; i < 100 && !h.memory.calls.contains('write'); i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(h.memory.calls, contains('write'));
      final logout = h.coordinator.signOut();
      h.memory.pendingWrite!.complete();
      await login;
      await logout;
      expect(h.main.currentSession, isNull);
      expect(h.memory.values, isEmpty);
      expect(h.storage.acceptsSessions, false);
    },
  );

  test(
    'logout waits for delayed password installation then clears it',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      late PasswordHarness h;
      h = PasswordHarness(
        install: (encoded) async {
          entered.complete();
          await release.future;
          await h.main.setInitialSession(encoded);
        },
      );
      addTearDown(h.dispose);
      final login = expectLater(h.login(), throwsA(isA<AppFailure>()));
      await h.entered.future;
      h.succeed();
      await entered.future;
      final logout = h.coordinator.signOut();
      release.complete();
      await login;
      await logout;
      expect(h.main.currentSession, isNull);
      expect(h.memory.values, isEmpty);
    },
  );
  test(
    'stale OAuth callback cannot exchange during password authentication',
    () async {
      final h = PasswordHarness();
      addTearDown(h.dispose);
      final login = h.login();
      await h.entered.future;
      await h.coordinator.handleCallback(
        Uri.parse('$stagingAuthRedirect?code=stale-code'),
      );
      expect(h.calls, 1);
      h.succeed();
      expect(await login, true);
    },
  );

  test(
    'failed login cleanup reports uncertain server logout rather than hiding it',
    () async {
      late PasswordHarness h;
      h = PasswordHarness(
        logoutFails: true,
        install: (encoded) async {
          await h.main.setInitialSession(encoded);
          throw StateError('PRIVATE-installation-error');
        },
      );
      addTearDown(h.dispose);
      final login = expectLater(
        h.login(),
        throwsA(
          isA<AppFailure>()
              .having((e) => e.outcomeUnknown, 'unknown logout', true)
              .having(
                (e) => e.message,
                'safe error',
                isNot(contains('PRIVATE')),
              ),
        ),
      );
      await h.entered.future;
      h.succeed();
      await login;
      expect(h.memory.values, isEmpty);
      expect(h.storage.acceptsSessions, false);
    },
  );
  test(
    'cancel retry performs cleanup after first storage failure and retired flow',
    () async {
      final h = PasswordHarness();
      addTearDown(h.dispose);
      final login = expectLater(h.login(), throwsA(isA<AppFailure>()));
      await h.entered.future;
      h.memory.fail = 'remove';
      await expectLater(
        h.coordinator.cancelSignIn(),
        throwsA(isA<SecureStorageFailure>()),
      );
      h.succeed();
      await login;
      h.memory.fail = null;
      await h.coordinator.cancelSignIn();
      expect(h.storage.failed, false);
      expect(h.memory.values, isEmpty);
      expect(h.main.currentSession, isNull);
    },
  );
}
