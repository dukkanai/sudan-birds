import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sudan_birds/domain.dart';
import 'package:sudan_birds/moderation_screens.dart';
import 'package:sudan_birds/screens.dart';
import 'flow_recovery_test.dart' show FlowRepository, openPage, visibleTap;

class WriteRepository extends FlowRepository {
  final pending = Completer<Result<bool>>();
  int profileWrites = 0, contactWrites = 0, moderationWrites = 0;
  int profileReads = 0, targetReads = 0;
  @override
  Future<Result<ProfileData?>> profile() async {
    profileReads++;
    return const Result.success(ProfileData('اسم الاختبار', true));
  }

  @override
  Future<Result<bool>> saveProfile(String name, bool accepted) {
    profileWrites++;
    return pending.future;
  }

  @override
  Future<Result<bool>> saveContact(ContactData contact) {
    contactWrites++;
    return pending.future;
  }

  @override
  Future<Result<bool>> moderate(
    ModerationReport report,
    bool hidden,
    String reason,
  ) {
    moderationWrites++;
    return pending.future;
  }

  @override
  Future<Result<bool>> resolveReport(String id, String state, String reason) {
    actions++;
    return pending.future;
  }

  @override
  Future<Result<ModerationTarget?>> moderationTarget(ModerationReport report) {
    targetReads++;
    return super.moderationTarget(report);
  }
}

final report = ModerationReport(
  id: 'report',
  reason: 'سبب واضح',
  state: 'open',
  createdAt: DateTime.utc(2026),
  kind: ReportKind.listing,
  targetId: 'target',
);

VoidCallback? profileCallback(WidgetTester tester) => tester
    .widget<FilledButton>(
      find.widgetWithText(FilledButton, 'حفظ الملف والإقرار'),
    )
    .onPressed;
VoidCallback? contactCallback(WidgetTester tester) => tester
    .widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'حفظ تفضيل مشاركة التواصل'),
    )
    .onPressed;

void finishUnknown(WriteRepository repo, bool rawError) {
  if (rawError) {
    repo.pending.completeError(StateError('private-test-marker'));
  } else {
    repo.pending.complete(
      const Result.failure(AppFailure('نتيجة غير مؤكدة', outcomeUnknown: true)),
    );
  }
}

