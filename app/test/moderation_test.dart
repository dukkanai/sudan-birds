import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sudan_birds/domain.dart';
import 'package:sudan_birds/moderation_screens.dart';
import 'package:sudan_birds/screens.dart';

class ModerationFixture extends PreviewRepository {
  ModerationFixture({
    this.allowed = false,
    this.pending = false,
    this.authenticated = true,
  });
  final bool allowed, pending, authenticated;
  int reports = 0, profileReads = 0;
  @override
  bool get signedIn => authenticated;
  @override
  Future<Result<bool>> isModerator() async => Result.success(allowed);
  @override
  Future<Result<DeletionStatus?>> deletionStatus() async =>
      Result.success(pending ? const DeletionStatus(false) : null);
  @override
  Future<Result<ProfileData?>> profile() async {
    profileReads++;
    return const Result.success(null);
  }

  @override
  Future<Result<bool>> reportTarget(
    ReportKind kind,
    String targetId,
    String reason,
  ) async {
    reports++;
    return const Result.success(true);
  }
}

class SupportRequiredRepository extends PreviewRepository {
  @override
  Future<Result<DeletionStatus?>> deletionStatus() async =>
      const Result.success(DeletionStatus(false, requiresOperator: true));
}

void main() {
  testWidgets('moderation entry is absent without a verified role', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ModeratorAccessTile(repository: ModerationFixture()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('مراجعة البلاغات (للمشرفين)'), findsNothing);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ModeratorAccessTile(
            key: const ValueKey('moderator'),
            repository: ModerationFixture(allowed: true),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('مراجعة البلاغات (للمشرفين)'), findsOneWidget);
  });
  testWidgets('guest cannot send account or listing reports', (tester) async {
    final repo = ModerationFixture(authenticated: false);
    await tester.pumpWidget(
      MaterialApp(
        home: ReportPage(
          repository: repo,
          kind: ReportKind.account,
          targetId: 'account',
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'سبب واضح للإبلاغ');
    await tester.tap(find.text('إرسال البلاغ'));
    await tester.pumpAndSettle();
    expect(repo.reports, 0);
    expect(find.text('سجّل الدخول وأكمل الملف الشخصي أولاً.'), findsOneWidget);
  });
  testWidgets('pending deletion is shown instead of fresh onboarding', (
    tester,
  ) async {
    final repo = ModerationFixture(pending: true);
    await tester.pumpWidget(MaterialApp(home: ProfilePage(repository: repo)));
    await tester.pumpAndSettle();
    expect(repo.profileReads, 0);
    expect(find.widgetWithText(TextField, 'اسم العرض العام'), findsNothing);
    expect(find.textContaining('حذف الحساب قيد التنفيذ'), findsOneWidget);
  });
  testWidgets('legal drafts remain clearly nonfinal', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: DraftLegalLinks())),
    );
    await tester.tap(find.text('مسودة سياسة الخصوصية • غير نهائية'));
    await tester.pumpAndSettle();
    expect(find.textContaining('غير معتمدة للنشر العام'), findsOneWidget);
  });
  testWidgets(
    'operator blockers are not described as normal deletion progress',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DeletionStatusPanel(repository: SupportRequiredRepository()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('يحتاج إلى تدخل مسؤول الخدمة'),
        findsOneWidget,
      );
      expect(
        find.textContaining('قد تنتظر العملية انتهاء روابط الرفع'),
        findsNothing,
      );
    },
  );
}
