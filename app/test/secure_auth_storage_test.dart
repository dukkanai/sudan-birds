import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sudan_birds/app.dart';
import 'package:sudan_birds/auth_config.dart';
import 'package:sudan_birds/domain.dart';
import 'package:sudan_birds/repository.dart';
import 'package:sudan_birds/secure_auth_storage.dart';
import 'session_repository_test.dart' show session, a;

class MemoryCredentials implements CredentialStore {
  final values = <String, String>{};
  final calls = <String>[];
  String? fail;
  bool ignoreWrite = false, ignoreRemove = false;
  Completer<void>? pendingWrite;

  void check(String operation) {
    calls.add(operation);
    if (fail == operation) {
      throw PlatformException(
        code: 'locked',
        message: 'synthetic-secret-and-native-path',
      );
    }
  }

  @override
  Future<String?> read(String key) async {
    check('read');
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    check('write');
    if (pendingWrite != null) await pendingWrite!.future;
    if (!ignoreWrite) values[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    check('remove');
    if (!ignoreRemove) values.remove(key);
  }
}

class MemoryFence implements AuthRestoreFence {
  MemoryFence([this.allowed = true]);
  bool allowed;
  bool failRead = false, failWrite = false;
  @override
  Future<bool> mayRestore() async {
    if (failRead) throw StateError('synthetic native error');
    return allowed;
  }

  @override
  Future<void> setAllowed(bool allowed) async {
    if (failWrite) throw StateError('synthetic native error');
    this.allowed = allowed;
  }
}

SecureAuthStorage activeStorage(MemoryCredentials memory) =>
    SecureAuthStorage(memory, fence: MemoryFence())..acceptsSessions = true;

class CleanupRepository extends PreviewRepository {
  bool cleanupRequired = true;
  int cleanupCalls = 0;
  @override
  bool get sessionCleanupRequired => cleanupRequired;
  @override
  Future<Result<bool>> signOut() async {
    cleanupCalls++;
    cleanupRequired = false;
    return const Result.success(true);
  }
}

Matcher get safeStorageFailure => isA<SecureStorageFailure>()
    .having((e) => e.message, 'safe message', secureStorageMessage)
    .having(
      (e) => e.toString(),
      'safe exception',
      isNot(contains('synthetic')),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('session and PKCE use only separate secure keys', () async {
    final memory = MemoryCredentials();
    final storage = activeStorage(memory);
    addTearDown(storage.dispose);
    await storage.session.initialize();
    expect(await storage.session.hasAccessToken(), false);
    await storage.session.persistSession(
      '{"access_token":"synthetic-session"}',
    );
    await storage
        .pkceFor(storage.generation)
        .setItem(
          key: SecureAuthStorage.sdkPkceKey,
          value: 'synthetic-verifier',
        );
    expect(
      await storage.session.accessToken(),
      '{"access_token":"synthetic-session"}',
    );
    expect(await storage.session.hasAccessToken(), true);
    expect(
      await storage
          .pkceFor(storage.generation)
          .getItem(key: SecureAuthStorage.sdkPkceKey),
      'synthetic-verifier',
    );
    expect(memory.values.keys.toSet(), {
      SecureAuthStorage.sessionKey,
      SecureAuthStorage.pkceKey,
    });
    await storage
        .pkceFor(storage.generation)
        .removeItem(key: SecureAuthStorage.sdkPkceKey);
    await storage.session.removePersistedSession();
    expect(memory.values, isEmpty);
  });

  for (final operation in ['read', 'write', 'remove']) {
    test(
      '$operation failure invalidates storage without leaking secrets',
      () async {
        final memory = MemoryCredentials()..fail = operation;
        final storage = activeStorage(memory);
        addTearDown(storage.dispose);
        var notifications = 0;
        final subscription = storage.changes.listen((_) => notifications++);
        addTearDown(subscription.cancel);
        final Future<dynamic> attempt = switch (operation) {
          'read' => storage.initialize(),
          'write' => storage.session.persistSession(
            '{"access_token":"synthetic-session"}',
          ),
          _ => storage.session.removePersistedSession(),
        };
        await expectLater(attempt, throwsA(safeStorageFailure));
        expect(storage.failed, true);
        expect(notifications, greaterThan(0));
        final previousCalls = memory.calls.length;
        await expectLater(
          storage.session.persistSession('must-not-save'),
          throwsA(safeStorageFailure),
        );
        expect(memory.calls.length, previousCalls);
        await expectLater(storage.prepareSignIn(), throwsA(safeStorageFailure));
      },
    );
  }

  test('successful native return must verify write and removal', () async {
    for (final write in [true, false]) {
      final memory = MemoryCredentials()
        ..ignoreWrite = write
        ..ignoreRemove = !write;
      memory.values[SecureAuthStorage.sessionKey] = 'old-session';
      final storage = activeStorage(memory);
      addTearDown(storage.dispose);
      await expectLater(
        write
            ? storage.session.persistSession('{"access_token":"new-session"}')
            : storage.session.removePersistedSession(),
        throwsA(safeStorageFailure),
      );
      expect(storage.failed, true);
    }
  });

  test(
    'cleanup can recover a locked store only after verified deletion',
    () async {
      final memory = MemoryCredentials()..fail = 'remove';
      memory.values.addAll({
        SecureAuthStorage.sessionKey: 'session',
        SecureAuthStorage.pkceKey: 'verifier',
        'unrelated': 'preserve',
      });
      final storage = activeStorage(memory);
      addTearDown(storage.dispose);
      await storage.beginSignOut();
      await expectLater(
        storage.clearAfterSignOut(),
        throwsA(safeStorageFailure),
      );
      expect(storage.acceptsSessions, false);
      memory.fail = null;
      await storage.clearAfterSignOut();
      expect(storage.failed, false);
      expect(storage.acceptsSessions, false);
      expect(memory.values, {'unrelated': 'preserve'});
      await storage.session.persistSession('stale-auth-event');
      expect(memory.values, {'unrelated': 'preserve'});
      final generation = await storage.prepareSignIn();
      await storage.persistCandidate(
        generation,
        '{"access_token":"explicit-new-login"}',
      );
      storage.acceptCandidate(generation);
      expect(
        memory.values[SecureAuthStorage.sessionKey],
        '{"access_token":"explicit-new-login"}',
      );
    },
  );

  testWidgets(
    'timed-out native write cannot run after verified logout cleanup',
    (tester) async {
      final memory = MemoryCredentials()..pendingWrite = Completer<void>();
      final storage = activeStorage(memory);
      addTearDown(storage.dispose);
      final writing = expectLater(
        storage.session.persistSession(
          '{"access_token":"late-synthetic-session"}',
        ),
        throwsA(safeStorageFailure),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));
      await writing;
      final cleanup = storage.beginSignOut().then(
        (_) => storage.clearAfterSignOut(),
      );
      await tester.pump();
      expect(memory.calls.where((call) => call == 'remove'), isEmpty);
      memory.pendingWrite!.complete();
      await tester.pump();
      await cleanup;
      expect(memory.values, isEmpty);
      expect(storage.failed, false);
      expect(storage.acceptsSessions, false);
    },
  );

