import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sudan_birds/app.dart';
import 'package:sudan_birds/domain.dart';
import 'package:sudan_birds/screens.dart';
import 'package:sudan_birds/moderation_screens.dart';

FeedEntry entry(String id, {FeedKind kind = FeedKind.request}) => FeedEntry(
  id: id,
  title: 'إعلان $id',
  body: 'وصف واضح للطيور',
  kind: kind,
  ownerId: 'owner',
  birdId: 1,
  locationId: 1,
  age: 2,
  price: 100,
  currency: 'SDG',
  createdAt: DateTime.utc(2026),
);

class FlowRepository extends PreviewRepository {
  bool authenticated = true, failTaxonomy = false, failContact = false;
  int saves = 0, reveals = 0, blocks = 0, reports = 0, actions = 0;
  Publication? saved;
  Completer<Result<FeedEntry>>? pendingSave;
  Completer<Result<ContactData?>>? pendingReveal;
  Completer<Result<bool>>? pendingBlock, pendingReport, pendingAction;
  final sessions = StreamController<void>.broadcast(sync: true);
  @override
  bool get isPreview => false;
  @override
  bool get signedIn => authenticated;
  @override
  String? get currentUserId => authenticated ? 'owner' : null;
  @override
  Stream<void> get authChanges => sessions.stream;
  @override
  Future<Result<ProfileData?>> profile() async =>
      const Result.success(ProfileData('مربي الطيور', true));
  @override
  Future<Result<ContactData?>> contact() async => failContact
      ? const Result.failure(AppFailure('تعذر تحميل التواصل'))
      : const Result.success(ContactData('phone', '123456', false));
  @override
  Future<Result<Taxonomy>> taxonomy() async => failTaxonomy
      ? const Result.failure(AppFailure('تعذر تحميل القوائم'))
      : const Result.success(
          Taxonomy(
            birds: [NamedOption(1, 'كناري')],
            locations: [LocationOption(1, 'الخرطوم', 'الخرطوم')],
          ),
        );
  @override
  Future<Result<FeedEntry>> savePublication(
    Publication publication, {
    FeedEntry? existing,
  }) async {
    saves++;
    saved = publication;
    return pendingSave?.future ?? Result.success(existing ?? entry('new'));
  }

  @override
  Future<Result<ContactData?>> revealContact(String id, bool confirmed) async {
    reveals++;
    return pendingReveal?.future ??
        const Result.success(ContactData('phone', '123456', true));
  }

  @override
  Future<Result<List<String>>> blockedUsers() async =>
      const Result.success(['blocked']);
  @override
  Future<Result<bool>> block(String id, bool blocked) async {
    blocks++;
    return pendingBlock?.future ?? const Result.success(true);
  }

  @override
  Future<Result<bool>> reportTarget(
    ReportKind kind,
    String id,
    String reason,
  ) async {
    reports++;
    return pendingReport?.future ?? const Result.success(true);
  }

  @override
  Future<Result<ModerationTarget?>> moderationTarget(
    ModerationReport report,
  ) async => const Result.success(
    ModerationTarget(
      id: 'target',
      kind: ReportKind.listing,
      title: 'محتوى للمراجعة',
      body: 'نص المحتوى',
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
    return pendingAction?.future ?? const Result.success(true);
  }
}

class FeedRepository extends PreviewRepository {
  final calls =
      <
        ({
          FeedKind kind,
          FeedFilter filter,
          Completer<Result<List<FeedEntry>>> pending,
        })
      >[];
  @override
  bool get isPreview => false;
  @override
  Future<Result<List<FeedEntry>>> feed(FeedKind kind, FeedFilter filter) {
    final pending = Completer<Result<List<FeedEntry>>>();
    calls.add((kind: kind, filter: filter, pending: pending));
    return pending.future;
  }
}

class AuthRepository extends PreviewRepository {
  int attempts = 0;
  final pending = Completer<Result<bool>>();
  @override
  Future<Result<bool>> signIn(String provider) {
    attempts++;
    return pending.future;
  }
}

class QueueRepository extends PreviewRepository {
  final calls =
      <
        ({
          String state,
          ModerationReport? before,
          Completer<Result<List<ModerationReport>>> pending,
        })
      >[];
  @override
  Future<Result<List<ModerationReport>>> moderationReports(
    String state, {
    ModerationReport? before,
  }) {
    final pending = Completer<Result<List<ModerationReport>>>();
    calls.add((state: state, before: before, pending: pending));
    return pending.future;
  }
}

Future<void> openPage(WidgetTester tester, Widget page) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.push<void>(
              context,
              MaterialPageRoute(builder: (_) => page),
            ),
            child: const Text('افتح'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('افتح'));
  await tester.pumpAndSettle();
}

