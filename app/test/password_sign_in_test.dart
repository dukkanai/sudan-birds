import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sudan_birds/domain.dart';
import 'package:sudan_birds/password_sign_in.dart';

class PasswordRepository extends PreviewRepository {
  final pending = Completer<Result<bool>>();
  int attempts = 0, cancellations = 0;
  bool failFirstCancellation = false;
  @override
  Future<Result<bool>> signInWithPassword(String email, String password) {
    attempts++;
    expect(email, 'trial@example.test');
    expect(password, 'synthetic-only');
    return pending.future;
  }

  @override
  Future<Result<bool>> cancelSignIn() async {
    cancellations++;
    if (failFirstCancellation && cancellations == 1) {
      return const Result.failure(
        AppFailure('تعذر تأكيد إلغاء الدخول. أعد المحاولة.'),
      );
    }
    return const Result.success(true);
  }
}

Future<void> open(
  WidgetTester tester,
  PasswordRepository repo, {
  double scale = 1,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            child: const Text('افتح الدخول'),
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) => PasswordSignInPage(repository: repo),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('افتح الدخول'));
  await tester.pumpAndSettle();
}

Future<void> fill(WidgetTester tester) async {
  await tester.enterText(
    find.byKey(const ValueKey('trial-email')),
    ' trial@example.test ',
  );
  await tester.enterText(
    find.byKey(const ValueKey('trial-password')),
    'synthetic-only',
  );
}

void main() {
  testWidgets(
    'uncertain cancellation keeps login disabled and retries cleanup',
    (tester) async {
      final repo = PasswordRepository()..failFirstCancellation = true;
      await open(tester, repo);
      await fill(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'تسجيل الدخول'));
      await tester.pump();
      await tester.tap(find.widgetWithText(TextButton, 'إلغاء'));
      await tester.pumpAndSettle();
      expect(find.byType(PasswordSignInPage), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'تسجيل الدخول'),
            )
            .onPressed,
        isNull,
      );
      expect(
        find.text('تعذر تأكيد إلغاء الدخول. أعد المحاولة.'),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(TextButton, 'إلغاء'));
      await tester.pumpAndSettle();
      expect(repo.cancellations, 2);
      expect(find.byType(PasswordSignInPage), findsNothing);
      repo.pending.complete(const Result.success(true));
      await tester.pumpAndSettle();
      expect(find.byType(PasswordSignInPage), findsNothing);
    },
  );

  testWidgets('invalid local input never starts a login and clears password', (
    tester,
  ) async {
    final repo = PasswordRepository();
    await open(tester, repo);
    await tester.enterText(
      find.byKey(const ValueKey('trial-email')),
      'not-an-email',
    );
    await tester.enterText(
      find.byKey(const ValueKey('trial-password')),
      'synthetic-only',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'تسجيل الدخول'));
    await tester.pumpAndSettle();
    expect(repo.attempts, 0);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('trial-password')))
          .controller!
          .text,
      isEmpty,
    );
    expect(
      find.text('أدخل البريد الإلكتروني وكلمة المرور لحساب التجربة.'),
      findsOneWidget,
    );
  });

  testWidgets(
    'password entry is obscured and cleared before pending work; repeated taps blocked',
    (tester) async {
      final repo = PasswordRepository();
      await open(tester, repo);
      await fill(tester);
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('trial-password')),
      );
      expect(field.obscureText, true);
      expect(field.enableSuggestions, false);
      expect(field.autocorrect, false);
      final submit = tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'تسجيل الدخول'),
          )
          .onPressed!;
      submit();
      submit();
      await tester.pump();
      expect(repo.attempts, 1);
      expect(field.controller!.text, isEmpty);
      repo.pending.complete(const Result.success(true));
      await tester.pumpAndSettle();
      expect(find.byType(PasswordSignInPage), findsNothing);
    },
  );

  testWidgets(
    'invalid credentials remain retryable and raw failures are contained',
    (tester) async {
      final repo = PasswordRepository();
      await open(tester, repo);
      await fill(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'تسجيل الدخول'));
      repo.pending.completeError(StateError('private-token-secret'));
      await tester.pumpAndSettle();
      expect(find.textContaining('تعذر إتمام العملية'), findsOneWidget);
      expect(find.textContaining('private-token-secret'), findsNothing);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'تسجيل الدخول'),
            )
            .onPressed,
        isNotNull,
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('trial-password')))
            .controller!
            .text,
        isEmpty,
      );
    },
  );

  testWidgets('cancel fences a pending result and does not reopen the route', (
    tester,
  ) async {
    final repo = PasswordRepository();
    await open(tester, repo);
    await fill(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'تسجيل الدخول'));
    await tester.pump();
    await tester.tap(find.widgetWithText(TextButton, 'إلغاء'));
    await tester.pumpAndSettle();
    expect(repo.cancellations, 1);
    repo.pending.complete(const Result.success(true));
    await tester.pumpAndSettle();
    expect(find.byType(PasswordSignInPage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('system back cancels pending login', (tester) async {
    final repo = PasswordRepository();
    await open(tester, repo);
    await fill(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'تسجيل الدخول'));
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(repo.cancellations, 1);
    expect(find.byType(PasswordSignInPage), findsNothing);
    repo.pending.complete(const Result.failure(AppFailure('تم إلغاء الدخول.')));
    await tester.pumpAndSettle();
  });

  testWidgets(
    'Arabic labels, large text and small viewport remain scrollable and accessible',
    (tester) async {
      tester.view.physicalSize = const Size(390, 640);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 180);
      addTearDown(tester.view.resetViewInsets);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final semantics = tester.ensureSemantics();
      try {
        await open(tester, PasswordRepository(), scale: 2.0);
        expect(find.bySemanticsLabel('البريد الإلكتروني'), findsOneWidget);
        expect(find.bySemanticsLabel('كلمة المرور'), findsOneWidget);
        expect(find.textContaining('Google'), findsNothing);
        expect(find.textContaining('Apple'), findsNothing);
        await tester.scrollUntilVisible(
          find.widgetWithText(TextButton, 'إلغاء'),
          150,
          scrollable: find
              .descendant(
                of: find.byType(SingleChildScrollView),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        expect(tester.takeException(), isNull);
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      } finally {
        semantics.dispose();
      }
    },
  );
}
