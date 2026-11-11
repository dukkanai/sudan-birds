# SDK experiment adapter alignment, 2026-11-11

This is a source-correspondence and unit-test update, not a new resource experiment.
Historical measurements in [the lifetime supplement](media-sdk-lifetime-supplement.md)
and [the original SDK report](media-sdk-local-experiment.md) retain their original
source attribution. No historical evidence JSON or measurements were changed.

## Reviewed correspondence

- The driver injects its closed transport through `AuthRuntime.fetch`, rather than
  replacing the client options' fetch function. The actual production
  `backendFetch` wrapper now supplies the Auth/PostgREST abort deadline and safe
  transport-error normalization, with the real caller/service identities intact.
- Fixture-owned client cleanup catches destruction failure and reports only the
  production fixed event. It preserves the operation's success or primary error.
  The explicit no-destroy mode remains a counterfactual, not a production baseline.
- Signed PUT response cleanup calls the actual bounded production stream helper.
  Rejected or never-settling cancellation cannot replace confirmed HTTP success,
  create-only conflict, or storage failure. Synthetic response bodies and destroy
  hooks exercise these paths without network access.
- The launcher now pins 21 fixed reviewed paths: the full imported application
  media/Auth/HTTP/codec/trial helper graph, the synthetic JPEG fixture, Deno/npm
  configuration and lockfile, plus the experiment driver and SDK adapter. This
  includes `stream_cleanup.ts`, `diagnostics.ts`, `backend_fetch.ts` and `auth.ts`.
  The launcher's test uses the same fixed path allowlist and verifies drift
  rejection for every entry before Deno execution. Updating pins requires review;
  it does not make an earlier resource measurement applicable to changed code.

## Verification and limits

With pinned Deno 2.5.6, all **18 SDK unit tests** passed, including three new tests
for transport-wrapper wiring, destruction failures, and bounded signed-PUT
response cancellation. All **3 Python launcher tests** passed, including all 21
pin matches and individual mutation rejection. Formatting, lint, type checks for
all three TypeScript harness files, shell syntax and whitespace checks passed.

The SDK unit tests use a cleared environment, cached-only/no-remote module
resolution, an explicit SDK metadata environment allowlist, and denied network,
file read/write, subprocess, sys and FFI permissions. No resource scenario was
run. No hosted calls, real credentials, R2 objects, deployments, upload enablement,
threshold changes, dependency updates or iOS changes were made. Synthetic
transports do not establish actual network cancellation, socket cleanup, hosted
Auth/RLS correctness, resource capacity, or production readiness.