Future<void> openWritePage(WidgetTester tester, Widget page) async {
  tester.view.physicalSize = const Size(1000, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await openPage(tester, page);
}

void main() {
  for (final contact in [false, true]) {
    for (final rawError in [false, true]) {
      testWidgets(
        '${contact ? 'contact' : 'profile'} ${rawError ? 'raw exception' : 'unknown result'} locks writes across reload and stale callbacks',
        (tester) async {
          final repo = WriteRepository();
          addTearDown(repo.sessions.close);
          await openWritePage(tester, ProfilePage(repository: repo));
          // Build both controls before capturing their pre-request callbacks.
          await tester.ensureVisible(find.text('حفظ تفضيل مشاركة التواصل'));
          await tester.pumpAndSettle();
          final staleProfile = profileCallback(tester)!;
          final staleContact = contactCallback(tester)!;
          (contact ? staleContact : staleProfile)();
          await tester.pump();
          finishUnknown(repo, rawError);
          await tester.pumpAndSettle();
          expect(profileCallback(tester), isNull);
          expect(contactCallback(tester), isNull);
          expect(find.textContaining('private-test-marker'), findsNothing);
          expect(find.text('تم حفظ تفضيل مشاركة التواصل.'), findsNothing);
          expect(
            find.text('تم حفظ الملف الشخصي. يمكنك النشر والإبلاغ'),
            findsNothing,
          );
          final reads = repo.profileReads;
          await visibleTap(tester, find.text('إعادة التحميل'));
          await tester.pumpAndSettle();
          expect(repo.profileReads, reads + 1);
          expect(profileCallback(tester), isNull);
          expect(contactCallback(tester), isNull);
          staleProfile();
          staleContact();
          await tester.pumpAndSettle();
          expect(repo.profileWrites, contact ? 0 : 1);
          expect(repo.contactWrites, contact ? 1 : 0);
        },
      );
    }
    testWidgets(
      '${contact ? 'contact' : 'profile'} known rejection remains retryable',
      (tester) async {
        final repo = WriteRepository();
        addTearDown(repo.sessions.close);
        await openWritePage(tester, ProfilePage(repository: repo));
        await tester.ensureVisible(find.text('حفظ تفضيل مشاركة التواصل'));
        await tester.pumpAndSettle();
        (contact ? contactCallback(tester)! : profileCallback(tester)!)();
        await tester.pump();
        repo.pending.complete(
          const Result.failure(AppFailure('تحقق من الإدخال')),
        );
        await tester.pumpAndSettle();
        expect(profileCallback(tester), isNotNull);
        expect(contactCallback(tester), isNotNull);
        expect(find.textContaining('أُوقف تكرار الحفظ'), findsNothing);
        (contact ? contactCallback(tester)! : profileCallback(tester)!)();
        await tester.pumpAndSettle();
        expect(repo.profileWrites, contact ? 0 : 2);
        expect(repo.contactWrites, contact ? 2 : 0);
      },
    );
  }

  for (final moderate in [false, true]) {
    final label = moderate ? 'إخفاء المحتوى' : 'تعيين الحالة: تمت المعالجة';
    for (final rawError in [false, true]) {
      testWidgets(
        '${moderate ? 'moderate' : 'resolve'} ${rawError ? 'raw exception' : 'unknown result'} locks all actions across target reload',
        (tester) async {
          final repo = WriteRepository();
          addTearDown(repo.sessions.close);
          await openWritePage(
            tester,
            ReviewReportPage(repository: repo, report: report),
          );
          await tester.enterText(find.byType(TextField), 'سبب إجراء المراجعة');
          final hideFinder = find.widgetWithText(
            OutlinedButton,
            'إخفاء المحتوى',
          );
          final resolveFinder = find.widgetWithText(
            TextButton,
            'تعيين الحالة: تمت المعالجة',
          );
          final staleHide = tester
              .widget<OutlinedButton>(hideFinder)
              .onPressed!;
          final staleResolve = tester
              .widget<TextButton>(resolveFinder)
              .onPressed!;
          await visibleTap(tester, find.text(label));
          await tester.pumpAndSettle();
          await tester.tap(find.text('تأكيد الإجراء'));
          await tester.pump();
          finishUnknown(repo, rawError);
          await tester.pumpAndSettle();
          void expectLocked() {
            expect(tester.widget<OutlinedButton>(hideFinder).onPressed, isNull);
            final stateButtons = tester.widgetList<TextButton>(
              find.byWidgetPredicate(
                (w) =>
                    w is TextButton &&
                    w.child is Text &&
                    ((w.child as Text).data ?? '').startsWith('تعيين الحالة:'),
              ),
            );
            expect(stateButtons.length, 3);
            expect(stateButtons.every((b) => b.onPressed == null), isTrue);
          }

          expectLocked();
          expect(find.text('أكد الخادم تنفيذ الإجراء وتسجيله.'), findsNothing);
          expect(find.textContaining('private-test-marker'), findsNothing);
          final reads = repo.targetReads;
          await visibleTap(tester, find.text('إعادة تحميل الهدف'));
          await tester.pumpAndSettle();
          expect(repo.targetReads, reads + 1);
          expectLocked();
          staleHide();
          staleResolve();
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsNothing);
          expect(repo.moderationWrites, moderate ? 1 : 0);
          expect(repo.actions, moderate ? 0 : 1);
        },
      );
    }
    testWidgets(
      '${moderate ? 'moderate' : 'resolve'} known rejection remains retryable',
      (tester) async {
        final repo = WriteRepository();
        addTearDown(repo.sessions.close);
        await openWritePage(
          tester,
          ReviewReportPage(repository: repo, report: report),
        );
        await tester.enterText(find.byType(TextField), 'سبب إجراء المراجعة');
        await visibleTap(tester, find.text(label));
        await tester.pumpAndSettle();
        await tester.tap(find.text('تأكيد الإجراء'));
        await tester.pump();
        repo.pending.complete(const Result.failure(AppFailure('رفض معروف')));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, 'إخفاء المحتوى'),
              )
              .onPressed,
          isNotNull,
        );
        expect(
          tester
              .widget<TextButton>(
                find.widgetWithText(TextButton, 'تعيين الحالة: تمت المعالجة'),
              )
              .onPressed,
          isNotNull,
        );
        await visibleTap(tester, find.text(label));
        await tester.pumpAndSettle();
        await tester.tap(find.text('تأكيد الإجراء'));
        await tester.pumpAndSettle();
        expect(repo.moderationWrites, moderate ? 2 : 0);
        expect(repo.actions, moderate ? 0 : 2);
      },
    );
  }
}