Future<void> visibleTap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pump();
}

void main() {
  test(
    'UI guard preserves typed failures and hides unexpected exceptions',
    () async {
      final typed = await guardResult<bool>(
        () async => const Result.failure(AppFailure('اختبر الاتصال')),
      );
      expect(typed.failure!.message, 'اختبر الاتصال');
      final unexpected = await guardResult<bool>(
        () => throw StateError('token=private'),
      );
      expect(unexpected.isSuccess, false);
      expect(unexpected.failure!.message, isNot(contains('private')));
      final pending = Completer<Result<bool>>();
      final future = guardResult(() => pending.future);
      pending.complete(const Result.success(true));
      expect((await future).value, true);
    },
  );

  testWidgets('older feed completion cannot replace a newer selected tab', (
    tester,
  ) async {
    final repo = FeedRepository();
    await tester.pumpWidget(BirdsApp(repository: repo));
    await tester.pump();
    await tester.tap(find.text('معروضات'));
    await tester.pump();
    expect(repo.calls.length, 2);
    repo.calls[1].pending.complete(
      Result.success([entry('new', kind: FeedKind.offer)]),
    );
    await tester.pumpAndSettle();
    repo.calls[0].pending.complete(Result.success([entry('old')]));
    await tester.pumpAndSettle();
    expect(find.text('إعلان new'), findsOneWidget);
    expect(find.text('إعلان old'), findsNothing);
  });

  testWidgets(
    'pagination retains results and retries same applied search and cursor',
    (tester) async {
      final repo = FeedRepository();
      await tester.pumpWidget(BirdsApp(repository: repo));
      repo.calls.single.pending.complete(
        Result.success(List.generate(20, (i) => entry('$i'))),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'بحث لم يطبق');
      await tester.scrollUntilVisible(
        find.text('تحميل المزيد'),
        500,
        scrollable: find.byType(Scrollable).first,
        maxScrolls: 30,
      );
      final callback = tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'تحميل المزيد'))
          .onPressed!;
      callback();
      callback();
      await tester.pump();
      expect(repo.calls.length, 2);
      expect(repo.calls.last.filter.search, '');
      expect(repo.calls.last.filter.before!.id, '19');
      repo.calls.last.pending.complete(
        const Result.failure(AppFailure('انقطع الاتصال')),
      );
      await tester.pumpAndSettle();
      expect(find.text('إعلان 19'), findsOneWidget);
      expect(find.text('انقطع الاتصال'), findsOneWidget);
      await visibleTap(tester, find.text('إعادة تحميل المزيد'));
      expect(repo.calls.length, 3);
      expect(repo.calls.last.filter.before!.id, '19');
      repo.calls.last.pending.complete(
        Result.success([entry('19'), entry('20')]),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('وصلت إلى نهاية النتائج.'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('إعلان 19'), findsOneWidget);
      expect(find.text('إعلان 20'), findsOneWidget);
      expect(find.text('انقطع الاتصال'), findsNothing);
    },
  );

  testWidgets(
    'failed profile prerequisites cannot create a blank editable profile',
    (tester) async {
      final repo = FlowRepository()..failContact = true;
      addTearDown(repo.sessions.close);
      await openPage(tester, ProfilePage(repository: repo));
      expect(find.text('تعذر تحميل التواصل'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      repo.failContact = false;
      await tester.tap(find.text('إعادة المحاولة'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, 'اسم العرض العام'), findsOneWidget);
      expect(find.text('مربي الطيور'), findsOneWidget);
    },
  );

  testWidgets('existing selected taxonomy survives a failed load and retry', (
    tester,
  ) async {
    final repo = FlowRepository()..failTaxonomy = true;
    addTearDown(repo.sessions.close);
    await openPage(
      tester,
      PublicationPage(
        repository: repo,
        kind: FeedKind.offer,
        existing: entry('edit', kind: FeedKind.offer),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(Form), findsNothing);
    repo.failTaxonomy = false;
    await tester.tap(find.text('إعادة المحاولة'));
    await tester.pumpAndSettle();
    expect(find.byType(Form), findsOneWidget);
    expect(find.text('كناري'), findsOneWidget);
    expect(find.text('إعلان edit'), findsOneWidget);
  });

  testWidgets(
    'edit and close lock repeats and back, then freeze uncertain saves with draft intact',
    (tester) async {
      final repo = FlowRepository()
        ..pendingSave = Completer<Result<FeedEntry>>();
      addTearDown(repo.sessions.close);
      await openPage(
        tester,
        PublicationPage(
          repository: repo,
          kind: FeedKind.request,
          existing: entry('edit'),
        ),
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'العنوان'),
        'عنوان معدل',
      );
      await tester.scrollUntilVisible(
        find.text('حالة الإعلان'),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.widgetWithText(DropdownButtonFormField<String>, 'حالة الإعلان'),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(DropdownButtonFormField<String>, 'حالة الإعلان'),
      );

      await tester.pumpAndSettle();
      await tester.tap(find.text('مغلق').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('حفظ التعديل'));
      final callback = tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'حفظ التعديل'),
          )
          .onPressed!;
      callback();
      callback();
      await tester.pump();
      expect(repo.saves, 1);
      expect(repo.saved!.status, 'closed');
      final nav = tester.state<NavigatorState>(find.byType(Navigator));
      await nav.maybePop();
      await tester.pump();
      expect(find.byType(PublicationPage), findsOneWidget);
      repo.pendingSave!.completeError(StateError('secret=never-show'));
      await tester.pumpAndSettle();
      expect(find.textContaining('لم تتأكد نتيجة العملية'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'حفظ التعديل'),
            )
            .onPressed,
        isNull,
      );
      expect(find.textContaining('never-show'), findsNothing);
      await tester.scrollUntilVisible(
        find.text('عنوان معدل'),
        -400,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('عنوان معدل'), findsOneWidget);
      await nav.maybePop();
      await tester.pumpAndSettle();
      expect(find.byType(PublicationPage), findsNothing);
      expect(repo.saves, 1);
    },
  );

  testWidgets('back from an edited draft does not write anything', (
    tester,
  ) async {
    final repo = FlowRepository();
    addTearDown(repo.sessions.close);
    await openPage(
      tester,
      PublicationPage(
        repository: repo,
        kind: FeedKind.request,
        existing: entry('edit'),
      ),
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'العنوان'),
      'غير محفوظ',
    );
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(repo.saves, 0);
  });

  testWidgets(
    'filter cancellation keeps original filter and failed taxonomy retries safely',
    (tester) async {
      final repo = FlowRepository()..failTaxonomy = true;
      addTearDown(repo.sessions.close);
      const original = FeedFilter(
        birdId: 1,
        locationId: 1,
        minPrice: 12,
        currency: 'SDG',
      );
      await openPage(
        tester,
        FilterPage(repository: repo, kind: FeedKind.offer, initial: original),
      );
      expect(find.byType(DropdownButtonFormField<int>), findsNothing);
      expect(tester.takeException(), isNull);
      repo.failTaxonomy = false;
      await tester.tap(find.text('إعادة المحاولة'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'الحد الأدنى للسعر أو الميزانية'),
        '999',
      );
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(original.minPrice, 12);
      expect(find.byType(FilterPage), findsNothing);
    },
  );

  testWidgets('contact confirmation opens once and cancel makes no request', (
    tester,
  ) async {
    final repo = FlowRepository();
    addTearDown(repo.sessions.close);
    await openPage(
      tester,
      DetailPage(repository: repo, entry: entry('listing')),
    );
    final callback = tester
        .widget<OutlinedButton>(
          find.widgetWithText(OutlinedButton, 'طلب وسيلة التواصل'),
        )
        .onPressed!;
    callback();
    callback();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('إلغاء'));
    await tester.pumpAndSettle();
    expect(repo.reveals, 0);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(DetailPage), findsOneWidget);
  });

  testWidgets(
    'session loss suppresses late contact reveal and clears displayed private contact',
    (tester) async {
      final repo = FlowRepository()
        ..pendingReveal = Completer<Result<ContactData?>>();
      addTearDown(repo.sessions.close);
      await openPage(
        tester,
        DetailPage(repository: repo, entry: entry('listing')),
      );
      await tester.tap(
        find.widgetWithText(OutlinedButton, 'طلب وسيلة التواصل'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'طلب التواصل'));
      await tester.pump();
      repo.authenticated = false;
      repo.sessions.add(null);
      repo.pendingReveal!.complete(
        const Result.success(ContactData('phone', 'private-contact', true)),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('private-contact'), findsNothing);
      repo.authenticated = true;
      repo.sessions.add(null);
      repo.pendingReveal = null;
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        MaterialApp(
          home: DetailPage(
            key: const ValueKey('reopened'),
            repository: repo,
            entry: entry('listing'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(OutlinedButton, 'طلب وسيلة التواصل'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'طلب التواصل'));
      await tester.pumpAndSettle();
      expect(find.text('phone: 123456'), findsOneWidget);
      repo.authenticated = false;
      repo.sessions.add(null);
      await tester.pumpAndSettle();
      expect(find.text('phone: 123456'), findsNothing);
    },
  );

  testWidgets(
    'unblock repeated clicks send once and failure keeps the blocked account',
    (tester) async {
      final repo = FlowRepository()..pendingBlock = Completer<Result<bool>>();
      addTearDown(repo.sessions.close);
      await openPage(tester, BlockedUsersPage(repository: repo));
      final callback = tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'إلغاء الحظر'))
          .onPressed!;
      callback();
      callback();
      await tester.pump();
      expect(repo.blocks, 1);
      repo.pendingBlock!.completeError(StateError('token=hidden'));
      await tester.pumpAndSettle();
      expect(find.text('blocked'), findsOneWidget);
      expect(find.textContaining('تعذر إتمام العملية'), findsOneWidget);
      expect(find.textContaining('token='), findsNothing);
    },
  );

  testWidgets('uncertain report keeps the reason and freezes duplicate sends', (
    tester,
  ) async {
    final repo = FlowRepository()..pendingReport = Completer<Result<bool>>();
    addTearDown(repo.sessions.close);
    await openPage(
      tester,
      ReportPage(
        repository: repo,
        kind: ReportKind.account,
        targetId: 'target',
      ),
    );
    await tester.enterText(find.byType(TextField), 'سبب واضح للمراجعة');
    final callback = tester
        .widget<FilledButton>(find.byType(FilledButton))
        .onPressed!;
    callback();
    callback();
    await tester.pump();
    await tester.state<NavigatorState>(find.byType(Navigator)).maybePop();
    await tester.pump();
    expect(find.byType(ReportPage), findsOneWidget);
    expect(repo.reports, 1);
    repo.pendingReport!.completeError(StateError('private'));
    await tester.pumpAndSettle();
    expect(find.text('سبب واضح للمراجعة'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
  });

  testWidgets(
    'moderation cancellation sends nothing and successful status is shown once',
    (tester) async {
      final repo = FlowRepository()..pendingAction = Completer<Result<bool>>();
      addTearDown(repo.sessions.close);
      await openPage(
        tester,
        ReviewReportPage(
          repository: repo,
          report: ModerationReport(
            id: 'report',
            reason: 'سبب واضح',
            state: 'open',
            createdAt: DateTime.utc(2026),
            kind: ReportKind.listing,
            targetId: 'target',
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'سبب إجراء المراجعة');
      final button = find.widgetWithText(
        TextButton,
        'تعيين الحالة: تمت المعالجة',
      );
      await visibleTap(tester, button);
      await tester.pumpAndSettle();
      await tester.tap(find.text('إلغاء'));
      await tester.pumpAndSettle();
      expect(repo.actions, 0);
      final callback = tester.widget<TextButton>(button).onPressed!;
      callback();
      callback();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.text('تأكيد الإجراء'));
      await tester.pump();
      expect(repo.actions, 1);
      repo.pendingAction!.complete(const Result.success(true));
      await tester.pumpAndSettle();
      expect(find.text('حالة البلاغ: تمت المعالجة'), findsOneWidget);
      expect(tester.widget<TextButton>(button).onPressed, isNull);
    },
  );
  testWidgets(
    'account modal and login reject repeated clicks and recover cancelled or failed login',
    (tester) async {
      final repo = AuthRepository();
      await tester.pumpWidget(BirdsApp(repository: repo));
      await tester.pumpAndSettle();
      final open = tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (w) => w is IconButton && w.tooltip == 'الحساب والإعدادات',
            ),
          )
          .onPressed!;
      open();
      open();
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      await tester.state<NavigatorState>(find.byType(Navigator)).maybePop();
      await tester.pumpAndSettle();
      expect(repo.attempts, 0);
      open();
      await tester.pumpAndSettle();
      final signIn = tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'الدخول باستخدام Google'),
          )
          .onPressed!;
      signIn();
      signIn();
      await tester.pumpAndSettle();
      expect(repo.attempts, 1);
      open();
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      repo.pending.completeError(StateError('token=private'));
      await tester.pumpAndSettle();
      expect(find.textContaining('تعذر إتمام العملية'), findsOneWidget);
      expect(find.textContaining('private'), findsNothing);
      open();
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
    },
  );

  testWidgets(
    'successful edit returns to detail and completed writes are not repeated on back',
    (tester) async {
      final repo = FlowRepository();
      addTearDown(repo.sessions.close);
      await openPage(
        tester,
        DetailPage(repository: repo, entry: entry('edit')),
      );
      await tester.tap(find.text('تعديل المحتوى أو إغلاق الإعلان'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('حفظ التعديل'),
        350,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('حفظ التعديل'));
      await tester.pumpAndSettle();
      expect(repo.saves, 1);
      expect(find.byType(PublicationPage), findsNothing);
      expect(find.byType(DetailPage), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(repo.saves, 1);
    },
  );

  testWidgets(
    'moderation status changes clear stale queue before a failed request',
    (tester) async {
      final repo = QueueRepository();
      await tester.pumpWidget(
        MaterialApp(home: ModerationQueuePage(repository: repo)),
      );
      repo.calls.single.pending.complete(
        Result.success([
          ModerationReport(
            id: 'old',
            reason: 'بلاغ قديم',
            state: 'open',
            createdAt: DateTime.utc(2026),
            kind: ReportKind.listing,
            targetId: 'old',
          ),
        ]),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('بلاغ قديم'), findsOneWidget);
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('تمت المعالجة').last);
      await tester.pump();
      expect(repo.calls.last.state, 'resolved');
      expect(repo.calls.last.before, isNull);
      expect(find.textContaining('بلاغ قديم'), findsNothing);
      repo.calls.last.pending.complete(
        const Result.failure(AppFailure('تعذر تحميل البلاغات')),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('بلاغ قديم'), findsNothing);
      await tester.tap(find.text('إعادة تحميل البلاغات'));
      await tester.pump();
      expect(repo.calls.last.state, 'resolved');
      repo.calls.last.pending.complete(const Result.success([]));
      await tester.pumpAndSettle();
      expect(find.text('لا توجد بلاغات بهذه الحالة.'), findsOneWidget);
    },
  );
}
