import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:sudan_birds/image_sanitizer.dart';
import 'package:sudan_birds/media_policy.dart';

void main() {
  test('sanitizer resizes and emits a fresh metadata-free baseline JPEG', () {
    final source = img.Image(width: 1500, height: 1000, numChannels: 3);
    source.exif.imageIfd.make = 'PRIVATE_CAMERA';
    source.exif.imageIfd.imageDescription = 'PRIVATE_LOCATION';
    final encoded = img.encodeJpg(source, quality: 80);
    expect(String.fromCharCodes(encoded), contains('PRIVATE_CAMERA'));
    expect(String.fromCharCodes(encoded), contains('PRIVATE_LOCATION'));
    final clean = sanitizeJpeg(encoded);
    final decoded = img.decodeJpg(clean)!;
    expect(decoded.width, lessThanOrEqualTo(MediaPolicy.maxDimension));
    expect(decoded.height, lessThanOrEqualTo(MediaPolicy.maxDimension));
    expect(
      decoded.width * decoded.height,
      lessThanOrEqualTo(MediaPolicy.maxPixels),
    );
    expect(clean.length, lessThanOrEqualTo(MediaPolicy.maxBytes));
    expect(decoded.exif.isEmpty, isTrue);
    final asText = String.fromCharCodes(clean);
    expect(asText, isNot(contains('PRIVATE_CAMERA')));
    expect(asText, isNot(contains('PRIVATE_LOCATION')));
  });
  test('unsupported and oversized source input is rejected', () {
    expect(
      () => sanitizeJpeg(Uint8List.fromList([71, 73, 70, 56])),
      throwsA(anything),
    );
    expect(() => sanitizeJpeg(Uint8List(10485761)), throwsA(anything));
  });
}
