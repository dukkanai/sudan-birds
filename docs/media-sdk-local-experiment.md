# Local real-SDK media experiment, 2026-11-09

Development evidence only. No production source, threshold, upload setting,
credential, hosted account, object, function or permission was changed. The
previous [bundle baseline and encoder comparison](media-bundle-resource-experiment.md)
remain immutable. This experiment exercises more SDK work but does not establish
hosted R2 integration or media readiness.

## Source and execution boundary

Production base: `b4f39445b386dd3bd9ec682af5214b04233f9f41`. The
[evidence record](evidence/media-sdk-local-2026-11-09.json) identifies every measured
source file and relevant installed SDK implementation by SHA-256, and retains all
11 final run reports, samples and effects (211 handler requests).

`scripts/media_sdk_resource.sh` requires explicit `--run-local`, a closed scenario
name, an absolute native Deno binary and cache directory. Deno must be 2.5.6.
Before execution the launcher checks exact hashes of production `r2.ts`,
`presign.ts`, `image_stream.ts` and `package-lock.json`. Any drift stops the run
until correspondence is reviewed. Three offline launcher tests verify argument
rejection, an exact match of the unchanged pins, and independent mutation of each
pinned file in disposable copies.
Do not bypass the launcher and claim the source pins were checked.

The process has no network, file-read/write, subprocess, sys or FFI permission;
the driver also queries and asserts those denials. Module loading uses the
existing dependency tree/cache. The environment is cleared, with an inert home
path and empty AWS configuration locations; only required SDK metadata names are
readable. Credentials are literal synthetic non-credentials. Global fetch rejects.
No listener, service, real user or storage object exists. Reports do not contain
signed URLs, signatures, credential literals, request bodies or arbitrary SDK
exception messages.

Each process is bounded by 64 handler requests, 128 clients, 128 SDK transport
attempts, 1,024 stream chunks, 768 samples, a 90-second checked deadline and an
external 120-second timeout. No forced GC, V8 tuning, threshold increase or Web
Worker is used. Direct dependencies remain the existing pinned AWS S3 client and
presigner 3.1164.0, Supabase JS 2.57.4 and jpeg-js 0.4.4; no dependency was added.

## Exactly what executes

The actual media handler and bounded encoder execute. Actual Supabase clients,
Auth.getUser and RPC serialization use a closed synthetic transport. The local
storage adapter constructs real `S3Client` instances, uses real GetObject,
PutObject and HeadObject commands, and exercises SDK serialization, SigV4 signing,
response deserialization and `Body.transformToWebStream()`.

An independent WebCrypto implementation recomputes signatures inside the closed
transport. Tests change the method, object path, expiry and each required upload
header to verify rejection. This is cryptographic fixture verification, not
acceptance by AWS or R2.

Correspondence to production `r2.ts`:

| Production operation | Local corresponding sequence | Deliberate difference |
| --- | --- | --- |
| Client factory | Same region `auto`, checksum policy `WHEN_REQUIRED`, maxAttempts 2, standard retry/defaults, disabled FIPS/dualstack and fixed user-agent provider | Synthetic `.invalid` endpoint/credentials and closed injected requestHandler |
| `signUpload` | Real production `presignCreateOnly`, including exact length/type/create-only signed headers | Returned URL is inspected/used only in memory |
| `signRead` | Real GetObjectCommand and getSignedUrl, 60-second expiry | Independent local signature verification; no URL is printed |
| `downloadImage` | New client, GetObjectCommand, 15-second AbortSignal, SDK stream conversion, metadata checks and production `readExactImageStream` | Response bytes are synthetic 64-KiB chunks, not socket data |
| `writeVerified` | Same expiry clamp, real upload presign, create-only request headers and error mapping | Closed in-memory signed PUT replaces fetch; real fetch timeout/redirect behavior is not exercised |
| `removePayloadAndFence` | One new client for actual zero-byte PutObject followed by HeadObject, metadata verification and 10-second signals | Closed transport retains only object metadata, never uploaded image payloads |

The production R2 factory itself remains private and is not called: this is a
source-pinned local adapter, **not proof of production adapter injection/wiring**.
The primary workload preserves production's new-client-per-helper, no-destroy
behavior. A separate comparison destroys each client after its complete operation,
after download stream consumption/cancellation, and never changes production.

After each successful completion, the workload separately signs a read URL and
writes/verifies an **orphan** tombstone. It never cleans a published winner.
Those supplemental operations increase SDK work beyond a single media completion.
Handler latency excludes the supplemental work; total duration and memory include
it. Independent signature verification is simulated server work that would normally
run remotely, and adds crypto allocations/CPU here. Samples also include the fixed
fixture, chunk copies and instrumentation. These are neither isolated SDK-allocation
measurements nor a proven upper bound on real production resource usage.

## Recorded measurements

All final runs use the same 640×640 synthetic JPEG: 571,931 input bytes and
571,691 canonical output bytes. Each sequential run makes 20 calls, waits two
seconds, then makes one recovery call. Paced runs add 100-ms inter-request gaps
and 5-ms synthetic transport waits. There is one handler per process.

| Scenario / run | Initial completions | Recovery | Max sampled heap + external | Max sampled process RSS |
| --- | ---: | --- | ---: | ---: |
| Immediate / 1 | 19/20 | 200 | 78.14 MiB | 181.55 MiB |
| Immediate / 2 | 20/20 | 200 | 62.45 MiB | 163.78 MiB |
| Immediate / 3 | 20/20 | 200 | 62.54 MiB | 160.58 MiB |
| Paced / 1 | 20/20 | 200 | 63.10 MiB | 164.95 MiB |
| Paced / 2 | 20/20 | 200 | 62.56 MiB | 165.80 MiB |
| Paced / 3 | 20/20 | 200 | 62.50 MiB | 161.86 MiB |
| Destroy comparison / 1 | 20/20 | 200 | 62.51 MiB | 162.77 MiB |
| Destroy comparison / 2 | 20/20 | 200 | 62.52 MiB | 162.29 MiB |
| Destroy comparison / 3 | 20/20 | 200 | 63.06 MiB | 165.61 MiB |

