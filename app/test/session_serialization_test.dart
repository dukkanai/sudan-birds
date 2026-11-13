import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:sudan_birds/secure_auth_storage.dart';
import 'package:sudan_birds/session_serialization.dart';
import 'secure_auth_storage_test.dart' show MemoryCredentials, MemoryFence;

const providerSession =
    '{"access_token":"synthetic-access",'
    '"refresh_token":"synthetic-refresh","user":{"id":"synthetic-user"},'
    '"provider_token":"synthetic-provider",'
    '"provider_refresh_token":"synthetic-provider-refresh"}';

void expectSanitized(String value) {
  final data = jsonDecode(value) as Map;
  expect(data['access_token'], 'synthetic-access');
  expect(data['refresh_token'], 'synthetic-refresh');
  expect(data['user'], {'id': 'synthetic-user'});
  expect(data.containsKey('provider_token'), false);
  expect(data.containsKey('provider_refresh_token'), false);
}

class PausedCredentials extends MemoryCredentials {
  final entered = Completer<void>();
  final release = Completer<void>();
  bool pauseWrite = false;
  bool paused = false;

  @override
  Future<String?> read(String key) async {
    if (!paused && !pauseWrite && key == SecureAuthStorage.sessionKey) {
      paused = true;
      entered.complete();
      await release.future;
    }
    return super.read(key);
  }

  @override
  Future<void> write(String key, String value) async {
    if (!paused && pauseWrite && key == SecureAuthStorage.sessionKey) {
      paused = true;
      entered.complete();
      await release.future;
    }
    await super.write(key, value);
  }
}

