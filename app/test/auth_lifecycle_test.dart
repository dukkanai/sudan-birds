import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sudan_birds/auth_config.dart';
import 'package:sudan_birds/mobile_oauth.dart';
import 'package:sudan_birds/repository.dart';
import 'package:sudan_birds/secure_auth_storage.dart';
import 'secure_auth_storage_test.dart' show MemoryCredentials, MemoryFence;
import 'session_repository_test.dart' show a, b, session;

Future<void> until(bool Function() ready) async {
  for (var i = 0; i < 100; i++) {
    if (ready()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('Synthetic operation did not reach its expected boundary');
}

class Harness {
  Harness({
    OAuthLauncher? launch,
    Future<void> Function(String)? install,
    Duration exchangeTimeout = const Duration(seconds: 20),
  }) {
    storage = SecureAuthStorage(memory, fence: fence);
    main = SupabaseClient(
      'https://example.test',
      'public-test-key',
      authOptions: AuthClientOptions(
        autoRefreshToken: false,
        pkceAsyncStorage: storage.pkce,
      ),
      httpClient: MockClient((_) async {
        logoutCalls++;
        return http.Response('{}', 200);
      }),
    );
    oauth = MobileOAuthCoordinator(
      mainAuth: main.auth,
      storage: storage,
      notice: notices.add,
      launch:
          launch ??
          (client, provider, redirect) async {
            await client.getOAuthSignInUrl(
              provider: provider,
              redirectTo: redirect,
            );
            return true;
          },
      install: install,
      exchangeTimeout: exchangeTimeout,
      createClient: (pkce) => GoTrueClient(
        url: 'https://example.test/auth/v1',
        autoRefreshToken: false,
        flowType: AuthFlowType.pkce,
        asyncStorage: pkce,
        httpClient: MockClient((request) async {
          final code = (jsonDecode(request.body) as Map)['auth_code'] as String;
          requests[code] = Completer<http.Response>();
          return requests[code]!.future;
        }),
      ),
    );
    repo = SupabaseBirdsRepository(
      main,
      authRedirect: stagingAuthRedirect,
      authStorage: storage,
      oauth: oauth,
      oauthEnabled: true,
    );
  }
  final memory = MemoryCredentials();
  final fence = MemoryFence(false);
  final notices = <String>[];
  final requests = <String, Completer<http.Response>>{};
  late final SecureAuthStorage storage;
  late final SupabaseClient main;
  late final MobileOAuthCoordinator oauth;
  late final SupabaseBirdsRepository repo;
  int logoutCalls = 0;
  Future<void> start() async {
    expect((await repo.signIn('google')).isSuccess, true);
  }

  Future<void> callback(String code) =>
      oauth.handleCallback(Uri.parse('$stagingAuthRedirect?code=$code'));
  void complete(String code, String account) {
    requests[code]!.complete(
      http.Response(
        jsonEncode({
          ...session(account),
          'provider_token': 'synthetic-provider-access',
          'provider_refresh_token': 'synthetic-provider-refresh',
        }),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
  }

  Future<void> dispose() async {
    await oauth.dispose();
    await main.dispose();
    await storage.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'winning OAuth strips provider credentials before install and storage',
    () async {
      String? installed;
      final h = Harness(
        install: (value) async {
          installed = value;
        },
      );
      addTearDown(h.dispose);
      await h.start();
      final callback = h.callback('provider-hygiene');
      await until(() => h.requests.containsKey('provider-hygiene'));
      h.complete('provider-hygiene', a);
      await callback;
      final saved = h.memory.values[SecureAuthStorage.sessionKey];
      expect(saved, isNotNull);
      expect(installed, saved);
      final data = jsonDecode(saved!) as Map;
      expect(data.containsKey('provider_token'), false);
      expect(data.containsKey('provider_refresh_token'), false);
      final restored = Session.fromJson(Map<String, dynamic>.from(data));
      expect(restored, isNotNull);
      expect(restored!.user.id, a);
      expect(restored.accessToken, isNotEmpty);
      expect(data['refresh_token'], session(a)['refresh_token']);
    },
  );

  test('failed secret deletion stays blocked across process restart', () async {
    final memory = MemoryCredentials();
    final fence = MemoryFence();
    memory.values[SecureAuthStorage.sessionKey] = jsonEncode(session(a));
    final first = SecureAuthStorage(memory, fence: fence);
    await first.initialize();
    expect(await first.session.hasAccessToken(), true);
    await first.beginSignOut();
    memory.fail = 'remove';
    await expectLater(
      first.clearAfterSignOut(),
      throwsA(isA<SecureStorageFailure>()),
    );
    expect(fence.allowed, false);
    expect(memory.values[SecureAuthStorage.sessionKey], isNotNull);
    await first.dispose();

    // A new object/process has no RAM quarantine, yet cannot expose old keys.
    final locked = SecureAuthStorage(memory, fence: fence);
    await expectLater(
      locked.initialize(),
      throwsA(isA<SecureStorageFailure>()),
    );
    expect(await locked.session.accessToken(), null);
    await locked.dispose();
    memory.fail = null;
    final recovered = SecureAuthStorage(memory, fence: fence);
    await recovered.initialize();
    expect(await recovered.session.accessToken(), null);
    expect(memory.values, isEmpty);
    expect(recovered.acceptsSessions, false);
    await recovered.dispose();
  });

  test(
    'missing fence discards reinstall/legacy keys, unreadable fence reads no secrets',
    () async {
      for (final unreadable in [false, true]) {
        final memory = MemoryCredentials();
        memory.values[SecureAuthStorage.sessionKey] = 'must-not-restore';
        final fence = MemoryFence(false)..failRead = unreadable;
        final storage = SecureAuthStorage(memory, fence: fence);
        if (unreadable) {
          await expectLater(
            storage.initialize(),
            throwsA(isA<SecureStorageFailure>()),
          );
          expect(memory.calls, isEmpty);
        } else {
          await storage.initialize();
          expect(memory.values, isEmpty);
        }
        expect(await storage.session.accessToken(), null);
        await storage.dispose();
      }
    },
  );

  test(
    'fence write failure aborts logout before SDK, network or secret removal',
    () async {
      final h = Harness();
      addTearDown(h.dispose);
      await h.main.auth.setInitialSession(jsonEncode(session(a)));
      h.memory.values[SecureAuthStorage.sessionKey] = jsonEncode(session(a));
      h.fence.allowed = true;
      h.fence.failWrite = true;
      final result = await h.repo.signOut();
      expect(result.failure, isA<SecureStorageFailure>());
      expect(h.logoutCalls, 0);
      expect(h.memory.calls, isEmpty);
      expect(
        h.main.auth.currentUser!.id,
        a,
      ); // SDK unchanged, repository quarantined.
      expect(h.repo.currentUserId, null);
      expect(h.repo.sessionCleanupRequired, true);
      expect((await h.repo.signIn('google')).isSuccess, false);
      h.fence.failWrite = false;
      expect((await h.repo.signOut()).isSuccess, true);
      expect(h.fence.allowed, false);
      expect(h.memory.values, isEmpty);
    },
  );

  test(
    'duplicate logout callers both receive the original cleanup failure',
    () async {
      final h = Harness();
      addTearDown(h.dispose);
      h.fence.failWrite = true;
      final first = h.repo.signOut();
      final second = h.repo.signOut();
      expect((await first).failure, isA<SecureStorageFailure>());
      expect((await second).failure, isA<SecureStorageFailure>());
      expect(h.logoutCalls, 0);
    },
  );

  test(
    'old real PKCE HTTP response after logout and new login cannot remove new verifier or install identity',
    () async {
      final h = Harness();
      addTearDown(h.dispose);
      await h.start();
      final old = h.callback('old');
      await until(() => h.requests.containsKey('old'));
      expect((await h.repo.signOut()).isSuccess, true);
      await h.start();
      final verifier = h.memory.values[SecureAuthStorage.pkceKey];
      h.complete('old', a);
      await old;
      expect(h.main.auth.currentSession, null);
      expect(h.repo.currentUserId, null);
      expect(h.memory.values[SecureAuthStorage.pkceKey], verifier);
      expect(h.memory.values[SecureAuthStorage.sessionKey], null);
      expect(h.storage.failed, false);
      final current = h.callback('current');
      await until(() => h.requests.containsKey('current'));
      h.complete('current', b);
      await current;
      expect(h.repo.currentUserId, b);
      expect(h.fence.allowed, true);
      expect(
        jsonDecode(
          h.memory.values[SecureAuthStorage.sessionKey]!,
        )['user']['id'],
        b,
      );
    },
  );

  test(
    'replacement login without logout also fences old HTTP results',
    () async {
      final h = Harness();
      addTearDown(h.dispose);
      await h.start();
      final old = h.callback('old');
      await until(() => h.requests.containsKey('old'));
      await h.start();
      final newer = h.callback('new');
      await until(() => h.requests.containsKey('new'));
      h.complete('new', b);
      await newer;
      h.complete('old', a);
      await old;
      expect(h.repo.currentUserId, b);
      expect(
        jsonDecode(
          h.memory.values[SecureAuthStorage.sessionKey]!,
        )['user']['id'],
        b,
      );
    },
  );

  test('main SDK cannot consume or remove an isolated flow verifier', () async {
    final h = Harness();
    addTearDown(h.dispose);
    await h.start();
    final verifier = h.memory.values[SecureAuthStorage.pkceKey];
    await h.storage.pkce.removeItem(key: SecureAuthStorage.sdkPkceKey);
    expect(h.memory.values[SecureAuthStorage.pkceKey], verifier);
    await expectLater(
      h.storage.pkce.getItem(key: SecureAuthStorage.sdkPkceKey),
      throwsA(isA<ObsoleteAuthFlow>()),
    );
    expect(h.storage.failed, false);
  });

  test(
    'duplicate callback exchanges once and successful repeat is silent',
    () async {
      final h = Harness();
      addTearDown(h.dispose);
      await h.start();
      final first = h.callback('once');
      await until(() => h.requests.containsKey('once'));
      await h.callback('once');
      expect(h.requests.length, 1);
      h.complete('once', a);
      await first;
      await h.callback('once');
      expect(h.notices, isEmpty);
      expect(h.repo.currentUserId, a);
    },
  );

  test('cold return never infers a flow from persisted verifier', () async {
    final h = Harness();
    addTearDown(h.dispose);
    h.memory.values[SecureAuthStorage.pkceKey] = 'surviving-verifier';
    await h.storage.initialize();
    await h.callback('cold');
    expect(h.requests, isEmpty);
    expect(h.memory.values, isEmpty);
    expect(h.repo.currentUserId, null);
    expect(h.notices, [oauthRestartMessage]);
  });

  for (final throws in [false, true]) {
    test(
      'browser launch ${throws ? 'exception' : 'denial'} clears verifier and never authenticates',
      () async {
        final h = Harness(
          launch: (client, provider, redirect) async {
            await client.getOAuthSignInUrl(
              provider: provider,
              redirectTo: redirect,
            );
            if (throws) {
              throw StateError('synthetic sensitive native exception');
            }
            return false;
          },
        );
        addTearDown(h.dispose);
        expect((await h.repo.signIn('google')).isSuccess, false);
        expect(h.memory.values, isEmpty);
        expect(h.fence.allowed, false);
        expect(h.repo.currentUserId, null);
        expect(h.requests, isEmpty);
      },
    );
  }

  test(
    'callback waits for pending browser launch, denied launch never exchanges',
    () async {
      final launch = Completer<bool>();
      final h = Harness(
        launch: (client, provider, redirect) async {
          await client.getOAuthSignInUrl(
            provider: provider,
            redirectTo: redirect,
          );
          return launch.future;
        },
      );
      addTearDown(h.dispose);
      final opening = h.repo.signIn('google');
      await until(() => h.memory.values.containsKey(SecureAuthStorage.pkceKey));
      final callback = h.callback('premature');
      launch.complete(false);
      expect((await opening).isSuccess, false);
      await callback;
      expect(h.requests, isEmpty);
      expect(h.memory.values, isEmpty);
    },
  );

  test(
    'logout while candidate persistence waits cannot publish or restore identity',
    () async {
      final h = Harness();
      addTearDown(h.dispose);
      await h.start();
      h.memory.pendingWrite = Completer<void>();
      final callback = h.callback('pending-save');
      await until(() => h.requests.containsKey('pending-save'));
      final priorWrites = h.memory.calls.where((v) => v == 'write').length;
      h.complete('pending-save', a);
      await until(
        () => h.memory.calls.where((v) => v == 'write').length > priorWrites,
      );
      final logout = h.repo.signOut();
      expect(h.repo.currentUserId, null);
      expect((await h.repo.signIn('google')).isSuccess, false);
      h.memory.pendingWrite!.complete();
      await callback;
      expect((await logout).isSuccess, true);
      expect(h.main.auth.currentSession, null);
      expect(h.memory.values, isEmpty);
      expect(h.fence.allowed, false);
    },
  );

  test(
    'delayed main installation serializes logout, rejects newer login, then clears installed SDK identity',
    () async {
      final installEntered = Completer<void>();
      final releaseInstall = Completer<void>();
      late Harness h;
      h = Harness(
        install: (value) async {
          installEntered.complete();
          await releaseInstall.future;
          await h.main.auth.setInitialSession(value);
        },
      );
      addTearDown(h.dispose);
      await h.start();
      final callback = h.callback('installing');
      await until(() => h.requests.containsKey('installing'));
      h.complete('installing', a);
      await installEntered.future;
      expect((await h.repo.signIn('google')).isSuccess, false);
      final logout = h.repo.signOut();
      expect(h.repo.currentUserId, null);
      expect((await h.repo.signIn('apple')).isSuccess, false);
      releaseInstall.complete();
      await callback;
      expect((await logout).isSuccess, true);
      expect(h.main.auth.currentSession, null);
      expect(h.repo.currentUserId, null);
      expect(h.memory.values, isEmpty);
      expect(h.fence.allowed, false);
      await h.start();
    },
  );

  test(
    'old response during newer install cannot release installation guard',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      late Harness h;
      h = Harness(
        install: (value) async {
          entered.complete();
          await release.future;
          await h.main.auth.setInitialSession(value);
        },
      );
      addTearDown(h.dispose);
      await h.start();
      final old = h.callback('old');
      await until(() => h.requests.containsKey('old'));
      await h.start();
      final newer = h.callback('new');
      await until(() => h.requests.containsKey('new'));
      h.complete('new', b);
      await entered.future;
      h.complete('old', a);
      await old;
      expect((await h.repo.signIn('google')).isSuccess, false);
      release.complete();
      await newer;
      expect(h.repo.currentUserId, b);
    },
  );

  test(
    'timed-out exchange remains fenced when HTTP eventually succeeds',
    () async {
      final h = Harness(exchangeTimeout: const Duration(milliseconds: 30));
      addTearDown(h.dispose);
      await h.start();
      final callback = h.callback('timeout');
      await until(() => h.requests.containsKey('timeout'));
      await callback;
      expect(h.repo.currentUserId, null);
      expect(h.notices, [oauthRetryMessage]);
      expect(h.fence.allowed, false);
      await h.start();
      final verifier = h.memory.values[SecureAuthStorage.pkceKey];
      h.complete('timeout', a);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(h.main.auth.currentSession, null);
      expect(h.memory.values[SecureAuthStorage.pkceKey], verifier);
      expect(h.storage.failed, false);
    },
  );

  test('disposal during exchange never installs its result', () async {
    final h = Harness();
    addTearDown(h.dispose);
    await h.start();
    final callback = h.callback('dispose');
    await until(() => h.requests.containsKey('dispose'));
    await h.oauth.dispose();
    h.complete('dispose', a);
    await callback;
    expect(h.main.auth.currentSession, null);
    expect(h.repo.currentUserId, null);
  });

  test(
    'native fence channel rejects failed writes, missing/malformed marker blocks restore',
    () async {
      final calls = <MethodCall>[];
      Object? response;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(NativeAuthRestoreFence.channel, (
        call,
      ) async {
        calls.add(call);
        return response;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          NativeAuthRestoreFence.channel,
          null,
        ),
      );
      final fence = NativeAuthRestoreFence('example.test');
      expect(await fence.mayRestore(), false);
      response = false;
      await expectLater(
        fence.setAllowed(false),
        throwsA(isA<SecureStorageFailure>()),
      );
      response = true;
      await fence.setAllowed(true);
      expect(await fence.mayRestore(), true);
      expect(
        calls.every(
          (call) => (call.arguments as Map)['project'] == 'example.test',
        ),
        true,
      );
      expect(
        calls.every(
          (call) => (call.arguments as Map).keys.every(
            (key) => ['project', 'allowed'].contains(key),
          ),
        ),
        true,
      );
    },
  );

  test(
    'native fence source is nonsecret, synchronized and backup-excluded; no outer initialization timeout',
    () {
      final android = File(
        'android/app/src/main/kotlin/dev/sudanbirds/sudan_birds/MainActivity.kt',
      ).readAsStringSync();
      final ios = File('ios/Runner/AppDelegate.swift').readAsStringSync();
      final main = File('lib/main.dart').readAsStringSync();
      expect(android, contains('.commit()'));
      expect(android, contains('prefs.all[project] == true'));
      expect(ios, contains('isExcludedFromBackup = true'));
      expect(ios, contains('.atomic'));
      expect(ios, contains('handle.synchronize()'));
      expect(ios, contains('data == Data("allow-v1".utf8)'));
      expect(main, contains('detectSessionInUri: false'));
      expect(main, contains('timeout: null'));
    },
  );
}
