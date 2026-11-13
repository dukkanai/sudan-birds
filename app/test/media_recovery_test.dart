import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:image_picker/image_picker.dart';
import 'package:sudan_birds/domain.dart';
import 'package:sudan_birds/media_screens.dart';

class MemoryPicker extends ImagePicker {
  bool cancel = false, fail = false;
  @override
  Future<XFile?> pickImage({
    required ImageSource source,
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    bool requestFullMetadata = true,
  }) async {
    if (fail) throw StateError('file=/private/hidden');
    if (cancel) return null;
    return XFile.fromData(
      image.encodeJpg(image.Image(width: 8, height: 8)),
      mimeType: 'image/jpeg',
    );
  }
}

class MediaRepository extends PreviewRepository {
  int reserves = 0, puts = 0, completions = 0, urlCalls = 0;
  bool failCount = false,
      failPut = true,
      failComplete = false,
      unknownReserve = false;
  Completer<Result<bool>>? pendingPut;
  final urlRequests = <Completer<Result<String>>>[];
  @override
  bool get signedIn => true;
  @override
  String get currentUserId => 'owner';
  @override
  Future<Result<List<MediaAsset>>> media(FeedEntry entry) async => failCount
      ? const Result.failure(AppFailure('تعذر عد الصور'))
      : Result.success(
          completions > 0 && !failComplete
              ? [const MediaAsset('new', 'وصف')]
              : [],
        );
  @override
  Future<Result<UploadIntent>> reserveImage(FeedEntry entry, int bytes) async {
    reserves++;
    if (unknownReserve) {
      return const Result.failure(
        AppFailure('نتيجة حجز غير مؤكدة', outcomeUnknown: true),
      );
    }
    return Result.success(
      UploadIntent(
        id: 'intent',
        url: 'https://example.test/image',
        expiresAt: DateTime.now().add(const Duration(minutes: 2)),
        headers: const {},
      ),
    );
  }

  @override
  Future<Result<bool>> putImage(UploadIntent intent, Uint8List bytes) async {
    puts++;
    return pendingPut?.future ??
        (failPut
            ? const Result.failure(AppFailure('انقطع رفع الصورة'))
            : const Result.success(true));
  }

  @override
  Future<Result<MediaAsset>> completeImage(
    UploadIntent intent,
    String altText,
  ) async {
    completions++;
    return failComplete
        ? const Result.failure(AppFailure('التحقق لم يكتمل'))
        : Result.success(MediaAsset('new', altText));
  }

  @override
  Future<Result<String>> imageUrl(String id) {
    urlCalls++;
    final pending = Completer<Result<String>>();
    urlRequests.add(pending);
    return pending.future;
  }
}

final listing = FeedEntry(
  id: 'listing',
  title: 'إعلان',
  body: 'وصف',
  ownerId: 'owner',
  kind: FeedKind.offer,
  createdAt: DateTime.utc(2026),
);

Future<void> choose(WidgetTester tester) async {
  final button = tester.widget<OutlinedButton>(
    find.widgetWithText(OutlinedButton, 'اختيار صورة من المعرض'),
  );
  final action = button.onPressed! as Future<void> Function();
  await tester.runAsync(action);
  await tester.pumpAndSettle();
}

