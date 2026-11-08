import { decode, encode } from "npm:jpeg-js@0.4.4";
import { ApiError } from "./http.ts";
export const IMAGE_LIMITS = { maxBytes: 2_097_152, maxPixels: 409_600, maxDimension: 640 } as const;
export function inspectJpeg(bytes: Uint8Array): { width: number; height: number } {
  const bad = () => new ApiError(400, "invalid_image");
  if (
    bytes.length < 20 || bytes.length > IMAGE_LIMITS.maxBytes || bytes[0] !== 255 ||
    bytes[1] !== 216
  ) throw bad();
  let i = 2, segments = 0, width = 0, height = 0, frames = 0;
  while (i < bytes.length) {
    if (++segments > 256 || bytes[i++] !== 255) throw bad();
    const marker = bytes[i++];
    if (marker === 0 || marker === 255 || i + 2 > bytes.length) throw bad();
    const len = (bytes[i] << 8) | bytes[i + 1];
    if (len < 2 || i + len > bytes.length) throw bad();
    if (marker === 0xc0) {
      if (++frames !== 1 || len < 11 || bytes[i + 2] !== 8) throw bad();
      height = (bytes[i + 3] << 8) | bytes[i + 4];
      width = (bytes[i + 5] << 8) | bytes[i + 6];
      const components = bytes[i + 7];
      if (
        ![1, 3].includes(components) || len !== 8 + 3 * components || !width || !height ||
        width > IMAGE_LIMITS.maxDimension || height > IMAGE_LIMITS.maxDimension ||
        width * height > IMAGE_LIMITS.maxPixels
      ) throw bad();
      for (let c = 0; c < components; c++) {
        const sampling = bytes[i + 9 + c * 3];
        if (![1, 2].includes(sampling >> 4) || ![1, 2].includes(sampling & 15)) throw bad();
      }
    } else if (marker === 0xda) {
      if (frames !== 1) throw bad();
      // Only a single baseline scan, no progressive/multi-scan or concatenated JPEG.
      i += len;
      while (i < bytes.length) {
        if (bytes[i++] !== 255) continue;
        const scanMarker = bytes[i++];
        if (scanMarker === 0 || (scanMarker >= 0xd0 && scanMarker <= 0xd7)) continue;
        if (scanMarker === 0xd9 && i === bytes.length) return { width, height };
        throw bad();
      }
      throw bad();
    } else if (!((marker >= 0xe0 && marker <= 0xef) || [0xfe, 0xdb, 0xc4, 0xdd].includes(marker))) {
      throw bad();
    }
    i += len;
  }
  throw bad();
}
export function sanitizeJpeg(bytes: Uint8Array) {
  try {
    const expected = inspectJpeg(bytes);
    const pixels = decode(bytes, {
      useTArray: true,
      formatAsRGBA: true,
      tolerantDecoding: false,
      maxResolutionInMP: 0.4096,
      maxMemoryUsageInMB: 16,
    });
    if (
      pixels.width !== expected.width || pixels.height !== expected.height ||
      pixels.data.length !== pixels.width * pixels.height * 4
    ) {
      throw new ApiError(400, "invalid_image");
    }
    // Fresh pixel-only input deliberately omits EXIF and decoded comments.
    const encoded = encode({ width: pixels.width, height: pixels.height, data: pixels.data }, 80);
    if (encoded.data.length > IMAGE_LIMITS.maxBytes) throw new ApiError(400, "image_too_large");
    inspectJpeg(encoded.data);
    return { bytes: new Uint8Array(encoded.data), width: pixels.width, height: pixels.height };
  } catch (error) {
    if (error instanceof ApiError) throw error;
    throw new ApiError(400, "invalid_image");
  }
}
