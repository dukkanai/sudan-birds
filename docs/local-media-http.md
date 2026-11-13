# Disposable local media HTTP integration

The database CI job runs `scripts/media_http_local.py --local-disposable` after
starting its isolated `sudan-birds-local` Supabase stack and applying migrations.
Only CLI-generated local status is accepted, from a private owner-controlled file.
The launcher removes inherited environment variables and passes only the local
API URL/public/admin keys over stdin. No hosted credentials, R2 credentials,
Cloudflare calls, gateway changes or deployed code are involved.

A loopback Deno HTTP server imports the production media and media-read handlers,
Auth helpers, codec and media orchestration unchanged. Auth.getUser and
PostgREST/RPC run against real local Supabase. Storage dependency methods alone
are replaced by an in-memory simulation. Placeholder URLs are never fetched.
This is **not** a Supabase Edge container/gateway or R2/S3 integration test; existing
separate Edge resource experiments cover different boundaries.

Coverage includes missing/invalid callers, cross-owner reservation/completion,
owner completion, canonical JPEG bytes and removal of synthetic metadata, stored
owner/listing/dimensions/type/size/alt text, idempotent completion, public and
user-authenticated read behavior, invalid-token fail-closed reads, block-aware user reads while public reads remain
available, authenticated
media read, and malformed-image failure without publishing an additional row.
The synthetic JPEG is generated at runtime and includes a test-only comment.

The runtime grants network access only to 127.0.0.1 ports 54321 and 54329, bounds
requests/timeouts, rejects redirects, and denies runtime filesystem, process,
system and FFI access. Only four unset SDK import flags may be read from the
otherwise scrubbed environment (SMITHY_NEW_RETRIES_2026,
AWS_LAMBDA_NODEJS_NO_GLOBAL_AWSLAMBDA, AWS_LAMBDA_BENCHMARK_MODE,
AWS_NEW_RETRIES_2026); no environment credentials are available. It runs only cached modules. The launcher records
commit and source hashes and prints fixed pass/fail labels, never raw output,
credentials, object keys or placeholder URLs. It suppresses errors that might
contain credentials, including startup errors. Source hashes distinguish local
uncommitted changes from the commit identifier.

Two randomly named synthetic local users and their data remain until the existing
CI `always()` cleanup destroys the entire disposable stack with `stop --no-backup`.
There is no user deletion API call. The HTTP server shuts down in `finally` and
clears simulated objects; shutdown failures fail the test. The outer workflow
timeout and cleanup also cover an interrupted process or failed setup. Never run
this against a developer's persistent stack. Failure of cleanup is a failing CI
step, not a successful test. No artifact containing credentials is uploaded.

Passing this focused harness does not establish hosted readiness, real storage
semantics, provider lifecycle cleanup, all security properties or device/release
readiness. Full-stack success may only be claimed for a CI run on the exact source
commit that executes it, not from offline boundary tests or type checking.
