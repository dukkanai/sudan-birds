import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sudan_birds/media_policy.dart';

void main() {
  test('mobile image limits match the server security contract', () {
    final server = File(
      '../supabase/functions/_shared/images.ts',
    ).readAsStringSync();
    int limit(String key) => int.parse(
      RegExp(
        '$key: ([0-9_]+)',
      ).firstMatch(server)!.group(1)!.replaceAll('_', ''),
    );
    expect(MediaPolicy.maxBytes, limit('maxBytes'));
    expect(MediaPolicy.maxPixels, limit('maxPixels'));
    expect(MediaPolicy.maxDimension, limit('maxDimension'));
  });
}
