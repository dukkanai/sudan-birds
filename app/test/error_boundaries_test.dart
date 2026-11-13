import 'dart:async';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:sudan_birds/app.dart';
import 'package:sudan_birds/domain.dart';
import 'package:sudan_birds/main.dart';
import 'package:sudan_birds/media_screens.dart';
import 'package:sudan_birds/moderation_screens.dart';

class BoundaryRepository extends PreviewRepository {
  String? user = 'A';
  final sessions = StreamController<void>.broadcast(sync: true);
  final feeds = <Completer<Result<List<FeedEntry>>>>[];
  Completer<Result<Taxonomy>>? pendingTaxonomy;
  Completer<Result<bool>>? pendingModerator;
  Completer<Result<DeletionStatus?>>? pendingDeletion;
  bool failModerator = false, failDeletion = false;
  int profiles = 0,
      moderatorCalls = 0,
      deletionCalls = 0,
      mediaCalls = 0,
      authCalls = 0;

  @override
  Future<Result<bool>> signIn(String provider) async {
    authCalls++;
    return const Result.success(true);
  }

  @override
  Future<Result<bool>> signOut() async {
    authCalls++;
    return const Result.success(true);
  }

  @override
  bool get isPreview => false;
  @override
  bool get signedIn => user != null;
  @override
  String? get currentUserId => user;
  @override
  Stream<void> get authChanges => sessions.stream;

  @override
  Future<Result<List<FeedEntry>>> feed(FeedKind kind, FeedFilter filter) {
    final request = Completer<Result<List<FeedEntry>>>();
    feeds.add(request);
    return request.future;
  }

  @override
  Future<Result<Taxonomy>> taxonomy() async =>
      pendingTaxonomy?.future ?? const Result.success(Taxonomy());

  @override
  Future<Result<ProfileData?>> profile() async {
    profiles++;
    return const Result.success(ProfileData('اسم تجريبي', true));
  }

  @override
  Future<Result<List<MediaAsset>>> media(FeedEntry entry) async {
    mediaCalls++;
    return const Result.success([]);
  }

  @override
  Future<Result<bool>> isModerator() async {
    moderatorCalls++;
    return pendingModerator?.future ??
        (failModerator
            ? const Result.failure(AppFailure('تعذر التحقق من المشرف'))
            : const Result.success(true));
  }

  @override
  Future<Result<DeletionStatus?>> deletionStatus() async {
    deletionCalls++;
    return pendingDeletion?.future ??
        (failDeletion
            ? const Result.failure(AppFailure('تعذر التحقق من الحذف'))
            : const Result.success(null));
  }
}

final listing = FeedEntry(
  id: 'synthetic-listing',
  title: 'إعلان خاص بحساب A',
  body: 'وصف تجريبي',
  ownerId: 'A',
  kind: FeedKind.request,
  createdAt: DateTime.utc(2026),
);

class DeferredPicker extends ImagePicker {
  final result = Completer<XFile?>();
  @override
  Future<XFile?> pickImage({
    required ImageSource source,
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    bool requestFullMetadata = true,
  }) => result.future;
}

class ObservedFile extends XFile {
  ObservedFile() : super('/synthetic/never-read.jpg');
  int lengthCalls = 0, readCalls = 0;
  Completer<int>? pendingLength;
  @override
  Future<int> length() async {
    lengthCalls++;
    return pendingLength?.future ?? 4;
  }

  @override
  Future<Uint8List> readAsBytes() async {
    readCalls++;
    throw StateError('file-contents-must-not-be-read');
  }
}

