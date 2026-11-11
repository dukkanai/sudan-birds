import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/native_storage_checks.dart';

void main() {
  test('guard preserves the safe failing check inside a group', () async {
    await expectLater(
      guardNativeStorage(
        'Credential operations and namespace isolation',
        () async {
          checkNativeStorage(false, 'Fresh credential adapter readback');
        },
      ),
      throwsA(
        isA<TestFailure>().having(
          (error) => error.message,
          'message',
          'Fresh credential adapter readback failed',
        ),
      ),
    );
  });

  test('guard suppresses platform, matcher and other exception data', () async {
    for (final error in <Object>[
      PlatformException(code: 'SYNTHETIC-PRIVATE', message: 'SYNTHETIC-PRIVATE'),
      TestFailure('SYNTHETIC-PRIVATE'),
      StateError('SYNTHETIC-PRIVATE'),
    ]) {
      await expectLater(
        guardNativeStorage('Initial cleanup', () async => throw error),
        throwsA(
          isA<TestFailure>().having(
            (failure) => failure.message,
            'message',
            'Initial cleanup failed (details suppressed)',
          ),
        ),
      );
    }
  });

  test('unknown check labels are suppressed even for passing checks', () {
    for (final condition in [false, true]) {
      expect(
        () => checkNativeStorage(condition, 'SYNTHETIC-PRIVATE'),
        throwsA(
          isA<TestFailure>().having(
            (failure) => failure.message,
            'message',
            'Unknown storage check failed',
          ),
        ),
      );
    }
  });

  test('unknown group labels fail before the action runs', () async {
    var called = false;
    await expectLater(
      guardNativeStorage('SYNTHETIC-PRIVATE', () async => called = true),
      throwsA(
        isA<TestFailure>().having(
          (failure) => failure.message,
          'message',
          'Unknown storage group failed',
        ),
      ),
    );
    expect(called, isFalse);
  });

  test('successful checks and guarded operations complete', () async {
    var called = false;
    await guardNativeStorage('Initial cleanup', () async {
      checkNativeStorage(true, 'Empty');
      called = true;
    });
    expect(called, isTrue);
  });
}
