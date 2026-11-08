import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'app.dart';
import 'domain.dart';
import 'repository.dart';

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
        final result = await protect(() async {
          final uri = Uri.tryParse(url);
          if (uri == null ||
              uri.scheme != 'https' ||
              uri.host.isEmpty ||
              key.isEmpty) {
            throw const AppFailure(
              'إعداد Supabase غير مكتمل أو غير آمن. تحقق من إعدادات البناء.',
            );
          }
          await Supabase.initialize(
            url: url,
            publishableKey: key,
            debug: false,
          );
          return SupabaseBirdsRepository(
            Supabase.instance.client,
            authRedirect: redirect,
          );
        });
        if (result.isSuccess) {
          repository = result.value!;
        } else {
          startupFailure =
              '${result.failure!.message} تعمل المعاينة المحلية فقط.';
        }
      }
      runApp(
        BirdsApp(
          repository: repository,
          startupFailure: startupFailure,
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
