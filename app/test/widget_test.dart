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
  testWidgets('exactly three Arabic tabs, RTL and honest preview', (
    tester,
  ) async {
    await tester.pumpWidget(BirdsApp(repository: PreviewRepository()));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationDestination), findsNWidgets(3));
    expect(find.text('طلبات'), findsOneWidget);
    expect(find.text('معروضات'), findsOneWidget);
    expect(find.text('محتوى تعليمي'), findsOneWidget);
    expect(
      Directionality.of(tester.element(find.byType(NavigationBar))),
      TextDirection.rtl,
    );
    expect(find.textContaining('لا بيانات تجريبية وهمية'), findsOneWidget);
    await tester.tap(find.text('محتوى تعليمي'));
    await tester.pumpAndSettle();
    expect(find.text('نوع المحتوى والموقع وبقية الفلاتر'), findsOneWidget);
    expect(find.byIcon(Icons.favorite), findsNothing);
  });
  testWidgets('publishing is auth gated in preview', (tester) async {
    await tester.pumpWidget(BirdsApp(repository: PreviewRepository()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('إضافة طلب'));
    await tester.pumpAndSettle();
    expect(find.text('الدخول باستخدام Google'), findsOneWidget);
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
