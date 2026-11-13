# Local bounded JPEG encoder mitigation, 2026-11-09

This is a **local allocation mitigation, not upload enablement or release
approval**. No hosted service, account, credential, R2 object or deployment was
used or changed. Uploads remain disabled. The original decoder, input limits,
strict baseline-only inspection, capacity thresholds and per-handler
verification lease remain unchanged.

## Change and assurance boundary

The previous encoder rebuilt 65,534 nested coefficient-code arrays and large
normal JavaScript tables on every call, then grew a normal JavaScript array for
output. The narrow adaptation of official npm jpeg-js 0.4.4 uses private fixed
typed tables and bounded, invocation-local output chunks. The complete origin,
licenses and change inventory are in
[the vendoring record](../supabase/functions/_shared/vendor/jpeg-js/README.md).

- Quality stays at 80, with the same arithmetic, padding, color conversion,
  quantization and Huffman codes. The pinned upstream decoder is unchanged.
- Fixed typed tables use 275,580 bytes in total, plus small fixed symbol lists.
  Each encode owns 2 KiB of mutable numeric scratch and at most 32 output chunks
  of up to 64 KiB. Aggregate output cannot exceed 2 MiB; the check precedes
  every byte write, including byte stuffing and end markers. Joining chunks
  creates one independent exact-sized output, so chunk bytes plus result are
  bounded by 4 MiB. These are encoder allocations, **not a total codec/handler
  memory cap**.
- No decoded pixels, writable scratch or output buffer is retained in module
  state. Fixed tables are private and not changed by encoding. No shared buffer
  pool, forced GC, worker, subprocess or unsupported Edge API is used.
- Invalid shape/data/budget and impossible coefficient lookups fail closed.
  Overflow returns the existing `image_too_large` API error; no partial output
  is published. The existing output inspection remains in place.
- `sanitizeJpeg` still inspects before decoding, accepts at most 640×640 pixels
  and 2 MiB input, uses strict decoding with the same 16 MiB allocation guard,
  and strips metadata by encoding only fresh RGBA pixels.

Eight new tests compare **exact output bytes and decoded pixels** with
unmodified jpeg-js 0.4.4. They cover 13 shape/color cases, 16 seeded noise
cases, maximum 640×640 noise/checker patterns, odd block edges, skinny images,
and the original full-bundle fixture (571,931 input / 571,691 output bytes).
Other cases cover invalid RGBA shape/types, non-finite/fractional/oversized
bounds, exhaustion in headers/scan/end markers, aggregate chunk-boundary
overflow, exact budgets, post-failure recovery, prior-output stability and
nested synchronous reentry. Reentry uses a synthetic typed-array proxy to invoke
another encode after the outer call has begun emitting blocks; it does not rely
on handler serialization. Existing metadata and malformed/progressive JPEG tests
remain unchanged.

These are regression and negative tests, not proof of universal equivalence or a
complete security audit of a JPEG implementation. The vendored fork requires
review and maintenance independently of npm dependency audit.

## Same-harness comparison

The [original baseline](media-bundle-resource-experiment.md) and its evidence
were preserved.
[New evidence](evidence/media-bundle-bounded-encoder-2026-11-09.json) records
SHA-256 for the exact candidate sources, upstream encoder, native Deno binary
and baseline file, plus all eight fresh-process runs. The handler, Auth, R2
helpers, capacity guard, package lock and all three harness files have the
**same hashes as the baseline**. Only encoding implementation and the
sanitizer's encoding call changed in that measured path.

The run used the exact same Deno 2.5.6 binary/cache, unchanged opt-in launcher,
synthetic 640×640 fixture, SDK transport/storage fakes, permissions and
scenarios. There were three independent processes each for immediate and paced
sequences, 20 calls per handler, then a two-second idle and one recovery call.
Paced runs use 100 ms between requests and 5 ms at synthetic transport
boundaries. No forced GC, V8 tuning, threshold changes or warm-process retries
were used.

| Scenario / run | Completions out of 20 | Safe busy rejections | After 2 s idle | Max sampled heap + external | Max sampled process RSS |
| -------------- | --------------------: | -------------------: | -------------- | --------------------------: | ----------------------: |
| Immediate / 1  |                     8 |                   12 | 200            |                   68.40 MiB |              173.23 MiB |
| Immediate / 2  |                     6 |                   14 | 200            |                   71.79 MiB |              168.94 MiB |
| Immediate / 3  |                     4 |                   16 | 200            |                   70.75 MiB |              171.12 MiB |
| Paced / 1      |                    20 |                    0 | 200            |                   54.37 MiB |              177.62 MiB |
| Paced / 2      |                    20 |                    0 | 200            |                   54.58 MiB |              179.95 MiB |
| Paced / 3      |                    20 |                    0 | 200            |                   54.38 MiB |              174.44 MiB |

All three paced sequences completed, unlike the original baseline's 4–5
completions followed by persistent safe rejection after idle. Successful calls
within these 20-request sequences took 149.59–225.40 ms immediately, or
182.10–266.48 ms paced, including synthetic handler work and waits. These are
elapsed durations, not CPU-time measurements or a production latency benchmark.

**Immediate warm-call stalls remain.** All immediate rejections occurred at the
first capacity gate, after Auth but before prepare/download/write/commit/remove.
External memory exceeded the unchanged 32 MiB threshold (sampled maxima
35.09–40.04 MiB), although heap stayed below 96 MiB and the sum below 112 MiB.
All three immediate runs recovered after idle in this sample. This does not
promise that idle or retry will recover every warm isolate. The paced external
maximum was 29.30 MiB, close enough to the 32 MiB gate that larger real-bundle
allocations, different GC timing or longer sequences remain material concerns.

The fresh-process burst still admitted one request, rejected seven overlapping
requests with 429 before protected effects, then completed and recovered. Its
max sampled heap + external was 73.06 MiB; this was **not lower** than the
baseline burst's 69.97 MiB. All 14 failure-boundary requests and all eight
exact/ over/non-finite capacity checks passed. Boundary mode still injects
deterministic capacity values to isolate failures; it does not establish warm
liveness.

## Reproduction and remaining gates

With the same prepared dependencies, use the baseline launcher instructions and
save separate filenames, for example:

```sh
for repeat in 1 2 3; do
  for mode in sequential sequential-paced; do
    bash scripts/media_bundle_resource.sh --run-local "$mode" \
      > "/tmp/media-bundle-bounded-$mode-$repeat.json"
  done
done
bash scripts/media_bundle_resource.sh --run-local burst
bash scripts/media_bundle_resource.sh --run-local boundaries
```

The full Edge suite passed **105 tests**, including eight new encoder tests;
four harness tests, formatter, lint, all Edge-entrypoint type checks, repository
policy and whitespace checks also passed locally. This does not replace required
CI/security evidence for the exact eventual commit.

This remains ordinary Deno with boundary samples, not continuous peak
measurement or a Supabase memory/CPU-policy test. The full handler and SDK
modules load, but actual S3Client construction, signing, R2
network/streaming/retries and real Auth are still not exercised. The local
improvement does not satisfy the separate actual Edge/hosted resource gate, real
staging-storage/authentication checks or physical-device tests. Keep uploads
disabled and keep the original capacity thresholds. Longer warm sequences,
representative adversarial input coverage and actual full-bundle hosted
measurements remain required before any separately authorized enablement
decision.
