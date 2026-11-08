import 'dart:typed_data';
import 'package:image/image.dart' as image;
import 'domain.dart';
import 'media_policy.dart';

/// Called in a background isolate. Only JPEG/PNG input, bounded before decoding.
/// Output is a NEW RGB image; no metadata-bearing clone is encoded.
Uint8List sanitizeJpeg(Uint8List bytes) {
  if (bytes.isEmpty || bytes.length > 10485760) {
    throw const AppFailure('اختر صورة JPEG أو PNG أصغر من ١٠ ميغابايت.');
  }
  final image.Decoder decoder;
  if (bytes.length >= 2 && bytes[0] == 255 && bytes[1] == 216) {
    decoder = image.JpegDecoder(maxPixels: 12000000);
  } else if (bytes.length >= 8 &&
      bytes[0] == 137 &&
      bytes[1] == 80 &&
      bytes[2] == 78 &&
      bytes[3] == 71) {
    decoder = image.PngDecoder(maxPixels: 12000000);
  } else {
    throw const AppFailure(
      'هذه النسخة تقبل صور JPEG وPNG فقط، ثم تحولها إلى JPEG آمن.',
    );
  }
  final info = decoder.startDecode(bytes);
  if (info == null ||
      info.width < 1 ||
      info.height < 1 ||
      info.width * info.height > 12000000) {
    throw const AppFailure('الصورة تالفة أو تتجاوز ١٢ مليون بكسل.');
  }
  final decoded = decoder.decode(bytes, frame: 0);
  if (decoded == null) {
    throw const AppFailure('تعذر قراءة الصورة. اختر ملفاً آخر.');
  }
  var pixels = image.bakeOrientation(decoded);
  if (pixels.width > MediaPolicy.maxDimension ||
      pixels.height > MediaPolicy.maxDimension) {
    pixels = pixels.width >= pixels.height
        ? image.copyResize(pixels, width: MediaPolicy.maxDimension)
        : image.copyResize(pixels, height: MediaPolicy.maxDimension);
  }
  final rgb = pixels.getBytes(order: image.ChannelOrder.rgb);
  final fresh = image.Image.fromBytes(
    width: pixels.width,
    height: pixels.height,
    bytes: rgb.buffer,
    bytesOffset: rgb.offsetInBytes,
    numChannels: 3,
    order: image.ChannelOrder.rgb,
  );
  final output = image.encodeJpg(
    fresh,
    quality: MediaPolicy.jpegQuality,
    chroma: image.JpegChroma.yuv420,
  );
  if (output.length > MediaPolicy.maxBytes ||
      fresh.width * fresh.height > MediaPolicy.maxPixels) {
    throw const AppFailure(
      'الصورة بعد المعالجة أكبر من الحد المسموح. اختر صورة أصغر.',
    );
  }
  return output;
}
