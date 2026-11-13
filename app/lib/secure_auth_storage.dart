import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'domain.dart';
import 'local_diagnostics.dart';
import 'session_serialization.dart';

const secureStorageMessage =
    'تعذر تأكيد حفظ أو مسح بيانات الدخول في التخزين الآمن. أُوقفت إجراءات الحساب. افتح قفل الجهاز وأعد مسح الجلسة من زر الحساب قبل تسجيل الدخول مجدداً.';

class SecureStorageFailure extends AppFailure implements Exception {
  const SecureStorageFailure()
    : super(secureStorageMessage, outcomeUnknown: true);

  @override
  String toString() => 'Secure credential storage unavailable';
}

abstract interface class CredentialStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> remove(String key);
}

/// Only the mobile secure backends are supported. No web/preferences fallback.
class NativeCredentialStore implements CredentialStore {
  NativeCredentialStore(String projectHost)
    : storage = FlutterSecureStorage(
        aOptions: AndroidOptions(
          storageNamespace: 'sudan_birds_auth_v1_$projectHost',
          resetOnError: false,
          migrateOnAlgorithmChange: false,
        ),
        iOptions: IOSOptions(
          accountName: 'sudan_birds_auth_v1_$projectHost',
          accessibility: KeychainAccessibility.first_unlock_this_device,
          synchronizable: false,
        ),
      );

  @visibleForTesting
  final FlutterSecureStorage storage;

  void _requireMobile() {
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.android &&
            defaultTargetPlatform != TargetPlatform.iOS)) {
      throw const SecureStorageFailure();
    }
  }

  @override
  Future<String?> read(String key) {
    _requireMobile();
    return storage.read(key: key);
  }

  @override
  Future<void> write(String key, String value) {
    _requireMobile();
    return storage.write(key: key, value: value);
  }

  @override
  Future<void> remove(String key) {
    _requireMobile();
    return storage.delete(key: key);
  }
}

/// Nonsecret, app-private restore permission. Missing or malformed state blocks
/// restoration. No credentials ever cross this channel or enter this file.
abstract interface class AuthRestoreFence {
  Future<bool> mayRestore();
  Future<void> setAllowed(bool allowed);
}

class NativeAuthRestoreFence implements AuthRestoreFence {
  NativeAuthRestoreFence(this.projectHost);
  final String projectHost;
  static const channel = MethodChannel('sudan_birds/auth_restore_fence');

  @override
  Future<bool> mayRestore() async =>
      await channel.invokeMethod<bool>('read', {'project': projectHost}) ==
      true;

  @override
  Future<void> setAllowed(bool allowed) async {
    final saved = await channel.invokeMethod<bool>('write', {
      'project': projectHost,
      'allowed': allowed,
    });
    if (saved != true) throw const SecureStorageFailure();
  }
}

class ObsoleteAuthFlow implements Exception {
  const ObsoleteAuthFlow();
}

/// The SDK persists Auth events without awaiting them. Keep operations ordered,
/// publish storage failures independently, and explicitly verify logout cleanup.
/// A caller timeout never unlocks the queue while native work is still pending.
class SecureAuthStorage {
  SecureAuthStorage(this.store, {required this.fence});

  final CredentialStore store;
  final AuthRestoreFence fence;
  static const sessionKey = 'session-v1';
  static const pkceKey = 'pkce-v1';
  static const sdkPkceKey = 'supabase.auth.token-code-verifier';
  final _changes = StreamController<void>.broadcast(sync: true);
  Stream<void> get changes => _changes.stream;
  Future<void> _tail = Future.value();
  bool failed = false;
  bool acceptsSessions = false;
  int _generation = 0;
  int get generation => _generation;
  late final LocalStorage session = _SecureSessionStorage(this);
  // Main SDK owns no verifier. Its adapter never reads, writes or removes a
  // live flow verifier; explicit app cleanup handles both secure keys.
  late final GotrueAsyncStorage pkce = _SecurePkceStorage(this, null);
  GotrueAsyncStorage pkceFor(int generation) =>
      _SecurePkceStorage(this, generation);

  void requireAvailable() {
    if (failed) throw const SecureStorageFailure();
  }

