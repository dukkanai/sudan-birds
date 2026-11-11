import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sudan_birds/domain.dart';
import 'package:sudan_birds/local_diagnostics.dart';
import 'package:sudan_birds/main.dart';

class SecretError implements Exception {
  @override
  String toString() => throw StateError('Must never stringify raw errors');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(localDiagnostics.reset);
  tearDown(() {
    localDiagnostics.reset();
    runtimeError.value = null;
  });

  test('bounded immutable snapshots contain only safe fields and UTC time', () {
    final time = DateTime.utc(2026, 11, 11);
    final recorder = LocalDiagnostics(clock: () => time);
    recorder.record(FailureBoundary.startup, FailureCode.rejected);
    final first = recorder.snapshot;
    for (var i = 0; i < LocalDiagnostics.capacity + 3; i++) {
      recorder.record(
        FailureBoundary.mutation,
        FailureCode.timeout,
        outcomeUnknown: true,
      );
    }
    expect(first.single.boundary, FailureBoundary.startup);
    expect(recorder.snapshot.length, LocalDiagnostics.capacity);
    expect(recorder.snapshot.every((event) => event.outcomeUnknown), isTrue);
    expect(
      recorder.snapshot.every((event) => event.occurredAt == time),
      isTrue,
    );
    expect(() => recorder.snapshot.clear(), throwsUnsupportedError);
    recorder.reset();
    expect(recorder.snapshot, isEmpty);
    expect(first, hasLength(1));
  });

  test('recording failure never throws or erases existing diagnostics', () {
    var failClock = false;
    final recorder = LocalDiagnostics(
      clock: () {
        if (failClock) throw SecretError();
        return DateTime.utc(2026);
      },
    );
    recorder.record(FailureBoundary.startup, FailureCode.rejected);
    failClock = true;
    expect(
      () => recorder.record(FailureBoundary.platform, FailureCode.unexpected),
      returnsNormally,
    );
    expect(recorder.snapshot.single.boundary, FailureBoundary.startup);
  });

  test(
    'protect preserves failures and never inspects raw exceptions',
    () async {
      final result = await protectMutation<bool>(
        () async => throw SecretError(),
      );
      expect(result.isSuccess, isFalse);
      expect(result.failure!.outcomeUnknown, isTrue);
      expect(
        localDiagnostics.snapshot.single.boundary,
        FailureBoundary.mutation,
      );
      expect(localDiagnostics.snapshot.single.code, FailureCode.unexpected);
      expect(localDiagnostics.snapshot.single.outcomeUnknown, isTrue);
      const failure = AppFailure('email=private@example.test jwt=secret');
      final rejected = await protect<bool>(() async => throw failure);
      expect(rejected.failure, same(failure));
      expect(localDiagnostics.snapshot.last.code, FailureCode.rejected);
      // No exception message, type, stack, or payload is part of the event API.
      expect(
        localDiagnostics.snapshot.last.toString(),
        isNot(contains('secret')),
      );
    },
  );

  test('timeouts and both guard failure paths preserve uncertainty', () async {
    final timeout = await protectMutation<bool>(
      () async => throw TimeoutException('secret'),
    );
    expect(timeout.failure!.outcomeUnknown, isTrue);
    expect(localDiagnostics.snapshot.last.code, FailureCode.timeout);
    final thrown = await guardMutation<bool>(() async => throw SecretError());
    expect(thrown.failure!.outcomeUnknown, isTrue);
    expect(
      localDiagnostics.snapshot.last.boundary,
      FailureBoundary.uiMutationGuard,
    );
    const failure = AppFailure('تعذر التنفيذ', outcomeUnknown: true);
    final returned = await guardResult<bool>(
      () async => const Result.failure(failure),
    );
    expect(returned.failure, same(failure));
    expect(localDiagnostics.snapshot.last.boundary, FailureBoundary.uiGuard);
    expect(localDiagnostics.snapshot.last.outcomeUnknown, isTrue);
    final count = localDiagnostics.snapshot.length;
    await guardResult<bool>(() async => const Result.success(true));
    expect(localDiagnostics.snapshot.length, count);
  });

  test(
    'framework platform and zone capture retain warning and safe origins',
    () async {
      final framework = FlutterError.onError;
      final platform = PlatformDispatcher.instance.onError;
      final builder = ErrorWidget.builder;
      try {
        installRuntimeErrorHandlers();
        FlutterError.onError!(FlutterErrorDetails(exception: SecretError()));
        expect(
          PlatformDispatcher.instance.onError!(
            SecretError(),
            StackTrace.fromString('jwt=secret'),
          ),
          isTrue,
        );
        final done = Completer<void>();
        runZonedGuarded(
          () {
            scheduleMicrotask(() => throw SecretError());
          },
          (_, _) {
            captureUnexpectedError();
            done.complete();
          },
        );
        await done.future;
        await Future<void>.delayed(Duration.zero);
        expect(runtimeError.value, unexpectedErrorMessage);
        expect(localDiagnostics.snapshot.map((event) => event.boundary), [
          FailureBoundary.flutter,
          FailureBoundary.platform,
          FailureBoundary.zone,
        ]);
        expect(
          localDiagnostics.snapshot.every((event) => event.outcomeUnknown),
          isTrue,
        );
      } finally {
        FlutterError.onError = framework;
        PlatformDispatcher.instance.onError = platform;
        ErrorWidget.builder = builder;
      }
    },
  );
}
