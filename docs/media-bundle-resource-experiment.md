# Local full media-handler bundle experiment, 2026-11-09

This is development evidence, **not media readiness or release approval**. Uploads
remain disabled. No production handler, admission threshold, hosted function,
credential, user, database row, storage object or scheduler was changed.

## Scope and reproducibility

The measured production modules are unchanged from base commit
`0d194ece82e91770ea73267a70b96d0fa07ebdf8` (use the full exact commit and individual SHA-256 hashes in the
[evidence file](evidence/media-bundle-local-2026-11-09.json)). The local experiment
itself is identified by its SHA-256 in that file, not by an earlier CI commit.

Docker, the Supabase CLI and the local Edge Runtime were unavailable in this
workspace. This experiment therefore used **ordinary Deno 2.5.6**, V8
14.0.365.5-rusty, on Linux x86-64. It does not enforce or emulate Supabase isolate
memory/CPU policy. No hosted experiment was attempted.

Coverage:

- Loads the actual `media/handler.ts`, all six R2 helper exports, all seven Auth
  helper exports, AWS SDK module imports, Supabase SDK and JPEG codec.
- Constructs actual Supabase clients and exercises Auth.getUser and privileged
  RPC serialization with a closed, in-memory synthetic transport. Only the
  allowlisted synthetic origin and expected Auth/RPC paths are accepted.
- Executes the actual media completion handler, both capacity checks, per-handler
  verification lease, JPEG inspection/decode/re-encode, and safe error boundary.
- Storage is injected. **No actual S3Client construction, AWS signing, R2 request,
  response streaming, storage retry or real account authentication is measured.**
  Importing the AWS SDK is not a substitute for these allocations or behaviors.
- Uses only the committed fixed 640×640 synthetic JPEG: 571,931 input bytes,
  571,691 output bytes. Input SHA-256 is
  `013be178fb8a412c89c511c9154327fbabf278bfb97a2fb594bc70ce2e148a95`.
- Retains the synthetic fixture and its base64 module, measurement records and an
  independent fake download copy. This is not the production input allocation
  profile. Fixture decoding itself creates temporary allocations. Memory is
  sampled at defined boundaries, **not continuously**, with no forced GC.

Direct dependency pins are Supabase JS 2.57.4, AWS S3 client and presigner
3.1164.0, and jpeg-js 0.4.4. The repository package lock identifies transitives.
The launcher installs nothing and clears the inherited environment. Deno grants
only the SDK's metadata-environment-name allowlist, with no host credential
values; network, runtime file reads/writes, process execution, sys and FFI are
denied. Module loading uses already-installed/cached dependencies. Global fetch
also rejects. No HTTP listener or persistent service is started.

Each scenario requires explicit `--run-local` and a closed scenario name. Bounds
are 64 requests, 768 memory samples, a 90-second between-request deadline and an
external 120-second process timeout. A synchronous codec operation cannot be
preempted by a JavaScript promise timeout. The launcher is Linux-specific and
requires the actual native Deno binary, not npm's Node wrapper.

With the pinned binary and dependencies already installed:

```sh
export DENO_BIN=/absolute/path/to/deno-2.5.6
export DENO_DIR=/absolute/path/to/prepared-deno-cache
bash scripts/media_bundle_resource.sh --run-local sequential
bash scripts/media_bundle_resource.sh --run-local sequential-paced
bash scripts/media_bundle_resource.sh --run-local burst
bash scripts/media_bundle_resource.sh --run-local boundaries
```

Run the preparation type check and tests against the same local dependency tree:

```sh
"$DENO_BIN" check --no-lock --node-modules-dir=manual \
  --config supabase/functions/deno.json scripts/media_bundle_resource.ts
"$DENO_BIN" test --cached-only --no-remote --no-lock --no-prompt \
  --node-modules-dir=manual --config supabase/functions/deno.json \
  scripts/media_bundle_resource_test.ts
```

## Measurements

There were three independent processes per sequential scenario. Each used one
handler instance for 20 sequential calls, then waited two seconds and made one
additional recovery call. The paced variant waits 100 ms between requests and
adds 5 ms asynchronous waits at synthetic Auth/RPC/download/write boundaries.
These controlled waits are not measured network latency.

| Scenario / run | Completions out of 20 | Safe busy rejections | After 2 s idle | Max sampled heap + external | Max sampled process RSS |
| --- | ---: | ---: | --- | ---: | ---: |
| Immediate / 1 | 4 | 16 | 503 busy | 138.22 MiB | 252.21 MiB |
| Immediate / 2 | 3 | 17 | 200 | 129.52 MiB | 237.25 MiB |
| Immediate / 3 | 3 | 17 | 200 | 129.39 MiB | 239.92 MiB |
| Paced / 1 | 5 | 15 | 503 busy | 125.12 MiB | 244.95 MiB |
| Paced / 2 | 4 | 16 | 503 busy | 132.27 MiB | 239.02 MiB |
| Paced / 3 | 4 | 16 | 503 busy | 131.96 MiB | 237.00 MiB |

