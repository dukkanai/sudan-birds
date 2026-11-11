import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sudan_birds/secure_auth_storage.dart';

import '../test/support/native_storage_checks.dart';

// Never use a real project host or a real login/session/verifier here. No app
// main(), Supabase client, provider, HTTP transport or channel mock is started.
const _scope = 'native-storage-smoke.invalid';
const _otherScope = 'native-storage-other.invalid';
const _missingScope = 'native-storage-missing.invalid';
const _fixture = 'SYNTHETIC-NON-LOGIN-STORAGE-FIXTURE';
const _updatedFixture = 'SYNTHETIC-NON-LOGIN-UPDATED-FIXTURE';
const _verifier = 'SYNTHETIC-NON-PKCE-FIXTURE';

// Attempt every exact-key cleanup even after an earlier failure. Never deleteAll
// or touch the production project scope. A failed cleanup fails the test.
Future<void> _cleanup() async {
  var clean = true;
  for (final scope in [_scope, _otherScope, _missingScope]) {
    final store = NativeCredentialStore(scope);
    if (scope != _missingScope) {
      try {
        final fence = NativeAuthRestoreFence(scope);
        await fence.setAllowed(false);
        if (await fence.mayRestore()) clean = false;
      } catch (_) {
        clean = false;
      }
    }
    for (final key in [
      SecureAuthStorage.sessionKey,
      SecureAuthStorage.pkceKey,
    ]) {
      try {
        await store.remove(key);
        if (await store.read(key) != null) clean = false;
      } catch (_) {
        clean = false;
      }
    }
  }
  checkNativeStorage(clean, 'Exact test-key cleanup and restore block');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('real native storage and restore fence smoke', (tester) async {
    checkNativeStorage(
      const bool.fromEnvironment('NATIVE_STORAGE_SMOKE'),
      'Explicit disposable native test opt-in required',
    );
    checkNativeStorage(Platform.isAndroid || Platform.isIOS, 'Android or iOS required');
    addTearDown(_cleanup);
    await guardNativeStorage('Initial cleanup', _cleanup);

    final store = NativeCredentialStore(_scope);
    final fence = NativeAuthRestoreFence(_scope);
    final owners = <SecureAuthStorage>[];
    addTearDown(() async {
      var closed = true;
      for (final owner in owners) {
        try {
          await owner.dispose();
        } catch (_) {
          closed = false;
        }
      }
      checkNativeStorage(closed, 'Adapter disposal');
    });

    await guardNativeStorage('Credential operations and namespace isolation', () async {
      checkNativeStorage(await store.read(SecureAuthStorage.sessionKey) == null, 'Empty');
      await store.write(SecureAuthStorage.sessionKey, _fixture);
      checkNativeStorage(
        await NativeCredentialStore(
              _scope,
            ).read(SecureAuthStorage.sessionKey) ==
            _fixture,
        'Fresh credential adapter readback',
      );
      checkNativeStorage(
        await NativeCredentialStore(
              _otherScope,
            ).read(SecureAuthStorage.sessionKey) ==
            null,
        'Separate namespace remains empty',
      );
      await store.remove(SecureAuthStorage.sessionKey);
      checkNativeStorage(
        await store.read(SecureAuthStorage.sessionKey) == null,
        'Deletion',
      );
    });

    await guardNativeStorage(
      'Native fence read/write and malformed request rejection',
      () async {
        checkNativeStorage(
          !await NativeAuthRestoreFence(_missingScope).mayRestore(),
          'Never-written scope denies restore',
        );
        await fence.setAllowed(true);
        checkNativeStorage(
          await NativeAuthRestoreFence(_scope).mayRestore(),
          'Fresh fence adapter readback',
        );
        await fence.setAllowed(false);
        var rejected = false;
        try {
          await NativeAuthRestoreFence.channel.invokeMethod<bool>('write', {
            'project': _scope,
            'allowed': 'NOT-A-BOOLEAN',
          });
        } on PlatformException {
          rejected = true;
        }
        checkNativeStorage(rejected, 'Malformed write rejected');
        checkNativeStorage(
          !await fence.mayRestore(),
          'Malformed write cannot enable restore',
        );
      },
    );

    await guardNativeStorage('Missing fence clears stale synthetic values', () async {
      final missingStore = NativeCredentialStore(_missingScope);
      await missingStore.write(SecureAuthStorage.sessionKey, _fixture);
      await missingStore.write(SecureAuthStorage.pkceKey, _verifier);
      final blocked = SecureAuthStorage(
        missingStore,
        fence: NativeAuthRestoreFence(_missingScope),
      );
      owners.add(blocked);
      await blocked.session.initialize();
      checkNativeStorage(!blocked.acceptsSessions && !blocked.failed, 'Blocked startup');
      checkNativeStorage(
        await blocked.session.accessToken() == null,
        'No restored session',
      );
      for (final key in [
        SecureAuthStorage.sessionKey,
        SecureAuthStorage.pkceKey,
      ]) {
        checkNativeStorage(await missingStore.read(key) == null, 'Stale key removed');
      }
    });

    await guardNativeStorage('Session/PKCE adapters, fresh instances and logout fence', () async {
      final first = SecureAuthStorage(store, fence: fence);
      owners.add(first);
      await first.session.initialize();
      final generation = await first.prepareSignIn();
      final pkce = first.pkceFor(generation);
      await pkce.setItem(key: SecureAuthStorage.sdkPkceKey, value: _verifier);
      checkNativeStorage(
        await pkce.getItem(key: SecureAuthStorage.sdkPkceKey) == _verifier,
        'Flow verifier readback',
      );
      // Storage-only synthetic candidate: no SDK parsing or identity validation
      // is claimed. Real app callers validate OAuth results before this method.
      await first.persistCandidate(generation, _fixture);
      first.acceptCandidate(generation);
      await first.session.persistSession(_updatedFixture);
      checkNativeStorage(
        await first.session.accessToken() == _updatedFixture,
        'Session adapter write/read',
      );

      final fresh = SecureAuthStorage(
        NativeCredentialStore(_scope),
        fence: NativeAuthRestoreFence(_scope),
      );
      owners.add(fresh);
      await fresh.session.initialize();
      checkNativeStorage(
        await fresh.session.accessToken() == _updatedFixture,
        'Fresh owner restores allowed synthetic value',
      );
      checkNativeStorage(
        await store.read(SecureAuthStorage.pkceKey) == null,
        'Orphan cleared',
      );
      await fresh.beginSignOut();
      checkNativeStorage(!await fence.mayRestore(), 'Logout persisted restore block');
      // Leave the synthetic session on disk deliberately, then construct a new
      // owner: this is object recreation, NOT process death or a device restart.
      checkNativeStorage(
        await store.read(SecureAuthStorage.sessionKey) == _updatedFixture,
        'Fixture exists before blocked startup',
      );
      final afterBlock = SecureAuthStorage(
        NativeCredentialStore(_scope),
        fence: NativeAuthRestoreFence(_scope),
      );
      owners.add(afterBlock);
      await afterBlock.session.initialize();
      checkNativeStorage(await afterBlock.session.accessToken() == null, 'Restore denied');
      checkNativeStorage(await store.read(SecureAuthStorage.sessionKey) == null, 'Cleared');
      checkNativeStorage(!afterBlock.failed, 'Cleanup succeeded');
      await afterBlock.clearAfterSignOut();
    });
  });
}
