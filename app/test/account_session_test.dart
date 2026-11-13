import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sudan_birds/domain.dart';
import 'package:sudan_birds/app.dart';
import 'package:sudan_birds/screens.dart';
import 'package:sudan_birds/media_screens.dart';
import 'package:sudan_birds/moderation_screens.dart';

class SessionRepository extends PreviewRepository {
  String? user = 'A';
  bool showFeed = false, showReports = false;
  int deletions = 0, contactsSaved = 0, profileSaves = 0, actions = 0;
  final sessions = StreamController<void>.broadcast(sync: true);
  Completer<Result<ContactData?>>? pendingContact;
  Completer<Result<List<ModerationReport>>>? pendingReports;
  Completer<Result<ModerationTarget?>>? pendingTarget;
  @override
  bool get signedIn => user != null;
  @override
  String? get currentUserId => user;
  @override
  Stream<void> get authChanges => sessions.stream;
  void switchTo(String? id) {
    user = id;
    sessions.add(null);
  }

  @override
  Future<Result<ProfileData?>> profile() async =>
      const Result.success(ProfileData('اسم خاص بالحساب A', true));
  @override
  Future<Result<ContactData?>> contact() async =>
      pendingContact?.future ??
      const Result.success(ContactData('phone', 'private-A-contact', true));
  @override
  Future<Result<bool>> saveContact(ContactData contact) async {
    contactsSaved++;
    return const Result.success(true);
  }

  @override
  Future<Result<bool>> saveProfile(String name, bool accepted) async {
    profileSaves++;
    return const Result.success(true);
  }

  @override
  Future<Result<DeletionStatus>> deleteOwnAccount() async {
    deletions++;
    switchTo(null);
    return const Result.success(DeletionStatus(true));
  }

  @override
  Future<Result<List<FeedEntry>>> feed(
    FeedKind kind,
    FeedFilter filter,
  ) async => Result.success(showFeed && user == 'A' ? [entry] : []);
  @override
  Future<Result<List<ModerationReport>>> moderationReports(
    String state, {
    ModerationReport? before,
  }) async =>
      pendingReports?.future ??
      Result.success(showReports && user == 'A' ? [report] : []);
  @override
  Future<Result<ModerationTarget?>> moderationTarget(
    ModerationReport report,
  ) async =>
      pendingTarget?.future ??
      const Result.success(
        ModerationTarget(
          id: 'target',
          kind: ReportKind.listing,
          title: 'هدف خاص',
          body: 'نص خاص',
          hidden: false,
        ),
      );
  @override
  Future<Result<bool>> resolveReport(
    String id,
    String state,
    String reason,
  ) async {
    actions++;
    return const Result.success(true);
  }

  @override
  Future<Result<Taxonomy>> taxonomy() async => const Result.success(Taxonomy());
  @override
  Future<Result<List<String>>> blockedUsers() async =>
      const Result.success(['private-blocked-id']);
}

final report = ModerationReport(
  id: 'report',
  reason: 'بلاغ خاص',
  state: 'open',
  createdAt: DateTime.utc(2026),
  kind: ReportKind.listing,
  targetId: 'target',
);
final entry = FeedEntry(
  id: 'listing',
  ownerId: 'A',
  title: 'عنوان خاص بالحساب A',
  body: 'نص',
  kind: FeedKind.request,
  createdAt: DateTime.utc(2026),
);

