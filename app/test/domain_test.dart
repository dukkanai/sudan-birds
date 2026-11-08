import 'package:flutter_test/flutter_test.dart';
import 'package:sudan_birds/domain.dart';

void main() {
  test('offers require a numeric amount, request budgets are optional', () {
    expect(validateAmount('', required: true), isNotNull);
    expect(validateAmount('', required: false), isNull);
    for (final invalid in ['السعر في الخاص', '-1', 'NaN', 'Infinity']) {
      expect(validateAmount(invalid, required: true), isNotNull);
    }
    expect(validateAmount('١٢٣٫٥', required: true), isNull);
    expect(validateAmount('0', required: true), isNull);
    expect(parseAmount('۱۲۳'), 123);
  });
  test('failures are typed and do not expose raw exception details', () async {
    final result = await protect<int>(
      () async => throw Exception('secret-token'),
    );
    expect(result.isSuccess, isFalse);
    expect(result.failure!.message, isNot(contains('secret-token')));
  });
  test('actionable domain failures survive containment', () async {
    final result = await protect<int>(
      () async => throw const AppFailure('سجّل الدخول أولاً.'),
    );
    expect(result.failure!.message, 'سجّل الدخول أولاً.');
  });
  test('preview never pretends to authenticate or save', () async {
    final repo = PreviewRepository();
    expect(repo.signedIn, isFalse);
    expect((await repo.signIn('google')).isSuccess, isFalse);
    expect((await repo.reply('id', 'hello')).isSuccess, isFalse);
    expect(
      (await repo.feed(FeedKind.request, const FeedFilter())).value,
      isEmpty,
    );
  });
}