Finder liveMessage(String message) => find.ancestor(
  of: find.text(message),
  matching: find.byWidgetPredicate(
    (widget) => widget is Semantics && widget.properties.liveRegion == true,
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'framework and platform safety nets publish only a safe warning',
    () async {
      final framework = FlutterError.onError;
      final platform = PlatformDispatcher.instance.onError;
      final builder = ErrorWidget.builder;
      try {
        installRuntimeErrorHandlers();
        FlutterError.onError!(
          FlutterErrorDetails(exception: StateError('jwt=private-token')),
        );
        await Future<void>.delayed(Duration.zero);
        expect(runtimeError.value, unexpectedErrorMessage);
        runtimeError.value = null;
        expect(
          PlatformDispatcher.instance.onError!(
            StateError('password=private-password'),
            StackTrace.current,
          ),
          true,
        );
        await Future<void>.delayed(Duration.zero);
        expect(runtimeError.value, unexpectedErrorMessage);
        expect(runtimeError.value, isNot(contains('private-')));
        expect(
          ErrorWidget.builder(
            FlutterErrorDetails(exception: StateError('secret')),
          ),
          isA<UnexpectedErrorView>(),
        );
      } finally {
        FlutterError.onError = framework;
        PlatformDispatcher.instance.onError = platform;
        ErrorWidget.builder = builder;
        runtimeError.value = null;
      }
    },
  );

  testWidgets('global fallback remains accessible in a small large-text area', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      const MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(2)),
        child: Center(
          child: SizedBox(
            width: 200,
            height: 100,
            child: UnexpectedErrorView(),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(SingleChildScrollView), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Semantics && widget.properties.liveRegion == true,
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('تحقق من حالة الطلب قبل تكراره'),
      findsOneWidget,
    );
    semantics.dispose();
  });

  testWidgets('startup runtime failure replaces the indefinite spinner', (
    tester,
  ) async {
    final error = ValueNotifier<String?>(null);
    addTearDown(error.dispose);
    await tester.pumpWidget(AuthStartupApp(errorSignal: error));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    error.value = unexpectedErrorMessage;
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(liveMessage(unexpectedErrorMessage), findsOneWidget);
    expect(find.textContaining('أعد تشغيل التطبيق'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unexpected startup recovery error is visible and redacted', (
    tester,
  ) async {
    final notice = Completer<String?>();
    await tester.pumpWidget(
      BirdsApp(repository: PreviewRepository(), startupNotice: notice.future),
    );
    notice.completeError(StateError('private-image-path'));
    await tester.pumpAndSettle();
    const message =
        'تعذر التحقق من استعادة اختيار الصور. لم تُرفق صورة تلقائياً؛ اخترها مجدداً من الإعلان المطلوب.';
    expect(liveMessage(message), findsOneWidget);
    expect(find.textContaining('private-image-path'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'auth-stream error cancels feed presentation and late completion',
    (tester) async {
      final repo = BoundaryRepository();
      addTearDown(repo.sessions.close);
      await tester.pumpWidget(BirdsApp(repository: repo));
      repo.sessions.addError(StateError('refresh-token-private'));
      await tester.pumpAndSettle();
      const message =
          'تعذر التحقق من جلسة الحساب. أُخفي المحتوى؛ أعد المحاولة.';
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(liveMessage(message), findsOneWidget);
      repo.feeds.single.complete(Result.success([listing]));
      await tester.pumpAndSettle();
      expect(find.text(listing.title), findsNothing);
      expect(find.text(message), findsOneWidget);
      expect(find.textContaining('refresh-token-private'), findsNothing);
      await tester.tap(find.text('إعادة المحاولة'));
      repo.feeds.last.complete(Result.success([listing]));
      await tester.pumpAndSettle();
      expect(repo.feeds.length, 2);
      expect(find.text(listing.title), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('auth failure clears already rendered account-visible entries', (
    tester,
  ) async {
    final repo = BoundaryRepository();
    addTearDown(repo.sessions.close);
    await tester.pumpWidget(BirdsApp(repository: repo));
    repo.feeds.single.complete(Result.success([listing]));
    await tester.pumpAndSettle();
    expect(find.text(listing.title), findsOneWidget);
    repo.sessions.addError(StateError('private'));
    await tester.pumpAndSettle();
    expect(find.text(listing.title), findsNothing);
    expect(find.textContaining('أُخفي المحتوى'), findsOneWidget);
  });

  testWidgets(
    'feed response checks identity even before an auth event arrives',
    (tester) async {
      final repo = BoundaryRepository();
      addTearDown(repo.sessions.close);
      await tester.pumpWidget(BirdsApp(repository: repo));
      repo.user = 'B';
      repo.feeds.single.complete(Result.success([listing]));
      await tester.pumpAndSettle();
      expect(find.text(listing.title), findsNothing);
      expect(find.textContaining('أُخفي المحتوى'), findsOneWidget);
    },
  );

  testWidgets('retained home refresh callback is inert after disposal', (
    tester,
  ) async {
    final repo = BoundaryRepository();
    addTearDown(repo.sessions.close);
    await tester.pumpWidget(BirdsApp(repository: repo));
    final refresh = tester
        .widget<RefreshIndicator>(find.byType(RefreshIndicator))
        .onRefresh;
    await tester.pumpWidget(const SizedBox());
    await refresh();
    expect(repo.feeds.length, 1);
    repo.feeds.single.complete(const Result.success([]));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  for (final action in ['account', 'publish']) {
    testWidgets(
      '$action navigation failure is contained and releases its lock',
      (tester) async {
        final repo = BoundaryRepository();
        addTearDown(repo.sessions.close);
        // Deliberately omit the Navigator subtree to exercise a synchronous
        // route-opening failure, without making any network request.
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => Overlay(
              initialEntries: [
                OverlayEntry(builder: (_) => HomePage(repository: repo)),
              ],
            ),
            home: const SizedBox(),
          ),
        );
        repo.feeds.single.complete(const Result.success([]));
        await tester.pumpAndSettle();
        expect(
          Navigator.maybeOf(tester.element(find.byType(HomePage))),
          isNull,
        );
        final callback =
            (action == 'account'
                    ? tester
                          .widget<IconButton>(
                            find.widgetWithIcon(
                              IconButton,
                              Icons.account_circle_outlined,
                            ),
                          )
                          .onPressed!
                    : tester
                          .widget<FloatingActionButton>(
                            find.byType(FloatingActionButton),
                          )
                          .onPressed!)
                as Future<void> Function();
        for (var attempt = 0; attempt < 2; attempt++) {
          await tester.runAsync(callback);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.textContaining('تعذر إتمام العملية'), findsOneWidget);
          expect(tester.takeException(), isNull);
          tester
              .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))
              .clearSnackBars();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
        }
      },
    );
  }

  for (final signedIn in [false, true]) {
    testWidgets(
      'dismissed account callback cannot latch ${signedIn ? 'sign-out' : 'sign-in'} busy state',
      (tester) async {
        final repo = BoundaryRepository()..user = signedIn ? 'A' : null;
        addTearDown(repo.sessions.close);
        await tester.pumpWidget(BirdsApp(repository: repo));
        repo.feeds.single.complete(const Result.success([]));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('الحساب والإعدادات'));
        await tester.pumpAndSettle();
        final VoidCallback stale = signedIn
            ? tester
                  .widget<FilledButton>(
                    find.widgetWithText(FilledButton, 'تسجيل الخروج'),
                  )
                  .onPressed!
            : tester
                  .widget<OutlinedButton>(
                    find.widgetWithText(
                      OutlinedButton,
                      'الدخول بالبريد وكلمة المرور',
                    ),
                  )
                  .onPressed!;
        tester.state<NavigatorState>(find.byType(Navigator)).pop();
        await tester.pumpAndSettle();
        stale();
        await tester.pumpAndSettle();
        expect(repo.authCalls, 0);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('الحساب والإعدادات'));
        await tester.pumpAndSettle();
        expect(find.byType(BottomSheet), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final dispose in [false, true]) {
    testWidgets(
      'picker does not read a file after ${dispose ? 'disposal' : 'account invalidation'}',
      (tester) async {
        final repo = BoundaryRepository();
        addTearDown(repo.sessions.close);
        final picker = DeferredPicker();
        final file = ObservedFile();
        await tester.pumpWidget(
          MaterialApp(
            home: UploadImagePage(
              repository: repo,
              entry: listing,
              picker: picker,
            ),
          ),
        );
        await tester.pumpAndSettle();
        final choose =
            tester
                    .widget<OutlinedButton>(find.byType(OutlinedButton))
                    .onPressed!
                as Future<void> Function();
        final pending = choose();
        await tester.pump();
        if (dispose) {
          await tester.pumpWidget(const SizedBox());
        } else {
          repo.sessions.addError(StateError('private'));
          await tester.pump();
        }
        picker.result.complete(file);
        await pending;
        await tester.pumpAndSettle();
        expect(file.lengthCalls, 0);
        expect(file.readCalls, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'picker stops before byte reading if identity changes during stat',
    (tester) async {
      final repo = BoundaryRepository();
      addTearDown(repo.sessions.close);
      final picker = DeferredPicker();
      final file = ObservedFile()..pendingLength = Completer<int>();
      await tester.pumpWidget(
        MaterialApp(
          home: UploadImagePage(
            repository: repo,
            entry: listing,
            picker: picker,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final choose =
          tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed!
              as Future<void> Function();
      final pending = choose();
      picker.result.complete(file);
      await tester.pump();
      expect(file.lengthCalls, 1);
      repo.user = 'B';
      repo.sessions.add(null);
      file.pendingLength!.complete(4);
      await pending;
      await tester.pumpAndSettle();
      expect(file.readCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'publication stops prerequisite reads after its account changes',
    (tester) async {
      final repo = BoundaryRepository()
        ..pendingTaxonomy = Completer<Result<Taxonomy>>();
      addTearDown(repo.sessions.close);
      await tester.pumpWidget(
        MaterialApp(
          home: PublicationPage(repository: repo, kind: FeedKind.offer),
        ),
      );
      await tester.pump();
      repo.user = 'B';
      repo.sessions.add(null);
      repo.pendingTaxonomy!.complete(const Result.success(Taxonomy()));
      await tester.pumpAndSettle();
      expect(repo.profiles, 0);
      expect(find.text('تغيرت جلسة الحساب'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('account panels discard late private status after auth error', (
    tester,
  ) async {
    final repo = BoundaryRepository()
      ..pendingModerator = Completer<Result<bool>>()
      ..pendingDeletion = Completer<Result<DeletionStatus?>>();
    addTearDown(repo.sessions.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              ModeratorAccessTile(repository: repo),
              DeletionStatusPanel(repository: repo),
            ],
          ),
        ),
      ),
    );
    repo.sessions.addError(StateError('private'));
    repo.pendingModerator!.complete(const Result.success(true));
    repo.pendingDeletion!.complete(const Result.success(DeletionStatus(false)));
    await tester.pumpAndSettle();
    expect(find.text('متابعة طلب حذف الحساب'), findsNothing);
    expect(find.text('مراجعة البلاغات (للمشرفين)'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('account panels announce errors and lock duplicate retries', (
    tester,
  ) async {
    final repo = BoundaryRepository()
      ..failModerator = true
      ..failDeletion = true;
    addTearDown(repo.sessions.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              ModeratorAccessTile(repository: repo),
              DeletionStatusPanel(repository: repo),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(liveMessage('تعذر التحقق من المشرف'), findsOneWidget);
    expect(liveMessage('تعذر التحقق من الحذف'), findsOneWidget);
    repo.pendingModerator = Completer<Result<bool>>();
    repo.pendingDeletion = Completer<Result<DeletionStatus?>>();
    final moderatorRetry = tester
        .widget<TextButton>(
          find.widgetWithText(TextButton, 'إعادة التحقق من صلاحية الإشراف'),
        )
        .onPressed!;
    final deletionRetry = tester
        .widget<TextButton>(
          find.widgetWithText(
            TextButton,
            'تعذر التحقق من حالة حذف الحساب؛ إعادة المحاولة',
          ),
        )
        .onPressed!;
    moderatorRetry();
    moderatorRetry();
    deletionRetry();
    deletionRetry();
    await tester.pump();
    expect(repo.moderatorCalls, 2);
    expect(repo.deletionCalls, 2);
    repo.pendingModerator!.complete(const Result.success(false));
    repo.pendingDeletion!.complete(const Result.success(null));
    await tester.pumpAndSettle();
    expect(find.text('تعذر التحقق من المشرف'), findsNothing);
    expect(find.text('تعذر التحقق من الحذف'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    moderatorRetry();
    deletionRetry();
    await tester.pumpAndSettle();
    expect(repo.moderatorCalls, 2);
    expect(repo.deletionCalls, 2);
    expect(tester.takeException(), isNull);
  });
}