  test('SDK PKCE generation uses the injected secure adapter', () async {
    final memory = MemoryCredentials();
    final storage = activeStorage(memory);
    addTearDown(storage.dispose);
    final client = SupabaseClient(
      'https://example.test',
      'public-test-key',
      authOptions: AuthClientOptions(
        autoRefreshToken: false,
        authFlowType: AuthFlowType.pkce,
        pkceAsyncStorage: storage.pkceFor(storage.generation),
      ),
      httpClient: MockClient(
        (_) async => throw StateError('unexpected network'),
      ),
    );
    addTearDown(client.dispose);
    await client.auth.getOAuthSignInUrl(provider: OAuthProvider.google);
    expect(memory.values.keys, [SecureAuthStorage.pkceKey]);
    expect(memory.values[SecureAuthStorage.pkceKey], isNotEmpty);
    expect(
      () => storage
          .pkceFor(storage.generation)
          .setItem(key: 'unreviewed-key', value: 'value'),
      throwsA(safeStorageFailure),
    );
  });

  test(
    'SDK swallowed persistence errors still invalidate the repository',
    () async {
      final memory = MemoryCredentials();
      final storage = activeStorage(memory);
      addTearDown(storage.dispose);
      await Supabase.initialize(
        url: 'https://example.test',
        publishableKey: 'public-test-key',
        debug: false,
        httpClient: MockClient(
          (_) async => throw StateError('unexpected network'),
        ),
        authOptions: FlutterAuthClientOptions(
          autoRefreshToken: false,
          detectSessionInUri: false,
          localStorage: storage.session,
          pkceAsyncStorage: storage.pkce,
        ),
      );
      addTearDown(Supabase.instance.dispose);
      final repo = SupabaseBirdsRepository(
        Supabase.instance.client,
        authRedirect: '',
        authStorage: storage,
      );
      final failed = Completer<void>();
      final subscription = storage.changes.listen((_) {
        if (storage.failed && !failed.isCompleted) failed.complete();
      });
      addTearDown(subscription.cancel);
      memory.fail = 'write';
      await Supabase.instance.client.auth.recoverSession(
        jsonEncode(session(a)),
      );
      await failed.future.timeout(const Duration(seconds: 2));
      expect(Supabase.instance.client.auth.currentUser, isNotNull);
      expect(repo.signedIn, false);
      expect(repo.sessionCleanupRequired, true);
      expect(memory.values, isEmpty);
    },
  );