Future<void> showUpload(
  WidgetTester tester,
  MediaRepository repo,
  MemoryPicker picker,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: UploadImagePage(repository: repo, entry: listing, picker: picker),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'cancelled picker and unexpected picker error never reserve an upload',
    (tester) async {
      final repo = MediaRepository();
      final picker = MemoryPicker()..cancel = true;
      await showUpload(tester, repo, picker);
      await choose(tester);
      expect(find.byType(Image), findsNothing);
      expect(repo.reserves, 0);
      picker.cancel = false;
      picker.fail = true;
      await choose(tester);
      expect(find.textContaining('تعذر إتمام العملية'), findsOneWidget);
      expect(find.textContaining('/private/hidden'), findsNothing);
      expect(repo.reserves, 0);
    },
  );

  testWidgets(
    'failed image count disables picking until explicit retry succeeds',
    (tester) async {
      final repo = MediaRepository()..failCount = true;
      await showUpload(tester, repo, MemoryPicker());
      expect(
        tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
        isNull,
      );
      repo.failCount = false;
      await tester.tap(find.text('تحديث حالة الصور'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
        isNotNull,
      );
    },
  );

  testWidgets(
    'ambiguous upload can verify prior attempt without reserve or PUT repetition',
    (tester) async {
      final repo = MediaRepository();
      await showUpload(tester, repo, MemoryPicker());
      await choose(tester);
      await tester.enterText(find.byType(TextField), 'طائر كناري أصفر');
      await tester.ensureVisible(find.text('رفع الصورة والتحقق منها'));
      await tester.tap(find.text('رفع الصورة والتحقق منها'));
      await tester.pumpAndSettle();
      expect(repo.reserves, 1);
      expect(repo.puts, 1);
      expect(repo.completions, 0);
      expect(find.textContaining('انقطع رفع الصورة'), findsOneWidget);
      await tester.ensureVisible(
        find.text('التحقق من الرفع السابق دون إعادته'),
      );
      await tester.tap(find.text('التحقق من الرفع السابق دون إعادته'));
      await tester.pumpAndSettle();
      expect(repo.reserves, 1);
      expect(repo.puts, 1);
      expect(repo.completions, 1);
      expect(
        find.text('تحقق الخادم من الصورة وأرفقها بالمحتوى.'),
        findsOneWidget,
      );
      expect(find.text('التحقق من الرفع السابق دون إعادته'), findsNothing);
    },
  );

  testWidgets(
    'successful PUT with failed verification retries completion only',
    (tester) async {
      final repo = MediaRepository()
        ..failPut = false
        ..failComplete = true;
      await showUpload(tester, repo, MemoryPicker());
      await choose(tester);
      await tester.enterText(find.byType(TextField), 'وصف بديل واضح');
      await tester.ensureVisible(find.text('رفع الصورة والتحقق منها'));
      await tester.tap(find.text('رفع الصورة والتحقق منها'));
      await tester.pumpAndSettle();
      expect(repo.puts, 1);
      expect(repo.completions, 1);
      repo.failComplete = false;
      await tester.ensureVisible(find.text('إعادة التحقق والإرفاق'));
      await tester.tap(find.text('إعادة التحقق والإرفاق'));
      await tester.pumpAndSettle();
      expect(repo.puts, 1);
      expect(repo.reserves, 1);
      expect(repo.completions, 2);
    },
  );

  testWidgets(
    'pending upload rejects double submission and recovers thrown failures',
    (tester) async {
      final repo = MediaRepository()..pendingPut = Completer<Result<bool>>();
      await showUpload(tester, repo, MemoryPicker());
      await choose(tester);
      await tester.enterText(find.byType(TextField), 'وصف بديل واضح');
      final callback = tester
          .widget<FilledButton>(find.byType(FilledButton))
          .onPressed!;
      callback();
      callback();
      await tester.pump();
      expect(repo.reserves, 1);
      expect(repo.puts, 1);
      expect(tester.widget<PopScope>(find.byType(PopScope)).canPop, false);
      repo.pendingPut!.completeError(StateError('authorization=secret'));
      await tester.pumpAndSettle();
      expect(find.textContaining('secret'), findsNothing);
      expect(tester.widget<PopScope>(find.byType(PopScope)).canPop, true);
      await tester.scrollUntilVisible(
        find.text('إلغاء اختيار الصورة'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('إلغاء اختيار الصورة'));
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsNothing);
      expect(find.textContaining('لا نؤكد نشر صورة'), findsOneWidget);
      expect(repo.completions, 0);
    },
  );

  testWidgets(
    'URL error retries and older signed URL result cannot overwrite new media',
    (tester) async {
      final repo = MediaRepository();
      Widget page(String id) => MaterialApp(
        home: Scaffold(
          body: PrivateImage(repository: repo, asset: MediaAsset(id, 'وصف')),
        ),
      );
      await tester.pumpWidget(page('old'));
      expect(repo.urlCalls, 1);
      await tester.pumpWidget(page('new'));
      expect(repo.urlCalls, 2);
      repo.urlRequests[1].complete(
        const Result.failure(AppFailure('انتهى الرابط')),
      );
      await tester.pumpAndSettle();
      repo.urlRequests[0].complete(
        const Result.success('https://example.test/private-old'),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsNothing);
      expect(find.text('انتهى الرابط'), findsOneWidget);
      final callback = tester
          .widget<TextButton>(find.byType(TextButton))
          .onPressed!;
      callback();
      await tester.pump();
      expect(repo.urlCalls, 3);
      repo.urlRequests.last.completeError(StateError('signed-url=private'));
      await tester.pumpAndSettle();
      expect(find.textContaining('private'), findsNothing);
      expect(find.text('تجديد رابط الصورة'), findsOneWidget);
    },
  );
  testWidgets(
    'unknown reservation freezes resubmission without a second reservation or PUT',
    (tester) async {
      final repo = MediaRepository()..unknownReserve = true;
      await showUpload(tester, repo, MemoryPicker());
      await choose(tester);
      await tester.enterText(find.byType(TextField), 'وصف بديل واضح');
      final submit = tester
          .widget<FilledButton>(find.byType(FilledButton))
          .onPressed!;
      submit();
      await tester.pumpAndSettle();
      expect(repo.reserves, 1);
      expect(repo.puts, 0);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      repo.unknownReserve = false;
      submit();
      await tester.pumpAndSettle();
      expect(repo.reserves, 1);
      expect(repo.puts, 0);
    },
  );
}
