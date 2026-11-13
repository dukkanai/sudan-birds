import { decode, encode } from "npm:jpeg-js@0.4.4";
import { encodeRgbaJpeg, JpegOutputLimitError } from "./bounded_jpeg_encoder.ts";
import { inspectJpeg, sanitizeJpeg } from "./images.ts";
import { assert } from "./test_fixtures.ts";
import { fixtureBase64 } from "../codec-diagnostic/fixture.ts";

function equal(actual: Uint8Array, expected: Uint8Array) {
  assert(actual.length === expected.length);
  for (let i = 0; i < expected.length; i++) {
    if (actual[i] !== expected[i]) throw new Error(`Byte mismatch at ${i}`);
  }
}
function pixels(width: number, height: number, pattern: string, seed = 117) {
  const data = new Uint8Array(width * height * 4);
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      for (let c = 0; c < 4; c++) {
        seed = (Math.imul(seed, 1664525) + 1013904223) | 0;
        const value = pattern === "noise"
          ? seed >>> 24
          : pattern === "checker"
          ? ((x + y + c) % 2) * 255
          : pattern === "gradient"
          ? (x * 7 + y * 13 + c * 91) % 256
          : pattern === "red"
          ? (c === 0 ? 255 : 0)
          : pattern === "white"
          ? 255
          : 0;
        data[(y * width + x) * 4 + c] = value;
      }
    }
  }
  return data;
}
function parity(width: number, height: number, pattern: string, seed = 117) {
  const data = pixels(width, height, pattern, seed);
  const unchanged = data.slice();
  const upstream = encode({ width, height, data }, 80).data;
  const actual = encodeRgbaJpeg(data, width, height);
  equal(actual, upstream);
  equal(data, unchanged);
  assert(actual.buffer.byteLength === actual.byteLength);
  const dimensions = inspectJpeg(actual);
  assert(dimensions.width === width && dimensions.height === height);
  const options = { useTArray: true, tolerantDecoding: false, formatAsRGBA: true } as const;
  const expectedPixels = decode(upstream, options);
  const actualPixels = decode(actual, options);
  assert(actualPixels.width === width && actualPixels.height === height);
  equal(actualPixels.data, expectedPixels.data);
}

Deno.test("bounded JPEG exact upstream byte and decoded-pixel parity across shapes and colors", () => {
  for (
    const [width, height, pattern] of [
      [1, 1, "black"],
      [1, 1, "white"],
      [1, 1, "red"],
      [7, 9, "checker"],
      [9, 7, "gradient"],
      [16, 16, "noise"],
      [31, 33, "gradient"],
      [640, 1, "noise"],
      [1, 640, "noise"],
      [639, 17, "checker"],
      [17, 639, "gradient"],
      [640, 640, "noise"],
      [640, 640, "checker"],
    ] as const
  ) parity(width, height, pattern);
});

Deno.test("bounded JPEG deterministic randomized parity includes odd block edges", () => {
  for (let seed = 1; seed <= 16; seed++) {
    parity(1 + (seed * 37) % 83, 1 + (seed * 23) % 71, "noise", seed);
  }
});

Deno.test("bounded JPEG full resource fixture matches pinned upstream sanitization", () => {
  const original = Uint8Array.from(atob(fixtureBase64), (c) => c.charCodeAt(0));
  const decoded = decode(original, {
    useTArray: true,
    tolerantDecoding: false,
    formatAsRGBA: true,
  });
  const expected = encode({ data: decoded.data, width: decoded.width, height: decoded.height }, 80);
  const actual = sanitizeJpeg(original);
  equal(actual.bytes, expected.data);
  assert(actual.bytes.length === 571_691 && actual.width === 640 && actual.height === 640);
});