  test(
    'server signout failure still clears local secrets without claiming revocation',
    () async {
      final memory = MemoryCredentials();
      final storage = activeStorage(memory);
      addTearDown(storage.dispose);
      memory.values.addAll({
        SecureAuthStorage.sessionKey: 'session',
        SecureAuthStorage.pkceKey: 'verifier',
      });
      final client = SupabaseClient(
        'https://example.test',
        'public-test-key',
        authOptions: AuthClientOptions(
          autoRefreshToken: false,
          pkceAsyncStorage: storage.pkce,
        ),
        httpClient: MockClient(
          (_) async => http.Response('{"message":"unavailable"}', 503),
        ),
      );
      addTearDown(client.dispose);
      await client.auth.recoverSession(jsonEncode(session(a)));
      final repo = SupabaseBirdsRepository(
        client,
        authRedirect: '',
        authStorage: storage,
      );
      final result = await repo.signOut();
      expect(result.isSuccess, false);
      expect(result.failure!.message, contains('لا نؤكد إبطال جلسة الخادم'));
      expect(memory.values, isEmpty);
      expect(repo.signedIn, false);
      // The real SDK removes its in-memory session before server revocation.
      expect(client.auth.currentSession, isNull);
    },
  );

  test(
    'late SDK session after logout cannot be reauthorized by starting OAuth',
    () async {
      final memory = MemoryCredentials();
      final storage = activeStorage(memory);
      addTearDown(storage.dispose);
      final client = SupabaseClient(
        'https://example.test',
        'public-test-key',
        authOptions: AuthClientOptions(
          autoRefreshToken: false,
          pkceAsyncStorage: storage.pkce,
        ),
        httpClient: MockClient(
          (_) async => http.Response('{"message":"unavailable"}', 503),
        ),
      );
      addTearDown(client.dispose);
      await client.auth.recoverSession(jsonEncode(session(a)));
      final repo = SupabaseBirdsRepository(
        client,
        authRedirect: stagingAuthRedirect,
        authStorage: storage,
      );
      expect((await repo.signOut()).isSuccess, false);
      expect(client.auth.currentSession, isNull);
      expect(storage.failed, false);
      expect(storage.acceptsSessions, false);
      // Emulate an already-started OAuth callback arriving after logout cleanup.
      await client.auth.recoverSession(jsonEncode(session(a)));
      expect(client.auth.currentSession, isNotNull);
      expect(repo.sessionCleanupRequired, true);
      expect(repo.signedIn, false);
      final login = await repo.signIn('google');
      expect(login.failure, isA<SecureStorageFailure>());
      expect(storage.acceptsSessions, false);
      expect(repo.signedIn, false);
      expect(memory.values, isEmpty);
    },
  );

