import { ApiError } from "./http.ts";
import { IMAGE_LIMITS, inspectJpeg, sanitizeJpeg } from "./images.ts";
import { assert, jpeg } from "./test_fixtures.ts";
function rejected(bytes: Uint8Array) {
  let failed = false;
  try {
    sanitizeJpeg(bytes);
  } catch (e) {
    failed = e instanceof ApiError;
  }
  assert(failed);
}
function frameOffset(bytes: Uint8Array) {
  for (let i = 2; i < bytes.length - 1; i++) {
    if (bytes[i] === 255 && bytes[i + 1] === 0xc0) return i;
  }
  throw new Error("No SOF");
}
Deno.test("JPEG fresh pixel encoding strips metadata and keeps valid dimensions", () => {
  const original = jpeg();
  const marker = new TextEncoder().encode("SECRET_GPS_XMP_IPTC_ICC_THUMBNAIL");
  let decorated = original;
  for (const code of [0xe1, 0xe2, 0xed, 0xfe]) {
    const extra = new Uint8Array(marker.length + 4);
    extra.set([255, code, (marker.length + 2) >> 8, (marker.length + 2) & 255]);
    extra.set(marker, 4);
    decorated = new Uint8Array([...decorated.slice(0, 2), ...extra, ...decorated.slice(2)]);
  }
  const clean = sanitizeJpeg(decorated);
  assert(clean.width === 16 && clean.height === 16);
  assert(!new TextDecoder().decode(clean.bytes).includes("SECRET_GPS"));
  assert(inspectJpeg(clean.bytes).width === 16);
});
Deno.test("JPEG rejects empty, non-image, truncated, trailing and oversize data", () => {
  const good = jpeg();
  for (
    const data of [
      new Uint8Array(),
      new TextEncoder().encode('<svg onload="x"/>'),
      good.slice(0, -2),
      good.slice(0, good.length / 2),
      new Uint8Array([...good, 1]),
      new Uint8Array(IMAGE_LIMITS.maxBytes + 1),
    ]
  ) rejected(data);
});
Deno.test("JPEG rejects progressive, invalid SOF, oversized/skinny dimensions and segment lengths", () => {
  const good = jpeg();
  const offset = frameOffset(good);
  for (const [width, height] of [[0, 16], [641, 1], [1, 641], [640, 641], [65535, 1]]) {
    const bad = good.slice();
    bad[offset + 5] = height >> 8;
    bad[offset + 6] = height & 255;
    bad[offset + 7] = width >> 8;
    bad[offset + 8] = width & 255;
    rejected(bad);
  }
  const progressive = good.slice();
  progressive[offset + 1] = 0xc2;
  rejected(progressive);
  for (const len of [0, 1, 65535]) {
    const bad = good.slice();
    bad[4] = len >> 8;
    bad[5] = len & 255;
    rejected(bad);
  }
  const repeated = new Uint8Array([
    ...good.slice(0, offset),
    ...good.slice(offset, offset + 19),
    ...good.slice(offset),
  ]);
  rejected(repeated);
});
Deno.test("JPEG rejects corrupted Huffman/quantization tables rather than publishing", () => {
  for (const marker of [0xc4, 0xdb]) {
    const bad = jpeg();
    let found = false;
    for (let i = 2; i < bad.length - 5; i++) {
      if (bad[i] === 255 && bad[i + 1] === marker) {
        bad[i + 4] = 255;
        found = true;
        break;
      }
    }
    assert(found);
    rejected(bad);
  }
});
Deno.test("JPEG accepts dimension boundary when total pixels remain within budget", () => {
  const clean = sanitizeJpeg(jpeg(640, 1));
  assert(clean.width === 640 && clean.height === 1);
});