Heap-used plus external was about 9.20 MiB before full imports, 18.32–18.52 MiB
after full imports, and 36.69 MiB after fixture materialization. Successful calls
within the initial 20 took 162.21–347.32 ms immediately, or 210.70–371.63 ms when
paced; those are full synthetic handler durations, not CPU-time measurements.

Every observed warm capacity rejection made one synthetic Auth call but **zero
prepare, download, write, commit or remove operations**. The gate intentionally
runs after authentication, before privileged preparation. All three paced runs
remained above admission limits after two seconds idle, while two immediate runs
recovered. The evidence includes before/after-idle samples and per-call effects.

This is a reproducible **ordinary-Deno warm-process liveness warning**, not proof
of an object leak, hosted failure, exact memory peak, or safe sustained capacity.
The unchanged guard is doing its protective job: heap >96 MiB, external >32 MiB,
or their sum >112 MiB denies admission. A post-codec sample can exceed those
admission thresholds because the checks happen before codec execution. Process
RSS is not an isolate memory counter and is deliberately not the gate.

An initial combined exploratory sequence stopped before its burst setup could
reach the held download because the already-warm handler rejected admission.
That was not counted as a passing concurrency test. The recorded scenarios use
fresh processes so concurrency and failure-boundary results are independent of
that warmed state; no failed admission was hidden by retry or forced GC.

## Concurrency and failure boundaries

The recorded burst starts one request and holds its in-memory download. Seven
additional requests return 429 `verification_busy` before prepare, download,
write or commit. Releasing the first request completes successfully, and the next
request succeeds. Sampled heap plus external reached 69.97 MiB. This proves only
one handler instance's lease, not multi-isolate/global concurrency control. Auth
and JSON work still occur before the lease. Effect deltas for concurrent calls
are interval counters, not exclusive per-request Auth attribution.

Fourteen failure-boundary requests passed their expected outcomes:

- Pre-download capacity denial: 503 before prepare. Post-download capacity denial:
  503 before codec/write/commit.
- Prepare refusal: 409. Existing verified media: 200 with no download/write.
- Short input or invalid JPEG: 400 with no write/commit.
- Download or write failure: safe 500, no exception disclosure; failed write does
  not commit.
- Uncertain commit: 409 `verification_pending_retry`, without deleting the
  potentially published output.
- Definite losing output with cleanup failure: 200; only the losing clean key is
  passed to removal, never the winner or quarantine.
- Disabled pipeline: 503. Missing or rejected synthetic authentication: 401.
- A later valid completion succeeds, confirming lease release after failures.

**Failure-boundary runs inject deterministic capacity metrics** to isolate those
branches; they do not claim warm capacity or recovery under measured memory.
The two explicit capacity-denial cases inject over-threshold values. All other
scenarios use actual `Deno.memoryUsage()`. Eight independent boundary checks
cover exact/over heap, external and combined limits, NaN and infinity. Four new
harness tests, formatting, lint, type checking, shell syntax, repository policy
and whitespace checks passed. All 97 existing production Edge tests also passed.
The four guard tests are wired into the Edge CI job. The explicit resource
experiment itself is not run automatically in CI and does not replace other
checks or constitute exact-final-commit CI evidence.

## Remaining gates and supported next steps

Keep the thresholds and disabled upload default unchanged. Current
[Supabase limits](https://supabase.com/docs/guides/functions/limits) document
256 MB memory, two seconds CPU per request and a Free-plan worker lifetime of up
to 150 seconds serving multiple requests. Ordinary Deno's GC, RSS and worker
lifetime cannot establish behavior under those limits. Web Workers and Node vm
are unavailable there; a subworker is not a supported mitigation. Do not propose
unsupported multithreaded sharp/libvips as an Edge drop-in.

Before media enablement, require separately authorized, bounded full-bundle
**actual Edge/hosted** measurements covering repeat warm calls, concurrency and
idle recovery, actual S3 construction/signing, and representative adversarial
image boundaries. A codec-only probe does not satisfy this gate. Real staging
R2 upload/download, exact-byte stream limits, create-only writes, expiring signed
URLs, uncertain commits, winner/loser cleanup and tombstone races remain untested
here. Valid-user authentication/refresh/revocation, cross-user RLS, unattended
cleanup and physical devices remain separate gates.

If actual Edge measurements also show retained-capacity stalls, evaluate a
lower-allocation transform or reduced image ceiling against product image
quality, or a separately authorized image-processing service with enforceable
resource limits. Each changes the design and needs its own measurements and
security review. Raising the guard or promising that retry/idle will reclaim
memory is not supported by this evidence. Bounded backoff can reduce repeated
Auth work but cannot guarantee the same warm isolate recovers.