  test('repository rejects protected work after a storage failure', () async {
    final memory = MemoryCredentials()..fail = 'read';
    final storage = activeStorage(memory);
    addTearDown(storage.dispose);
    var requests = 0;
    final client = SupabaseClient(
      'https://example.test',
      'public-test-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((_) async {
        requests++;
        return http.Response('{}', 200);
      }),
    );
    addTearDown(client.dispose);
    await client.auth.recoverSession(jsonEncode(session(a)));
    final repo = SupabaseBirdsRepository(
      client,
      authRedirect: '',
      authStorage: storage,
    );
    final events = <void>[];
    final subscription = repo.authChanges.listen(events.add);
    addTearDown(subscription.cancel);
    await expectLater(storage.initialize(), throwsA(safeStorageFailure));
    await Future<void>.delayed(Duration.zero);
    expect(events, isNotEmpty);
    expect(repo.signedIn, false);
    expect(repo.currentUserId, isNull);
    expect(repo.sessionCleanupRequired, true);
    expect((await repo.profile()).isSuccess, false);
    expect(
      (await repo.feed(FeedKind.request, const FeedFilter())).isSuccess,
      false,
    );
    expect((await repo.signIn('google')).isSuccess, false);
    expect(requests, 0);
  });

  test(
    'failed logout removal remains uncertain until verified retry',
    () async {
      final memory = MemoryCredentials()..fail = 'remove';
      final storage = activeStorage(memory);
      addTearDown(storage.dispose);
      memory.values[SecureAuthStorage.sessionKey] =
          '{"access_token":"synthetic-session"}';
      final client = SupabaseClient(
        'https://example.test',
        'public-test-key',
        authOptions: AuthClientOptions(
          autoRefreshToken: false,
          pkceAsyncStorage: storage.pkce,
        ),
        httpClient: MockClient((_) async => http.Response('{}', 200)),
      );
      addTearDown(client.dispose);
      await client.auth.recoverSession(jsonEncode(session(a)));
      final repo = SupabaseBirdsRepository(
        client,
        authRedirect: '',
        authStorage: storage,
      );
      final result = await repo.signOut();
      expect(result.isSuccess, false);
      expect(result.failure!.outcomeUnknown, true);
      expect(repo.sessionCleanupRequired, true);
      expect(memory.values[SecureAuthStorage.sessionKey], isNotNull);
      memory.fail = null;
      expect((await repo.signOut()).isSuccess, true);
      expect(repo.sessionCleanupRequired, false);
      expect(memory.values, isEmpty);
    },
  );

  testWidgets('uncertain logout keeps a visible local cleanup action', (
    tester,
  ) async {
    final repo = CleanupRepository();
    await tester.pumpWidget(BirdsApp(repository: repo));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('الحساب والإعدادات'));
    await tester.pumpAndSettle();
    expect(find.text('إعادة مسح الجلسة المحلية'), findsOneWidget);
    expect(find.text('الدخول باستخدام Google'), findsNothing);
    await tester.tap(find.text('إعادة مسح الجلسة المحلية'));
    await tester.pumpAndSettle();
    expect(repo.sessionCleanupRequired, false);
    expect(repo.cleanupCalls, 1);
  });

  test(
    'native options are device-bound, scoped and do not reset on errors',
    () {
      final native = NativeCredentialStore('staging.example.test').storage;
      expect(
        native.iOptions.toMap()['accessibility'],
        'first_unlock_this_device',
      );
      expect(native.iOptions.toMap()['synchronizable'], 'false');
      expect(native.iOptions.toMap()['groupId'], isNull);
      expect(native.aOptions.toMap()['resetOnError'], 'false');
      expect(native.aOptions.toMap()['migrateOnAlgorithmChange'], 'false');
      expect(native.aOptions.toMap()['migrateWithBackup'], 'false');
      expect(
        native.aOptions.toMap()['storageNamespace'],
        'sudan_birds_auth_v1_staging.example.test',
      );
    },
  );

  test(
    'non-mobile backend is rejected instead of using web or preferences',
    () {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        expect(
          () => NativeCredentialStore('example.test').read('key'),
          throwsA(safeStorageFailure),
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  test('main config injects both adapters and minimal iOS entitlement', () {
    final main = File('lib/main.dart').readAsStringSync();
    expect(main, contains('localStorage: authStorage.session'));
    expect(main, contains('pkceAsyncStorage: authStorage.pkce'));
    final source = File('lib/secure_auth_storage.dart').readAsStringSync();
    expect(source, isNot(contains('SharedPreferences')));
    expect(source, isNot(contains('deleteAll')));
    final entitlement = File(
      'ios/Runner/Runner.entitlements',
    ).readAsStringSync();
    expect(
      entitlement,
      contains(r'$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)'),
    );
    expect(RegExp('<string>').allMatches(entitlement).length, 1);
    expect(
      entitlement,
      isNot(contains('com.apple.security.application-groups')),
    );
    final project = File(
      'ios/Runner.xcodeproj/project.pbxproj',
    ).readAsStringSync();
    expect(
      RegExp(
        'CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements;',
      ).allMatches(project).length,
      3,
    );
  });
}
