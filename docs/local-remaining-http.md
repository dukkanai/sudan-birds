# Disposable contact and lifecycle HTTP checks

`scripts/remaining_http_local.py --local-disposable PRIVATE_STATUS_FILE` runs the
actual contact, account-delete and lifecycle handler factories over loopback HTTP.
It requires Deno 2.5.6, cached dependencies, a fresh `sudan-birds-local` Supabase
stack, applied migrations and the test-only `scripts/remaining_http_fixture.sql`.
The CI database job creates these prerequisites and always stops the stack. The
fixture SQL is **not a migration and must never be installed on hosted services**.

The launcher reuses the existing private-status validation, minimizes credentials
passed through stdin, scrubs inherited environment variables, denies filesystem,
process and FFI capabilities, and only permits network ports 54321 and 54329 on
127.0.0.1. An additional path/method guard allows Auth Admin deletion only for
synthetic users created by this invocation. No credentials, tokens, identities,
response bodies or arbitrary errors are printed. Runtime and request counts are
bounded. Output identifies the source commit and SHA256 of the tested sources.
Failure output contains only an allowlisted phase (`setup`, `contact`, `deletion`,
`lifecycle_authorization`, `lifecycle_batching`, `lifecycle_reconciliation`,
`unrelated_fixture`, or `shutdown`) and bounded decimal check/request counters.
The check counter counts harness assertions, including transport guards; the
request counter counts attempted real backend and handler HTTP requests. The
launcher rejects arbitrary, malformed or duplicate failure labels. A shutdown
failure cannot replace the first failure's phase/counters, and PASS is emitted
only after successful shutdown.

## Coverage

- Contact: genuine password session; missing, malformed and anonymous identity;
  explicit caller consent; absent contact and owner opt-out; opt-in response shape;
  hidden listing, both block directions, missing and deleted listing; simulated
  Auth unavailability denies downstream work.
- Account deletion: genuine local Auth session and real recent-session database
  checks; missing/invalid identity, wrong confirmation and injected owner rejected;
  owner-scoped real deletion RPC; unproven simulated fence leaves all objects and
  Auth user pending.
- Lifecycle: anonymous, ordinary user and wrong job secret rejected; scheduler
  secret cannot request administrator cleanup; actual scheduled claim, at most
  three objects per batch, durable pending status, controlled fixture retry,
  completion only after all four simulated fences; real local Auth Admin deletion
  whose response is deliberately lost and reconciled through real GET 404; empty
  repeat does not delete twice; unrelated user's Auth identity and listing survive.

## Limits and explicit gaps

This is simulated storage, **not evidence of real R2 removal or fencing**. The
fixture adapter inserts four synthetic registry objects with elapsed safe-delete
windows and clears only their owner's retry lease to avoid wall-clock sleeps.
Real sessions and real database deletion RPCs are used; no assertion claims that
an artificially edited token proves real stale/revoked-session handling. Those
end-to-end session cases remain outside this harness.

**Contact rate limiting is not implemented in the current handler or RPC.** No
rate-boundary success is claimed or arbitrary threshold introduced by these tests.

The integrated scenario cannot run in a container without Docker. Offline guard,
format, lint and type checks do not constitute an integration pass. Only a successful
fresh-stack CI run on the exact reviewed source provides local HTTP evidence.
This harness does not authorize a hosted deployment, a production account deletion,
or release approval.
