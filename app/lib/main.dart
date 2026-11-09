import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:app_links/app_links.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'app.dart';
import 'auth_config.dart';
import 'domain.dart';
import 'repository.dart';
import 'interrupted_image_selection.dart';
import 'secure_auth_storage.dart';
import 'mobile_oauth.dart';

final runtimeError = ValueNotifier<String?>(null);

void captureUnexpectedError() {
  scheduleMicrotask(
    () => runtimeError.value =
        'حدث خطأ غير متوقع. لم نؤكد نجاح العملية؛ أعد فتح الشاشة وحاول مجدداً.',
  );
}

void main() {
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      // Global safety nets complement typed recoverable failures at I/O boundaries.
      // Raw errors and stacks are deliberately never printed or transmitted.
      FlutterError.onError = (_) => captureUnexpectedError();
      PlatformDispatcher.instance.onError = (_, _) {
        captureUnexpectedError();
        return true;
      };
      ErrorWidget.builder = (_) => const Directionality(
        textDirection: TextDirection.rtl,
        child: ColoredBox(
          color: Color(0xfffafafa),
          child: Center(
            child: Text(
              'تعذر عرض هذا الجزء. أعد فتح الشاشة.',
              style: TextStyle(color: Colors.black, fontSize: 20),
            ),
          ),
        ),
      );
      const url = String.fromEnvironment('SUPABASE_URL');
      const key = String.fromEnvironment('SUPABASE_ANON_KEY');
      const redirect = String.fromEnvironment('AUTH_REDIRECT_URL');
      BirdsRepository repository = PreviewRepository();
      String? startupFailure;
      if (url.isNotEmpty || key.isNotEmpty) {
        // Keep the first frame visible while the bounded secure-store reads run.
        // No account actions/routes exist until initialization finishes.
        runApp(const AuthStartupApp());
        final result = await protect(
          () async {
            final uri = Uri.tryParse(url);
            if (uri == null ||
                uri.scheme != 'https' ||
                uri.host.isEmpty ||
                key.isEmpty) {
              throw const AppFailure(
                'إعداد Supabase غير مكتمل أو غير آمن. تحقق من إعدادات البناء.',
              );
            }
            if (redirect.isNotEmpty) validateAuthRedirect(redirect);
            final authStorage = SecureAuthStorage(
              NativeCredentialStore(uri.host),
              fence: NativeAuthRestoreFence(uri.host),
            );
            authStorage.changes.listen((_) {
              if (authStorage.failed) {
                runtimeError.value = secureStorageMessage;
              } else if (runtimeError.value == secureStorageMessage) {
                runtimeError.value = null;
              }
            });
            try {
              await Supabase.initialize(
                url: url,
                publishableKey: key,
                debug: false,
                authOptions: FlutterAuthClientOptions(
                  authFlowType: AuthFlowType.pkce,
                  detectSessionInUri: false,
                  localStorage: authStorage.session,
                  pkceAsyncStorage: authStorage.pkce,
                ),
              );
            } catch (_) {
              await protect(() => Supabase.instance.dispose(), timeout: null);
              await authStorage.dispose();
              rethrow;
            }
            final oauth = MobileOAuthCoordinator(
              mainAuth: Supabase.instance.client.auth,
              storage: authStorage,
              createClient: (pkce) => GoTrueClient(
                url: '$url/auth/v1',
                headers: {'apikey': key, 'Authorization': 'Bearer $key'},
                autoRefreshToken: false,
                flowType: AuthFlowType.pkce,
                asyncStorage: pkce,
              ),
              notice: (message) => runtimeError.value = message,
            );
            unawaited(oauth.listenForLinks(AppLinks()));
            return SupabaseBirdsRepository(
              Supabase.instance.client,
              authRedirect: redirect,
              authStorage: authStorage,
              oauth: oauth,
            );
          },
          timeout: null,
        ); // Each native operation is bounded. Do not orphan SDK
        // initialization behind a non-canceling outer Future.timeout.
        if (result.isSuccess) {
          repository = result.value!;
        } else {
          if (result.failure is SecureStorageFailure) {
            startupFailure =
                'تعذر فتح التخزين الآمن لبيانات الدخول. افتح قفل الجهاز وأعد تشغيل التطبيق. تعمل المعاينة المحلية فقط ولم نستخدم تخزيناً بديلاً.';
            if (runtimeError.value == secureStorageMessage) {
              runtimeError.value = null;
            }
          } else {
            startupFailure =
                '${result.failure!.message} تعمل المعاينة المحلية فقط.';
          }
        }
      }
      runApp(
        BirdsApp(
          repository: repository,
          startupFailure: startupFailure,
          startupNotice: discardInterruptedImageSelection(),
          errorSignal: runtimeError,
        ),
      );
    },
    (_, _) {
      // Final containment only. Do not claim a failed operation succeeded.
      captureUnexpectedError();
    },
  );
}

class AuthStartupApp extends StatelessWidget {
  const AuthStartupApp({super.key});

  @override
  Widget build(BuildContext context) => const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(semanticsLabel: 'جارٍ فتح التطبيق'),
                  SizedBox(height: 24),
                  Text(
                    'جارٍ التحقق من التخزين الآمن لبيانات الدخول…',
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