  void requireGeneration(int generation) {
    if (generation != _generation) throw const ObsoleteAuthFlow();
    requireAvailable();
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<T> _run<T>(Future<T> Function() action, {bool cleanup = false}) async {
    final operation = _tail.then((_) {
      if (!cleanup) requireAvailable();
      return action();
    });
    _tail = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    try {
      return await operation.timeout(const Duration(seconds: 5));
    } on ObsoleteAuthFlow {
      rethrow;
    } catch (_) {
      localDiagnostics.record(
        FailureBoundary.secureStorage,
        FailureCode.storageUnavailable,
        outcomeUnknown: true,
      );
      failed = true;
      acceptsSessions = false;
      _notify();
      throw const SecureStorageFailure();
    }
  }

  Future<void> initialize() async {
    final generation = _generation;
    // Must precede ANY secret read or SDK restore, including after reinstall.
    final allowed = await _run(fence.mayRestore);
    requireGeneration(generation);
    if (!allowed) {
      await clearAfterSignOut();
    } else {
      await _readSession();
      requireGeneration(generation);
      // A verifier cannot be resumed without its live, isolated flow client.
      await _remove(pkceKey);
      requireGeneration(generation);
      acceptsSessions = true;
    }
  }

  Future<String?> _readSession() {
    final generation = _generation;
    return _run(() async {
      requireGeneration(generation);
      final value = await store.read(sessionKey);
      requireGeneration(generation);
      if (value == null) return null;
      final sanitized = sanitizedSessionJson(value);
      if (sanitized != value) {
        requireGeneration(generation);
        await store.write(sessionKey, sanitized);
        requireGeneration(generation);
        final persisted = await store.read(sessionKey);
        requireGeneration(generation);
        if (persisted != sanitized) {
          throw const SecureStorageFailure();
        }
      }
      requireGeneration(generation);
      return sanitized;
    });
  }

  Future<void> _writeSession(String value) {
    final generation = _generation;
    return _run(() async {
      if (!acceptsSessions || generation != _generation) return;
      final sanitized = sanitizedSessionJson(value);
      await store.write(sessionKey, sanitized);
      if (await store.read(sessionKey) != sanitized) {
        throw const SecureStorageFailure();
      }
    });
  }

  Future<void> _remove(String key) => _run(() async {
    await store.remove(key);
    if (await store.read(key) != null) throw const SecureStorageFailure();
  }, cleanup: true);

  /// Invalidates in-flight work synchronously, even while native work is pending.
  void quarantine() {
    acceptsSessions = false;
    _generation++;
    _notify();
  }

  /// Must finish BEFORE SDK logout or deleting secrets. If it fails, no claim of
  /// durable logout is possible and the caller must not perform those effects.
  Future<void> beginSignOut() async {
    quarantine();
    await _run(() => fence.setAllowed(false), cleanup: true);
  }

  Future<void> clearAfterSignOut() async {
    await _remove(sessionKey);
    await _remove(pkceKey);
    failed = false;
    _notify();
  }

  Future<int> prepareSignIn() async {
    requireAvailable();
    quarantine();
    final generation = _generation;
    await _run(() => fence.setAllowed(false));
    requireGeneration(generation);
    await _remove(pkceKey);
    requireGeneration(generation);
    return generation;
  }

  /// Saves a current, validated OAuth result before the main client can use it.
  /// Generic SDK events cannot reopen the durable restore fence.
  Future<void> persistCandidate(int generation, String value) => _run(() async {
    requireGeneration(generation);
    final sanitized = sanitizedSessionJson(value);
    await store.write(sessionKey, sanitized);
    requireGeneration(generation);
    if (await store.read(sessionKey) != sanitized) {
      throw const SecureStorageFailure();
    }
    requireGeneration(generation);
    await fence.setAllowed(true);
    requireGeneration(generation);
  });

  void acceptCandidate(int generation) {
    requireGeneration(generation);
    acceptsSessions = true;
    _notify();
  }

  Future<void> dispose() {
    quarantine();
    return _changes.close();
  }
}

class _SecureSessionStorage extends LocalStorage {
  const _SecureSessionStorage(this.owner);
  final SecureAuthStorage owner;

  @override
  Future<void> initialize() => owner.initialize();
  @override
  Future<bool> hasAccessToken() async => await accessToken() != null;
  @override
  Future<String?> accessToken() async =>
      owner.acceptsSessions ? owner._readSession() : null;
  @override
  Future<void> persistSession(String value) => owner._writeSession(value);
  @override
  Future<void> removePersistedSession() =>
      owner._remove(SecureAuthStorage.sessionKey);
}

class _SecurePkceStorage extends GotrueAsyncStorage {
  const _SecurePkceStorage(this.owner, this.generation);
  final SecureAuthStorage owner;
  final int? generation;

  void _validate(String key) {
    if (key != SecureAuthStorage.sdkPkceKey) {
      throw const SecureStorageFailure();
    }
  }

  void _requireFlow() {
    if (generation == null) throw const ObsoleteAuthFlow();
    owner.requireGeneration(generation!);
  }

  @override
  Future<String?> getItem({required String key}) {
    _validate(key);
    return owner._run(() async {
      _requireFlow();
      final value = await owner.store.read(SecureAuthStorage.pkceKey);
      _requireFlow();
      return value;
    });
  }

  @override
  Future<void> setItem({required String key, required String value}) {
    _validate(key);
    return owner._run(() async {
      _requireFlow();
      await owner.store.write(SecureAuthStorage.pkceKey, value);
      _requireFlow();
      if (await owner.store.read(SecureAuthStorage.pkceKey) != value) {
        throw const SecureStorageFailure();
      }
      _requireFlow();
    });
  }

  @override
  Future<void> removeItem({required String key}) {
    _validate(key);
    if (generation == null) return Future.value();
    return owner._run(() async {
      _requireFlow();
      await owner.store.remove(SecureAuthStorage.pkceKey);
      if (await owner.store.read(SecureAuthStorage.pkceKey) != null) {
        throw const SecureStorageFailure();
      }
    }, cleanup: true);
  }
}
