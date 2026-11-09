import 'dart:async';
import 'dart:convert';
import 'package:app_links/app_links.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'auth_config.dart';
import 'domain.dart';
import 'secure_auth_storage.dart';

typedef OAuthClientFactory = GoTrueClient Function(GotrueAsyncStorage storage);
typedef OAuthLauncher =
    Future<bool> Function(
      GoTrueClient client,
      OAuthProvider provider,
      String redirect,
    );

const oauthRetryMessage = 'لم يكتمل تسجيل الدخول. أعد المحاولة من زر الحساب.';
const oauthRestartMessage =
    'انتهت محاولة الدخول السابقة بعد إعادة تشغيل التطبيق. سجّل الدخول مجدداً من زر الحساب.';

/// Each browser flow owns its SDK client and generation-bound verifier adapter.
/// A stale exchange may finish in its isolated client, but can never install an
/// identity in the application or delete the current flow's verifier.
class MobileOAuthCoordinator {
  MobileOAuthCoordinator({
    required this.mainAuth,
    required this.storage,
    required this.createClient,
    required this.notice,
    OAuthLauncher? launch,
    Future<void> Function(String)? install,
    this.exchangeTimeout = const Duration(seconds: 20),
  }) : launch = launch ?? _launch,
       install = install ?? mainAuth.setInitialSession;

  final GoTrueClient mainAuth;
  final SecureAuthStorage storage;
  final OAuthClientFactory createClient;
  final void Function(String) notice;
  final OAuthLauncher launch;
  final Future<void> Function(String) install;
  final Duration exchangeTimeout;
  _OAuthFlow? _flow;
  Future<void> _lifecycle = Future.value();
  Future<void>? _logout;
  StreamSubscription<Uri>? _links;
  bool _starting = false, _closing = false;
  int _installations = 0;
  bool _disposed = false;

  static Future<bool> _launch(
    GoTrueClient client,
    OAuthProvider provider,
    String redirect,
  ) => client.signInWithOAuth(provider, redirectTo: redirect);

  bool _current(_OAuthFlow flow) =>
      !_disposed &&
      identical(_flow, flow) &&
      storage.generation == flow.generation;