Deno.test("bounded JPEG fails closed on malformed shape, RGBA input and output budget", () => {
  const data = pixels(1, 1, "black");
  const badShapes = [
    [0, 1],
    [-1, 1],
    [1, 0],
    [1, -1],
    [641, 1],
    [1, 641],
    [Number.NaN, 1],
    [1, Infinity],
    [1.5, 1],
    [Number.MAX_SAFE_INTEGER, 1],
  ];
  const cases: Array<() => unknown> = [
    ...badShapes.map(([width, height]) => () => encodeRgbaJpeg(data, width, height)),
    ...[0, -1, 1.5, NaN, Infinity, 2_097_153].map((budget) => () =>
      encodeRgbaJpeg(data, 1, 1, budget)
    ),
    () => encodeRgbaJpeg(new Uint8Array(3), 1, 1),
    () => encodeRgbaJpeg(new Uint8Array(5), 1, 1),
    () => encodeRgbaJpeg([0, 0, 0, 0] as unknown as Uint8Array, 1, 1),
    () => encodeRgbaJpeg(new Float64Array(4) as unknown as Uint8Array, 1, 1),
  ];
  for (const run of cases) {
    let error: unknown;
    try {
      run();
    } catch (caught) {
      error = caught;
    }
    assert(error instanceof RangeError && !(error instanceof JpegOutputLimitError));
  }
});

Deno.test("bounded JPEG detects output exhaustion at headers, scan and final EOI then recovers", () => {
  const data = pixels(17, 19, "noise");
  const expected = encodeRgbaJpeg(data, 17, 19);
  for (
    const budget of [
      1,
      20,
      600,
      Math.floor(expected.length / 2),
      expected.length - 2,
      expected.length - 1,
    ]
  ) {
    let error: unknown;
    try {
      encodeRgbaJpeg(data, 17, 19, budget);
    } catch (caught) {
      error = caught;
    }
    assert(error instanceof JpegOutputLimitError);
    equal(encodeRgbaJpeg(data, 17, 19), expected);
  }
  equal(encodeRgbaJpeg(data, 17, 19, expected.length), expected);
});

Deno.test("bounded JPEG returns independent output and does not reuse stale scratch state", () => {
  const data = pixels(31, 33, "noise");
  const first = encodeRgbaJpeg(data, 31, 33);
  const expected = first.slice();
  const other = encodeRgbaJpeg(pixels(7, 1, "white"), 7, 1);
  other.fill(0);
  data.fill(0);
  equal(first, expected);
  const next = encodeRgbaJpeg(pixels(31, 33, "noise"), 31, 33);
  equal(next, expected);
  assert(first.buffer !== next.buffer && first.buffer !== data.buffer);
  first.fill(0);
  equal(next, expected);
});

Deno.test("bounded JPEG nested synchronous call cannot corrupt an in-progress invocation", () => {
  const data = pixels(16, 16, "noise");
  const expected = encodeRgbaJpeg(data, 16, 16);
  let nested = false;
  // A synthetic accessor induces reentry after one outer block has been encoded.
  // Normal sanitizer inputs are the decoder's plain Uint8Array, with no callbacks.
  const reentrant = new Proxy(data, {
    get(target, property) {
      if (property === "544" && !nested) {
        nested = true;
        parity(1, 7, "white");
      }
      return Reflect.get(target, property, target);
    },
  });
  equal(encodeRgbaJpeg(reentrant, 16, 16), expected);
  assert(nested);
});

Deno.test("bounded JPEG enforces one aggregate budget across output chunk boundaries", () => {
  const data = pixels(256, 256, "noise");
  const upstream = encode({ width: 256, height: 256, data }, 80).data;
  assert(upstream.length > 65_536);
  equal(encodeRgbaJpeg(data, 256, 256, upstream.length), upstream);
  for (const budget of [65_535, 65_536, 65_537, upstream.length - 1]) {
    let error: unknown;
    try {
      encodeRgbaJpeg(data, 256, 256, budget);
    } catch (caught) {
      error = caught;
    }
    assert(error instanceof JpegOutputLimitError);
  }
  equal(encodeRgbaJpeg(data, 256, 256), upstream);
});
