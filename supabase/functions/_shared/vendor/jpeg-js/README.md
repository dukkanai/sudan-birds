# Narrow jpeg-js encoder adaptation

`../../bounded_jpeg_encoder.ts` is derived from **jpeg-js 0.4.4**, `lib/encoder.js`, distributed by
the official npm package <https://www.npmjs.com/package/jpeg-js/v/0.4.4>, upstream
<https://github.com/eugeneware/jpeg-js>.

The source was copied from the repository's installed, lock-pinned package. Its unmodified SHA-256
is `00bde8df2517eca556669ab6fc27b414e9ba3fc52a0a71e1e37ec7c5f19c3d34`. The original Adobe copyright,
conditions, disclaimer and Andreas Ritter credit remain at the top of the adaptation. The package's
complete Eugene Ware BSD-3-Clause license is reproduced without changes in [LICENSE](LICENSE)
(SHA-256 `c0a8512eabe960492fefd4f287523eb3b5ca1518ca37ef0ec83344cd7f089cb8`). Retain both notices in
source and binary redistributions.

## Deliberate changes

- TypeScript module with one pixel-only, quality-80 encoding function, and a distinct output-limit
  error. Removed browser/CommonJS exports, canvas and base64 helpers, dead benchmark code, unused
  character lookup, EXIF/comment writers and other quality settings. The production caller already
  omitted metadata and always used quality 80.
- Fixed quantization, Huffman, coefficient and RGB/YUV tables are private and initialized once.
  Quantization scale is exactly `floor(200 - 80 * 2) = 40`. Coefficient and Huffman entries pack bit
  length in the high 16 bits and code value in the low 16 bits of `Uint32Array`, replacing per-call
  nested pairs and a separate category array. RGB conversion uses `Int32Array`.
- Every invocation owns its mutable DCT blocks, coefficient scratch, bit writer and output chunks.
  `Float64Array` preserves the original JavaScript numeric precision; quantized coefficients use
  `Int32Array`, matching upstream's explicit signed-32-bit rounding. No reusable mutable request
  state exists.
- Replace the growing normal JavaScript output array with at most 32 typed chunks, each at most 64
  KiB. Check the aggregate output budget **before every byte**, including stuffed zero bytes and the
  final marker. An exact-sized, independent result is copied once; a caller cannot retain spare
  capacity or change another call's output. Partial output is never returned on failure.
- Require exact RGBA byte length, integer positive dimensions no larger than 640×640 / 409,600
  pixels, and an integer output budget of 1–2,097,152 bytes. Check coefficient indexes and bit
  lengths rather than allowing undefined table entries or typed-array out-of-bounds writes to
  silently corrupt output.
- Keep the original DCT arithmetic, rounding, color conversion, padding, quantization values,
  Huffman codes, byte stuffing and baseline/JFIF headers. Function-scoped `var` is retained for a
  smaller numerical-code change, with only `no-var` and `no-inner-declarations` lint exceptions.
  Tables retain their compact layout to support comparison with upstream.

The original decoder remains the pinned npm dependency, with the same strict inspection, decode
limits and metadata-stripping boundary. This is a maintained vendored fork: dependency audit alone
does not audit these local changes.

`../../bounded_jpeg_encoder_test.ts` compares bytes and decoded pixels against unmodified npm
jpeg-js 0.4.4 for representative colors, deterministic noise, odd/skinny dimensions, maximum size
and the existing full-bundle fixture. It also checks malformed inputs, exact/overflow budgets across
chunk boundaries, post-failure recovery, immutable prior outputs and synthetic nested reentry. Tests
establish these cases, not universal equivalence or hosted readiness.
