import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sudan_birds/app.dart';
import 'package:sudan_birds/domain.dart';

class FailingRepository extends PreviewRepository {
  bool fail = true;
  @override
  Future<Result<List<FeedEntry>>> feed(
    FeedKind kind,
    FeedFilter filter,
  ) async => fail
      ? const Result.failure(AppFailure('تعذر الاتصال'))
      : const Result.success([]);
}

class RecordingRepository extends PreviewRepository {
  int publishes = 0;
  @override
  bool get signedIn => true;
  @override
  Future<Result<FeedEntry>> savePublication(
    Publication publication, {
    FeedEntry? existing,
  }) async {
    publishes++;
    return const Result.failure(AppFailure('test failure'));
  }
}

void main() {
  testWidgets('exactly two Arabic tabs, RTL and honest preview', (
    tester,
  ) async {
    await tester.pumpWidget(BirdsApp(repository: PreviewRepository()));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationDestination), findsNWidgets(2));
    expect(find.text('طلبات'), findsOneWidget);
    expect(find.text('معروضات'), findsOneWidget);
    expect(find.text('محتوى تعليمي'), findsNothing);
    expect(find.byIcon(Icons.menu_book), findsNothing);
    expect(
      Directionality.of(tester.element(find.byType(NavigationBar))),
      TextDirection.rtl,
    );
    expect(find.textContaining('لا بيانات تجريبية وهمية'), findsOneWidget);
    await tester.tap(find.text('معروضات'));
    await tester.pumpAndSettle();
    expect(find.text('نوع الطيور والموقع وبقية الفلاتر'), findsOneWidget);
    expect(find.byIcon(Icons.favorite), findsNothing);
  });
  testWidgets('listing details retain safety and contact without a timeline', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: DetailPage(
          repository: PreviewRepository(),
          entry: FeedEntry(
            id: 'listing',
            title: 'عرض طيور',
            body: 'وصف الإعلان',
            ownerId: 'owner',
            kind: FeedKind.offer,
            createdAt: DateTime.utc(2026),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('طلب وسيلة التواصل'), findsOneWidget);
    expect(find.text('إبلاغ عن الحساب'), findsOneWidget);
    expect(find.text('حظر صاحب المحتوى'), findsOneWidget);
    expect(find.text('الردود'), findsNothing);
    expect(find.text('إرسال الرد'), findsNothing);
    expect(find.text('سبب الإبلاغ'), findsOneWidget);
    await tester.tap(find.text('طلب وسيلة التواصل'));
    await tester.pumpAndSettle();
    expect(find.text('سجّل الدخول لطلب وسيلة التواصل.'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
  });
  testWidgets('publishing is auth gated in preview', (tester) async {
    await tester.pumpWidget(BirdsApp(repository: PreviewRepository()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('إضافة طلب'));
    await tester.pumpAndSettle();
    expect(find.text('الدخول بالبريد وكلمة المرور'), findsOneWidget);
    expect(find.text('الدخول باستخدام Google'), findsNothing);
    expect(find.text('الدخول باستخدام Apple'), findsNothing);
    expect(find.byType(PublicationPage), findsNothing);
  });
  testWidgets('feed failure presents working retry', (tester) async {
    final repo = FailingRepository();
    await tester.pumpWidget(BirdsApp(repository: repo));
    await tester.pumpAndSettle();
    expect(find.text('تعذر الاتصال'), findsOneWidget);
    repo.fail = false;
    await tester.tap(find.text('إعادة المحاولة'));
    await tester.pumpAndSettle();
    expect(find.text('تعذر الاتصال'), findsNothing);
  });
  testWidgets('large Arabic text does not throw in main view', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.8;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(BirdsApp(repository: PreviewRepository()));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets('incomplete offer form does not send data', (tester) async {
    final repo = RecordingRepository();
    await tester.pumpWidget(BirdsApp(repository: repo));
    await tester.pumpAndSettle();
    await tester.tap(find.text('معروضات'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('إضافة عرض'));
    await tester.pumpAndSettle();
    final publish = find.widgetWithText(FilledButton, 'نشر');
    await tester.scrollUntilVisible(
      publish,
      350,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(publish);
    await tester.pumpAndSettle();
    expect(repo.publishes, 0);
    expect(find.byType(PublicationPage), findsOneWidget);
  });
}