void main() {
  testWidgets('A deletion confirmation cannot authorize B deletion', (
    tester,
  ) async {
    final repo = SessionRepository();
    addTearDown(repo.sessions.close);
    await tester.pumpWidget(
      MaterialApp(home: DeleteAccountPage(repository: repo)),
    );
    await tester.enterText(find.byType(TextField), 'حذف حسابي');
    await tester.ensureVisible(find.text('طلب حذف حسابي نهائياً'));
    await tester.tap(find.text('طلب حذف حسابي نهائياً'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    final confirm = tester
        .widget<FilledButton>(
          find.widgetWithText(FilledButton, 'أؤكد الحذف النهائي'),
        )
        .onPressed!;
    repo.switchTo('B');
    await tester.pumpAndSettle();
    expect(find.text('أؤكد الحذف النهائي'), findsNothing);
    confirm();
    await tester.pumpAndSettle();
    expect(repo.deletions, 0);
    expect(find.text('تغيرت جلسة الحساب'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets(
    'profile clears visible private contact and stale save callback on account switch',
    (tester) async {
      final repo = SessionRepository();
      addTearDown(repo.sessions.close);
      await tester.pumpWidget(MaterialApp(home: ProfilePage(repository: repo)));
      await tester.pumpAndSettle();
      final saveProfile = tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'حفظ الملف والإقرار'),
          )
          .onPressed!;
      await tester.scrollUntilVisible(
        find.text('حفظ تفضيل مشاركة التواصل'),
        350,
        scrollable: find.byType(Scrollable).first,
      );
      final saveContact = tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'حفظ تفضيل مشاركة التواصل'),
          )
          .onPressed!;
      repo.switchTo('B');
      saveProfile();
      saveContact();
      await tester.pumpAndSettle();
      expect(repo.contactsSaved, 0);
      expect(repo.profileSaves, 0);
      expect(find.textContaining('private-A-contact'), findsNothing);
      expect(find.text('تغيرت جلسة الحساب'), findsOneWidget);
    },
  );

  testWidgets(
    'late private profile response cannot revive screen after logout and sign in',
    (tester) async {
      final repo = SessionRepository()
        ..pendingContact = Completer<Result<ContactData?>>();
      addTearDown(repo.sessions.close);
      await tester.pumpWidget(MaterialApp(home: ProfilePage(repository: repo)));
      await tester.pump();
      repo.switchTo(null);
      repo.switchTo('A');
      repo.pendingContact!.complete(
        const Result.success(ContactData('phone', 'late-private-A', true)),
      );
      await tester.pumpAndSettle();
      expect(find.text('تغيرت جلسة الحساب'), findsOneWidget);
      expect(find.textContaining('late-private-A'), findsNothing);
    },
  );

  testWidgets(
    'post-delete logout clears profile retained beneath deletion route',
    (tester) async {
      final repo = SessionRepository();
      addTearDown(repo.sessions.close);
      await tester.pumpWidget(MaterialApp(home: ProfilePage(repository: repo)));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('حذف الحساب نهائياً'),
        350,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('حذف الحساب نهائياً'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'حذف حسابي');
      await tester.ensureVisible(find.text('طلب حذف حسابي نهائياً'));
      await tester.tap(find.text('طلب حذف حسابي نهائياً'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('أؤكد الحذف النهائي'));
      await tester.pumpAndSettle();
      expect(repo.deletions, 1);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('تغيرت جلسة الحساب'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
    },
  );

  testWidgets(
    'all private routes invalidate on account change and do not revive',
    (tester) async {
      final repo = SessionRepository();
      addTearDown(repo.sessions.close);
      final pages = <Widget>[
        DetailPage(repository: repo, entry: entry),
        PublicationPage(repository: repo, kind: FeedKind.request),
        BlockedUsersPage(repository: repo),
        ReportPage(
          repository: repo,
          kind: ReportKind.account,
          targetId: 'target',
        ),
        ModerationQueuePage(repository: repo),
        ReviewReportPage(repository: repo, report: report),
        UploadImagePage(repository: repo, entry: entry),
      ];
      for (var i = 0; i < pages.length; i++) {
        repo.user = 'A';
        await tester.pumpWidget(
          KeyedSubtree(
            key: ValueKey(i),
            child: MaterialApp(home: pages[i]),
          ),
        );
        await tester.pumpAndSettle();
        repo.switchTo('B');
        await tester.pumpAndSettle();
        expect(
          find.text('تغيرت جلسة الحساب'),
          findsOneWidget,
          reason: 'page $i',
        );
        expect(find.textContaining('private-blocked-id'), findsNothing);
        expect(find.text('هدف خاص'), findsNothing);
        repo.switchTo('A');
        await tester.pumpAndSettle();
        expect(find.text('تغيرت جلسة الحساب'), findsOneWidget);
      }
    },
  );

  testWidgets(
    'moderation dialog and late queue results remain tied to original account',
    (tester) async {
      final repo = SessionRepository();
      addTearDown(repo.sessions.close);
      await tester.pumpWidget(
        MaterialApp(
          home: ReviewReportPage(repository: repo, report: report),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'سبب مراجعة واضح');
      await tester.ensureVisible(find.text('تعيين الحالة: تمت المعالجة'));
      await tester.tap(find.text('تعيين الحالة: تمت المعالجة'));
      await tester.pumpAndSettle();
      final confirm = tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'تأكيد الإجراء'),
          )
          .onPressed!;
      repo.switchTo('B');
      await tester.pumpAndSettle();
      expect(find.text('تأكيد الإجراء'), findsNothing);
      expect(find.textContaining('سيُسجل هذا الإجراء'), findsNothing);
      confirm();
      await tester.pumpAndSettle();
      expect(repo.actions, 0);
      repo.user = 'A';
      repo.pendingReports = Completer<Result<List<ModerationReport>>>();
      await tester.pumpWidget(
        MaterialApp(home: ModerationQueuePage(repository: repo)),
      );
      await tester.pump();
      repo.switchTo(null);
      repo.pendingReports!.complete(Result.success([report]));
      await tester.pumpAndSettle();
      expect(find.textContaining('بلاغ خاص'), findsNothing);
      expect(find.text('تغيرت جلسة الحساب'), findsOneWidget);
    },
  );
  testWidgets(
    'account sheet closes on identity change and rejects stale navigation callback',
    (tester) async {
      final repo = SessionRepository();
      addTearDown(repo.sessions.close);
      await tester.pumpWidget(BirdsApp(repository: repo));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('الحساب والإعدادات'));
      await tester.pumpAndSettle();
      final profile = tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'الملف الشخصي وإعدادات التواصل'),
          )
          .onPressed!;
      repo.switchTo('B');
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      profile();
      await tester.pumpAndSettle();
      expect(find.byType(ProfilePage), findsNothing);
    },
  );

  testWidgets(
    'unverifiable auth stream clears private profile without exposing stream error',
    (tester) async {
      final repo = SessionRepository();
      addTearDown(repo.sessions.close);
      await tester.pumpWidget(MaterialApp(home: ProfilePage(repository: repo)));
      await tester.pumpAndSettle();
      repo.sessions.addError(StateError('token=secret'));
      await tester.pumpAndSettle();
      expect(find.text('تغيرت جلسة الحساب'), findsOneWidget);
      expect(find.textContaining('private-A-contact'), findsNothing);
      expect(find.textContaining('secret'), findsNothing);
    },
  );
  testWidgets(
    'feed snapshot cannot initialize under B after tap before first route frame',
    (tester) async {
      final repo = SessionRepository()..showFeed = true;
      addTearDown(repo.sessions.close);
      await tester.pumpWidget(BirdsApp(repository: repo));
      await tester.pumpAndSettle();
      await tester.tap(find.text('عنوان خاص بالحساب A'));
      repo.switchTo('B');
      await tester.pumpAndSettle();
      expect(find.byType(DetailPage), findsNothing);
      expect(find.text('عنوان خاص بالحساب A'), findsNothing);
      expect(find.text('تغيرت جلسة الحساب'), findsOneWidget);
    },
  );

  testWidgets(
    'private report navigation rejects both queued builds and stale parent callbacks',
    (tester) async {
      final repo = SessionRepository()..showReports = true;
      addTearDown(repo.sessions.close);
      for (final staleCallback in [false, true]) {
        repo.user = 'A';
        await tester.pumpWidget(
          KeyedSubtree(
            key: ValueKey(staleCallback),
            child: MaterialApp(home: ModerationQueuePage(repository: repo)),
          ),
        );
        await tester.pumpAndSettle();
        final open = tester.widget<ListTile>(find.byType(ListTile)).onTap!;
        if (staleCallback) {
          repo.switchTo('B');
          await tester.pumpAndSettle();
          open();
        } else {
          open();
          repo.switchTo('B');
        }
        await tester.pumpAndSettle();
        expect(find.byType(ReviewReportPage), findsNothing);
        expect(find.textContaining('بلاغ خاص'), findsNothing);
        expect(find.text('تغيرت جلسة الحساب'), findsOneWidget);
      }
    },
  );
  testWidgets(
    'old feed tile callback cannot borrow B completed feed scope before repaint',
    (tester) async {
      final repo = SessionRepository()..showFeed = true;
      addTearDown(repo.sessions.close);
      await tester.pumpWidget(BirdsApp(repository: repo));
      await tester.pumpAndSettle();
      final oldTap = tester.widget<ListTile>(find.byType(ListTile)).onTap!;
      repo.switchTo('B');
      await tester.idle();
      oldTap();
      await tester.pumpAndSettle();
      expect(find.byType(DetailPage), findsNothing);
      expect(find.text('عنوان خاص بالحساب A'), findsNothing);
      expect(find.byType(HomePage), findsOneWidget);
    },
  );
}