void main() {
  test('unknown session metadata remains unchanged', () {
    final input = jsonDecode(providerSession) as Map<String, dynamic>;
    input['future_sdk_field'] = {
      'nested': [true, 17, 'metadata'],
    };
    input['expires_in'] = 3600;
    input['token_type'] = 'bearer';
    final actual = jsonDecode(sanitizedSessionJson(jsonEncode(input)));
    input.remove('provider_token');
    input.remove('provider_refresh_token');
    expect(actual, input);
  });

  for (final pauseWrite in [false, true]) {
    test(
      'logout fences pending legacy ${pauseWrite ? 'rewrite' : 'read'}',
      () async {
        final memory = PausedCredentials()..pauseWrite = pauseWrite;
        memory.values[SecureAuthStorage.sessionKey] = providerSession;
        final storage = SecureAuthStorage(memory, fence: MemoryFence())
          ..acceptsSessions = true;
        addTearDown(storage.dispose);
        final reading = expectLater(
          storage.session.accessToken(),
          throwsA(isA<ObsoleteAuthFlow>()),
        );
        await memory.entered.future;
        final cleanup = storage.beginSignOut().then(
          (_) => storage.clearAfterSignOut(),
        );
        expect(storage.acceptsSessions, false);
        memory.release.complete();
        await reading;
        await cleanup;
        expect(memory.values[SecureAuthStorage.sessionKey], isNull);
        expect(await storage.session.accessToken(), isNull);
        if (!pauseWrite) {
          expect(memory.calls.where((c) => c == 'write'), isEmpty);
        }
      },
    );
  }

  test('quarantine during initialization cannot reopen restore', () async {
    final memory = PausedCredentials();
    memory.values[SecureAuthStorage.sessionKey] = providerSession;
    final storage = SecureAuthStorage(memory, fence: MemoryFence());
    addTearDown(storage.dispose);
    final restoring = expectLater(
      storage.initialize(),
      throwsA(isA<ObsoleteAuthFlow>()),
    );
    await memory.entered.future;
    storage.quarantine();
    memory.release.complete();
    await restoring;
    expect(storage.acceptsSessions, false);
    expect(memory.calls.where((c) => c == 'write'), isEmpty);
  });

  test('sanitizer preserves auth fields and is idempotent', () {
    final safe = sanitizedSessionJson(providerSession);
    expectSanitized(safe);
    expect(sanitizedSessionJson(safe), safe);
  });

  for (final bad in [
    'secret malformed',
    'null',
    '[]',
    '{}',
    '{"access_token":null}',
    '{"access_token":""}',
  ]) {
    test('invalid session fails closed without echoing input: $bad', () {
      expect(
        () => sanitizedSessionJson(bad),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'safe error',
            'Invalid stored session',
          ),
        ),
      );
    });
  }

  test('candidate and SDK event writes exclude provider fields', () async {
    final memory = MemoryCredentials();
    final storage = SecureAuthStorage(memory, fence: MemoryFence());
    addTearDown(storage.dispose);
    final generation = await storage.prepareSignIn();
    await storage.persistCandidate(generation, providerSession);
    storage.acceptCandidate(generation);
    expectSanitized(memory.values[SecureAuthStorage.sessionKey]!);
    await storage.session.persistSession(providerSession);
    expectSanitized(memory.values[SecureAuthStorage.sessionKey]!);
    expectSanitized((await storage.session.accessToken())!);
    const verifier = 'SYNTHETIC-RAW-PKCE';
    await storage
        .pkceFor(generation)
        .setItem(key: SecureAuthStorage.sdkPkceKey, value: verifier);
    expect(memory.values[SecureAuthStorage.pkceKey], verifier);
    expect(
      await storage
          .pkceFor(generation)
          .getItem(key: SecureAuthStorage.sdkPkceKey),
      verifier,
    );
  });

  test(
    'legacy restore removes provider fields durably before returning',
    () async {
      final memory = MemoryCredentials();
      memory.values[SecureAuthStorage.sessionKey] = providerSession;
      final storage = SecureAuthStorage(memory, fence: MemoryFence());
      addTearDown(storage.dispose);
      await storage.initialize();
      expectSanitized((await storage.session.accessToken())!);
      expectSanitized(memory.values[SecureAuthStorage.sessionKey]!);
    },
  );

  test('failed legacy rewrite blocks restore', () async {
    final memory = MemoryCredentials()..ignoreWrite = true;
    memory.values[SecureAuthStorage.sessionKey] = providerSession;
    final storage = SecureAuthStorage(memory, fence: MemoryFence());
    addTearDown(storage.dispose);
    await expectLater(
      storage.initialize(),
      throwsA(isA<SecureStorageFailure>()),
    );
    expect(storage.acceptsSessions, false);
    expect(await storage.session.accessToken(), isNull);
  });

  test('malformed stored session blocks initialization and restore', () async {
    final memory = MemoryCredentials();
    memory.values[SecureAuthStorage.sessionKey] = 'secret malformed';
    final storage = SecureAuthStorage(memory, fence: MemoryFence());
    addTearDown(storage.dispose);
    await expectLater(
      storage.initialize(),
      throwsA(isA<SecureStorageFailure>()),
    );
    expect(storage.acceptsSessions, false);
    expect(await storage.session.accessToken(), isNull);
  });

  test('malformed candidate never opens restore fence', () async {
    final memory = MemoryCredentials();
    final fence = MemoryFence();
    final storage = SecureAuthStorage(memory, fence: fence);
    addTearDown(storage.dispose);
    final generation = await storage.prepareSignIn();
    await expectLater(
      storage.persistCandidate(generation, 'secret malformed'),
      throwsA(isA<SecureStorageFailure>()),
    );
    expect(fence.allowed, false);
    expect(memory.values[SecureAuthStorage.sessionKey], isNull);
  });

  test('obsolete candidate cannot write provider credentials', () async {
    final memory = MemoryCredentials();
    final storage = SecureAuthStorage(memory, fence: MemoryFence());
    addTearDown(storage.dispose);
    final generation = await storage.prepareSignIn();
    storage.quarantine();
    await expectLater(
      storage.persistCandidate(generation, providerSession),
      throwsA(isA<ObsoleteAuthFlow>()),
    );
    expect(memory.values[SecureAuthStorage.sessionKey], isNull);
  });
}