  Future<T> _exclusive<T>(Future<T> Function() action) {
    final operation = _lifecycle.then((_) => action());
    _lifecycle = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  /// AppLinks supplies cold and warm links. A return without an owned live flow
  /// is intentionally not exchanged, even if an encrypted verifier survived.
  Future<void> listenForLinks(AppLinks links) async {
    _links = links.uriLinkStream.listen(
      (uri) => unawaited(handleCallback(uri)),
      onError: (Object _) => notice(oauthRetryMessage),
    );
    try {
      final initial = await links.getInitialLink().timeout(
        const Duration(seconds: 5),
      );
      if (!_disposed && initial != null) await handleCallback(initial);
    } catch (_) {
      if (!_disposed) notice(oauthRetryMessage);
    }
  }

  Future<bool> signIn(OAuthProvider provider, String redirect) async {
    validateAuthRedirect(redirect);
    storage.requireAvailable();
    if (_disposed ||
        _starting ||
        _installations != 0 ||
        _closing ||
        mainAuth.currentSession != null) {
      throw const AppFailure(
        'انتظر انتهاء إجراء الحساب الحالي ثم حاول مجدداً.',
      );
    }
    _starting = true;
    final previous = _flow;
    _flow = null;
    previous?.retire();
    _OAuthFlow? flow;
    try {
      final generation = await storage.prepareSignIn();
      storage.requireGeneration(generation);
      flow = _OAuthFlow(generation, createClient(storage.pkceFor(generation)));
      _flow = flow;
      final launched = await launch(flow.client, provider, redirect);
      flow.launched.complete(launched);
      if (!_current(flow)) throw const ObsoleteAuthFlow();
      if (!launched) throw const AppFailure(oauthRetryMessage);
      return true;
    } catch (_) {
      if (flow != null && !flow.launched.isCompleted) {
        flow.launched.complete(false);
      }
      if (flow != null && _current(flow)) {
        _flow = null;
        await _exclusive(() async {
          await storage.beginSignOut();
          await storage.clearAfterSignOut();
        });
      }
      flow?.retire();
      rethrow;
    } finally {
      _starting = false;
    }
  }

  Future<void> handleCallback(Uri uri) async {
    if (_disposed || !isStagingAuthCallback(uri)) return;
    final flow = _flow;
    if (flow == null) {
      // Do not turn duplicate delivery after a successful login into an error.
      if (!storage.acceptsSessions && !_closing) notice(oauthRestartMessage);
      return;
    }
    if (flow.exchanging || !_current(flow)) return;
    flow.exchanging = true;
    var installing = false;
    try {
      if (!await flow.launched.future || !_current(flow)) return;
      if (uri.queryParameters.containsKey('error')) {
        throw const AppFailure(oauthRetryMessage);
      }
      flow.networkPending = true;
      final response = await flow.client
          .exchangeCodeForSession(uri.queryParameters['code']!)
          .whenComplete(() {
            flow.networkPending = false;
            flow.finishRetirement();
          })
          .timeout(exchangeTimeout);
      if (!_current(flow)) return;
      final session = response.session;
      if (session.isExpired || session.refreshToken == null) {
        throw const AppFailure(oauthRetryMessage);
      }
      final encoded = jsonEncode(session.toJson());
      installing = true;
      _installations++;
      await _exclusive(() async {
        if (!_current(flow)) return;
        await storage.persistCandidate(flow.generation, encoded);
        if (!_current(flow)) return;
        // The pinned SDK's valid setInitialSession branch installs synchronously.
        // The lifecycle gate also protects a delayed implementation: logout
        // invalidates now but waits for installation before clearing the SDK.
        await install(encoded);
        if (!_current(flow)) return;
        storage.acceptCandidate(flow.generation);
        _flow = null;
      });
    } on ObsoleteAuthFlow {
      // Canceled flow; do not poison a newer session or expose raw SDK errors.
    } catch (_) {
      if (_current(flow)) {
        await signOut().catchError((Object _) {});
        notice(storage.failed ? secureStorageMessage : oauthRetryMessage);
      }
    } finally {
      if (installing) _installations--;
      flow.exchanging = false;
      flow.retire();
    }
  }

  Future<void> signOut() {
    if (_closing) return _logout!;
    final completion = Completer<void>();
    _logout = completion.future;
    _closing = true;
    // Before any await: prevent old exchange/persist/install from being trusted.
    storage.quarantine();
    final flow = _flow;
    _flow = null;
    flow?.retire();
    completion.complete(
      _exclusive(() async {
        try {
          await storage.beginSignOut();
          var serviceFailed = false;
          try {
            await mainAuth.signOut(scope: SignOutScope.local);
          } catch (_) {
            serviceFailed = true;
          }
          await storage.clearAfterSignOut();
          if (serviceFailed) {
            throw const AppFailure(
              'مُسحت بيانات الدخول المحلية المتاحة، لكن تعذر تأكيد إنهاء الجلسة لدى الخدمة. لا نؤكد إبطال جلسة الخادم.',
            );
          }
        } finally {
          _closing = false;
        }
      }),
    );
    return completion.future;
  }

  Future<void> dispose() async {
    _disposed = true;
    storage.quarantine();
    _flow?.retire();
    _flow = null;
    await _links?.cancel();
  }
}

class _OAuthFlow {
  _OAuthFlow(this.generation, this.client);
  final int generation;
  final GoTrueClient client;
  final launched = Completer<bool>();
  bool exchanging = false, networkPending = false;
  bool _retirementRequested = false, _retired = false;

  void retire() {
    // GoTrue may still publish into its private stream when HTTP completes.
    // Dispose only once that exchange finishes; never close it under the SDK.
    _retirementRequested = true;
    finishRetirement();
  }

  void finishRetirement() {
    if (_retirementRequested && !networkPending && !_retired) {
      _retired = true;
      client.dispose();
    }
  }
}
