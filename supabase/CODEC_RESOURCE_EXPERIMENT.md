# Local Edge Runtime resource experiment

This isolated CI experiment uses only the committed synthetic 640×640 JPEG. It
creates no hosted resources or persistent credentials. The known synthetic token
is not a secret and is never suitable for a hosted endpoint. No user images are
accepted. Production media stays disabled regardless of this result.

The separate workflow archives the reviewed commit into a disposable directory,
changes only that copy, and sets explicit `per_worker` policy, Deno 2 and a literal
20-minute deadline shared by all isolates. Existing `verify_jwt=true` remains in
force. The client reads local CLI status from a private temporary file, validates
literal IPv4 loopback, disables proxies and redirects, and sends at most 20
sequential bodyless requests. Failures stop the test without retries. CLI output,
status files, arbitrary response bodies and credentials are not printed or
uploaded. Cleanup runs both in Python finally and an unconditional workflow step.

The disposable entrypoint also imports and retains the actual R2 and Auth helper
namespaces, checking their twelve exported functions without invoking them. A fixed
response marker is required on every request. This exercises SDK module initialization
and retained import footprint; it does not call Auth, R2 or database operations. The
hosted diagnostic handler remains unchanged.

All 20 requests must return valid 200 metrics, 640×640 output, a positive bounded
JPEG size and the exact deadline. At least one response must have `calls > 1` to
prove warm-worker reuse. Any 429, 503, worker kill, timeout, malformed response or
missing warm evidence fails this experiment. There is no burst phase. Counter
resets due to worker retirement are expected. Only selected numeric metrics and
runtime image identity/digests are emitted. RSS is recorded separately, never
compared with the 256MiB isolate limit. Elapsed time is not CPU time.

## Verified source semantics

- CLI [2.67.1 main worker](https://github.com/supabase/cli/blob/v2.67.1/internal/functions/serve/templates/main.ts)
  configures 256MiB memory, 1000ms soft / 2000ms hard CPU and normally 400s wallclock.
- Its [Dockerfile](https://github.com/supabase/cli/blob/v2.67.1/pkg/config/templates/Dockerfile)
  pins Edge Runtime v1.69.28. The harness verifies the running image, policy,
  absence of inspector flags and main worker memory/CPU constants before requests.
- The pinned runtime's [per-worker supervisor](https://github.com/supabase/edge-runtime/blob/v1.69.28/crates/base/src/worker/supervisor/strategy_per_worker.rs)
  accumulates CPU over the worker lifetime, retiring workers at the soft limit.
  This is not the hosted documentation's 2s-per-request claim.
- [Memory implementation](https://github.com/supabase/edge-runtime/blob/v1.69.28/crates/base/src/runtime/mod.rs)
  measures used heap plus external memory, optionally malloced memory, and applies
  V8 heap / ArrayBuffer allocator limits. Whole-process RSS is not this measure.

## Limits of the evidence

This is an actual local user-worker supervisor test, not plain Deno, but it is
not a hosted-runtime equivalence claim. It covers one fixed noisy baseline JPEG,
not every hostile JPEG, concurrent production workload, SDK request-processing allocations or
R2 upload/verification/deletion integration. Hosted compatibility and resource
checks, adversarial tests and actual R2 integration remain release gates. A local
pass must never enable the pipeline automatically.

The harness is statically/unit tested locally. Actual Docker-backed execution
must be observed in the separate workflow; the development executor has no
Docker. Do not describe a CI result until the exact commit's run finishes.
