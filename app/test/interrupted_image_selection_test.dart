import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:sudan_birds/app.dart';
import 'package:sudan_birds/domain.dart';
import 'package:sudan_birds/interrupted_image_selection.dart';
import 'package:sudan_birds/screens.dart';

class RecoveryPicker extends ImagePicker {
  int calls = 0;
  LostDataResponse response = LostDataResponse.empty();
  bool fail = false;
  Completer<LostDataResponse>? pending;

  @override
  Future<LostDataResponse> retrieveLostData() async {
    calls++;
    if (fail) throw StateError('private-file-path-and-token');
    return pending?.future ?? response;
  }
}

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('empty Android recovery is consumed once without a warning', () async {
    final picker = RecoveryPicker();
    expect(await discardInterruptedImageSelection(picker: picker), isNull);
    expect(picker.calls, 1);
  });

  test('lost file is discarded without reading or assigning it', () async {
    final picker = RecoveryPicker()
      ..response = LostDataResponse(
        type: RetrieveType.image,
        files: [XFile('/nonexistent/do-not-read-or-attach.jpg')],
      );
    final notice = await discardInterruptedImageSelection(picker: picker);
    expect(notice, contains('لم تُرفق أو تُرفع'));
    expect(notice, contains('افتح الإعلان المطلوب'));
    expect(notice, isNot(contains('do-not-read')));
    expect(picker.calls, 1);
  });

  test('native recovery failure is safe and requests reselection', () async {
    final picker = RecoveryPicker()
      ..response = LostDataResponse(
        exception: PlatformException(
          code: 'picker-failed',
          message: 'private-file-path-and-token',
        ),
      );
    final notice = await discardInterruptedImageSelection(picker: picker);
    expect(notice, contains('اختر الصورة مجدداً'));
    expect(notice, isNot(contains('private-file')));
  });

  test('thrown platform failure never leaks paths or credentials', () async {
    final picker = RecoveryPicker()..fail = true;
    final notice = await discardInterruptedImageSelection(picker: picker);
    expect(notice, contains('تعذر التحقق'));
    expect(notice, isNot(contains('private-file')));
  });

  testWidgets('unresponsive recovery cannot indefinitely block startup', (
    tester,
  ) async {
    final picker = RecoveryPicker()..pending = Completer<LostDataResponse>();
    final pending = discardInterruptedImageSelection(picker: picker);
    await tester.pump(const Duration(seconds: 5));
    expect(await pending, contains('تعذر التحقق'));
    picker.pending!.complete(LostDataResponse.empty());
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(picker.calls, 1);
  });

  testWidgets('pending startup recovery does not block or reset navigation', (
    tester,
  ) async {
    final recovery = Completer<String?>();
    await tester.pumpWidget(
      BirdsApp(repository: PreviewRepository(), startupNotice: recovery.future),
    );
    await tester.pumpAndSettle();
    expect(find.byType(NavigationDestination), findsNWidgets(2));
    expect(recovery.isCompleted, false);
    await tester.tap(find.text('نوع الطيور والموقع وبقية الفلاتر'));
    await tester.pumpAndSettle();
    final activeRouteState = tester.state(find.byType(FilterPage));

    const notice = 'افتح الإعلان المطلوب واختر الصورة مجدداً.';
    recovery.complete(notice);
    await tester.pumpAndSettle();
    expect(tester.state(find.byType(FilterPage)), same(activeRouteState));
    expect(find.text('تصفية النتائج'), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text(notice), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('late startup recovery after app disposal has no UI effects', (
    tester,
  ) async {
    final recovery = Completer<String?>();
    await tester.pumpWidget(
      BirdsApp(repository: PreviewRepository(), startupNotice: recovery.future),
    );
    await tester.pumpAndSettle();
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    recovery.complete('تنبيه اختيار صورة سابق');
    await tester.pumpAndSettle();
    expect(find.text('تنبيه اختيار صورة سابق'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test('iOS does not call Android-only recovery', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final picker = RecoveryPicker();
    expect(await discardInterruptedImageSelection(picker: picker), isNull);
    expect(picker.calls, 0);
  });
}
