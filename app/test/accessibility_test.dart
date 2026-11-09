import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sudan_birds/app.dart';
import 'package:sudan_birds/domain.dart';
import 'package:sudan_birds/media_screens.dart';
import 'package:sudan_birds/moderation_screens.dart';
import 'package:sudan_birds/screens.dart';

class AccessibleRepository extends PreviewRepository {
  Completer<Result<bool>>? pending;
  int reportCalls = 0;
  @override
  bool get signedIn => true;
  @override
  Future<Result<bool>> isModerator() async => const Result.success(true);
  @override
  Future<Result<List<ModerationReport>>> moderationReports(
    String state, {
    ModerationReport? before,
  }) async => const Result.success([]);
  @override
  Future<Result<ModerationTarget?>> moderationTarget(
    ModerationReport report,
  ) async => const Result.success(
    ModerationTarget(
      id: 'target',
      kind: ReportKind.listing,
      title: 'محتوى يحتاج إلى المراجعة',
      body: 'نص عام للمراجعة دون معلومات اتصال خاصة.',
      hidden: false,
    ),
  );

  @override
  Future<Result<ProfileData?>> profile() async =>
      const Result.success(ProfileData('مربي الطيور', true));
  @override
  Future<Result<Taxonomy>> taxonomy() async => const Result.success(
    Taxonomy(
      birds: [NamedOption(1, 'نوع طيور ذو اسم عربي طويل للاختبار')],
      locations: [LocationOption(1, 'ولاية الخرطوم', 'الخرطوم')],
    ),
  );
  @override
  Future<Result<bool>> reportTarget(
    ReportKind kind,
    String targetId,
    String reason,
  ) async {
    reportCalls++;
    return pending == null ? const Result.success(true) : pending!.future;
  }
}

Widget arabicPage(Widget page) => MaterialApp(
  locale: const Locale('ar'),
  supportedLocales: const [Locale('ar')],
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  home: page,
);

void smallLargeText(WidgetTester tester) {
  tester.view.physicalSize = const Size(320, 568);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = 2;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  });
}

void main() {
  testWidgets(
    'two tabs and home remain usable at 320px and 200 percent Arabic text',
    (tester) async {
      smallLargeText(tester);
      final handle = tester.ensureSemantics();

      await tester.pumpWidget(BirdsApp(repository: PreviewRepository()));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(NavigationDestination), findsNWidgets(2));
      expect(find.byTooltip('الحساب والإعدادات'), findsOneWidget);
      expect(find.bySemanticsLabel('إضافة طلب'), findsOneWidget);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      handle.dispose();
    },
  );
  testWidgets(
    'forms and destructive/report screens support small high-text viewport',
    (tester) async {
      smallLargeText(tester);
      final repo = AccessibleRepository();
      final pages = <Widget>[
        ProfilePage(repository: repo),
        FilterPage(
          repository: repo,
          kind: FeedKind.offer,
          initial: const FeedFilter(),
        ),
        PublicationPage(repository: repo, kind: FeedKind.offer),
        ReportPage(
          repository: repo,
          kind: ReportKind.listing,
          targetId: 'listing',
        ),
        DeleteAccountPage(repository: repo),
        const DraftLegalPage(privacy: true),
        ModerationQueuePage(repository: repo),
        ReviewReportPage(
          repository: repo,
          report: ModerationReport(
            id: 'report',
            reason: 'سبب بلاغ للمراجعة',
            state: 'open',
            createdAt: DateTime.utc(2026),
            kind: ReportKind.listing,
            targetId: 'target',
          ),
        ),
        UploadImagePage(
          repository: repo,
          entry: FeedEntry(
            id: 'entry',
            title: 'عنوان',
            body: 'نص',
            kind: FeedKind.offer,
            createdAt: DateTime.utc(2026),
          ),
        ),
      ];
      for (var index = 0; index < pages.length; index++) {
        await tester.pumpWidget(
          KeyedSubtree(key: ValueKey(index), child: arabicPage(pages[index])),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'screen $index initial');
        for (var step = 0; step < 6; step++) {
          await tester.drag(
            find.byType(Scrollable).first,
            const Offset(0, -400),
          );
          await tester.pumpAndSettle();
          expect(
            tester.takeException(),
            isNull,
            reason: 'screen $index scroll $step',
          );
        }
      }
    },
  );
  testWidgets(
    'report submit is labeled, locks duplicate taps and survives navigation away',
    (tester) async {
      final repo = AccessibleRepository()..pending = Completer<Result<bool>>();
      final handle = tester.ensureSemantics();

      await tester.pumpWidget(
        arabicPage(
          ReportPage(
            repository: repo,
            kind: ReportKind.listing,
            targetId: 'listing',
          ),
        ),
      );
      await tester.enterText(
        find.byType(TextField),
        'محتوى مخالف يستدعي المراجعة',
      );
      expect(find.bySemanticsLabel('إرسال البلاغ'), findsOneWidget);
      await tester.tap(find.text('إرسال البلاغ'));
      await tester.pump();
      final button = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(button.onPressed, isNull);
      expect(repo.reportCalls, 1);
      handle.dispose();
      await tester.pumpWidget(arabicPage(const SizedBox()));
      repo.pending!.complete(const Result.success(true));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(repo.reportCalls, 1);
    },
  );
  testWidgets(
    'destructive confirmation is scrollable, labeled and opens only once',
    (tester) async {
      smallLargeText(tester);
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        arabicPage(DeleteAccountPage(repository: AccessibleRepository())),
      );
      await tester.scrollUntilVisible(
        find.byType(TextField),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(find.byType(TextField), 'حذف حسابي');
      final button = find.widgetWithText(FilledButton, 'طلب حذف حسابي نهائياً');
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      final trigger = tester.widget<FilledButton>(button).onPressed!;
      trigger();
      trigger();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(find.bySemanticsLabel('أؤكد الحذف النهائي'), findsOneWidget);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await tester.tap(find.text('إلغاء'));
      await tester.pumpAndSettle();
      handle.dispose();
    },
  );
}