The first immediate run's twentieth request returned 503 `image_verifier_busy`:
external memory was 40.14 MiB, above the unchanged 32-MiB external gate, even
though combined memory was below its 112-MiB gate. It made one Auth call but zero
prepare, client construction, GET, write or commit operations. This result is
retained, not removed or retried. External memory was still high at the post-idle
sample; the next request succeeded. Thus success after idle does not establish
that idle alone reclaimed memory or that another request is guaranteed to recover.

Each fully successful sequential process constructed 84 clients, performed 63 SDK
transport attempts, verified 105 signatures and fully consumed 21 image streams.
The primary runs called destroy zero times; the comparison called it 84 times.
Successful initial handler durations ranged 134.01–913.60 ms immediately and
166.63–273.86 ms paced. These are local wall times, not CPU-budget measurements;
no exclusive machine scheduling or continuous peak measurement is claimed.

The burst run held one SDK download while seven additional calls returned 429
before client construction or protected effects. Release and the following
completion both succeeded. This proves one handler's lease, not global/multi-isolate
concurrency control.

## Failure and stream checks

The final boundary run passed 13 handler requests plus a separate bad-fence check:

- Wrong response length/type and streamed overflow return 400 and cancel the SDK
  stream. Truncated data returns 400 after stream exhaustion.
- Missing response body triggers an SDK exception before the adapter's `!Body`
  check, so the outer media boundary returns safe 500. An exploratory expectation
  of 400 failed and was corrected to reflect actual SDK behavior, not counted as
  a pass. No write or commit occurs.
- AccessDenied is not retried. One synthetic 503 SlowDown is retried once and
  succeeds, retaining the configured maximum of two attempts.
- An actual 15-second stalled response-body timeout returns 502
  `image_download_timeout` and cancels the stream. This tests stream timeout after
  the SDK returns a body, not real socket cancellation.
- Signed create-only conflict returns 409; failed signed PUT returns 502; neither
  commits. Local PUT handling does not simulate network redirects/retries.
- Injected pre/post-download admission denials return 503 with no write/commit;
  early denial creates no S3 client, later denial has consumed the source stream.
- Incorrect tombstone metadata is rejected; a later completion succeeds.

Eight new Deno tests passed with runtime permissions denied, including independent
signature tampering, exact stream bytes/cancellation, SDK retry/error behavior and
cleanup comparison. Three Python launcher tests passed, as did formatting, lint,
type checking, shell syntax, repository policy and whitespace checks. All 105
existing production Edge tests also passed. Source-hash and evidence-redaction
checks passed. The positive unchanged-pin test was added after measurement;
the evidence keeps its historical guard-file hash and records the updated test
hash separately. No measured runtime source or run result changed. These local
checks do not replace final-commit CI or service integration.

## What client lifetime does and does not show

A separate construction-only inspection resolves this ordinary-Deno SDK to runtime
`node` and `NodeHttpHandler`, with no send or socket opened. The pinned SDK source
shows NodeHttpHandler creates an HTTPS agent with `keepAlive=true` and `maxSockets=50`
per handler, and its destroy method destroys initialized agents. Smithy Client's
destroy method delegates to `requestHandler.destroy()`.

Production creates fresh clients for helpers and never calls destroy. Under a
real NodeHttpHandler transport, this discards client/agent reuse and provides no
explicit cleanup of idle sockets once an operation finishes. The per-agent limit
is not a process-wide connection limit. That is a concrete resource-ownership risk
worth reviewing, **not evidence of an observed socket or heap leak**. Actual Deno
shim/hosted transport behavior and server idle closure remain unmeasured.

The injected handler owns no sockets or persistent handles, and its destroy only
increments a counter. Similar no-destroy and destroy measurements cannot prove
socket safety, quantify a leak, or show destroy fixes the transient memory denial.
Signing-only operations do not send HTTP and do not by themselves demonstrate a
connection leak. If explicit per-operation cleanup is adopted later, download
cleanup must occur after full body consumption/cancellation, not immediately after
`client.send()` returns its stream. Client reuse is an alternative design requiring
its own isolation, concurrency and shutdown review. Neither change is made here.

## Reproduce and remaining gates

Use the reviewed launcher after preparing the existing pinned dependency tree:

```sh
export DENO_BIN=/absolute/path/to/native-deno-2.5.6
export DENO_DIR=/absolute/path/to/prepared-cache
bash scripts/media_sdk_resource.sh --run-local sequential
bash scripts/media_sdk_resource.sh --run-local sequential-paced
bash scripts/media_sdk_resource.sh --run-local burst
bash scripts/media_sdk_resource.sh --run-local boundaries
bash scripts/media_sdk_resource.sh --run-local destroy-comparison
python3 -m unittest discover -s scripts -p media_sdk_launcher_test.py
```

The scripts are explicit local tools, not a deployed function or new CI service.
Keep uploads disabled and thresholds unchanged. Actual Supabase Edge CPU/memory,
worker reuse and recovery, real R2 signatures/streams/create-only enforcement,
network timeout/retry behavior, cleanup races/tombstone durability, valid-user
Auth/RLS and physical-device checks remain gates. No successful synthetic signature
or metadata check establishes the corresponding service guarantee.
