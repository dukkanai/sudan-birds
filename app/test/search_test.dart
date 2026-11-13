import 'package:flutter_test/flutter_test.dart';
import 'package:sudan_birds/domain.dart';

void main() {
  test('quoted PostgREST patterns contain punctuation safely', () {
    final slash = String.fromCharCode(92);
    expect(quotedSearchPattern('bird"'), '"%bird$slash"%"');
    expect(quotedSearchPattern('a,b(c)'), '"%a,b(c)%"');
    expect(quotedSearchPattern(slash), '"%${slash * 4}%"');
    expect(quotedSearchPattern('%_'), '"%${slash * 2}%${slash * 2}_%"');
    expect(() => quotedSearchPattern('*'), throwsA(isA<AppFailure>()));
  });
}
