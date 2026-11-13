/// Mirrors supabase/functions/_shared/images.ts; media_contract_test prevents drift.
abstract final class MediaPolicy {
  static const maxBytes = 2097152;
  static const maxPixels = 409600;
  static const maxDimension = 640;
  static const jpegQuality = 80;
  static const maxImages = 3;
}
