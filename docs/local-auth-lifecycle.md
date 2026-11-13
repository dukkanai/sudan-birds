# Disposable local Auth lifecycle checks

## Status and scope

Added on 2026-11-09 against checkout base
`b4f39445b386dd3bd9ec682af5214b04233f9f41` with working-tree changes. The 41
new offline harness tests pass. They use mocked transport/responses and temporary
private files, not a Supabase service. A fixed-response transcript also exercises
the complete lifecycle orchestration, but is **not live integration evidence**.
Docker and the Supabase CLI are unavailable in the editing environment, so the
actual GoTrue/PostgREST run remains **pending exact-commit CI**. No hosted Auth
project, real email/account, Cloudflare service, OAuth provider or mobile device
was accessed. No production configuration or migration was changed.

`scripts/auth_lifecycle.py` supplements, rather than replaces,
`scripts/api_smoke.py`. The existing harness tests wider marketplace behavior
using locally signed synthetic caller JWTs. This new harness obtains genuine
local user access and refresh tokens from GoTrue password sign-in, then uses the
returned user access tokens for ownership/RLS checks.

## Live assertions to run in CI

- Create exactly two fresh synthetic users through Auth Admin, with explicit
  random UUIDs, unique `.invalid` emails, random in-memory passwords and
  `email_confirm=true`. No signup, invite, recovery or email-sending endpoint.
- Reject a wrong password and malformed refresh token; sign both accounts in
  and validate the returned identity, authenticated role, expiry and session ID.
- Confirm Auth `get-user`, deny ordinary-user Admin access, reject spoofed
  profile ownership, and require the owner's own terms acceptance.
- Publish a listing using a real session; reject cross-user updates/deletion and
  check the original row is unchanged. Refresh the owner session and check
  refresh-token rotation, stable session ID and unchanged ownership restrictions.
- Reject malformed access tokens at Auth and PostgREST. Separately reject a
  **correctly signed expired local fixture** made from a verified local-issued
  JWT's claims, preserving its user/session and changing its time claims. This
  is cryptographic expiry-path coverage, not observation of natural expiry of
  an unchanged server-issued JWT. The harness deliberately requires local HS256
  and fails closed for another signing algorithm; it does not validate hosted
  ES256 signing, provider flows, timeouts, inactivity limits or key rotation.
- Log out the current owner session using `scope=local`. Require the current
  refresh token to be rejected and Auth `get-user` to return `session_not_found`.
  Also require the still-unexpired issued JWT to retain owner-only PostgREST
  access: ordinary JWT validation/RLS does not check `auth.sessions` existence.
  Logout is therefore **not universal immediate access-token revocation**.
- Confirm the other user's refresh still works, a fresh owner login gets a new
  session, and the owner can delete their listing. This is two-user isolation,
  not a claim to test all logout scopes or concurrent devices of the same user.
- Delete only this invocation's two exact synthetic Auth users, verify absence,
  and rely on their existing foreign-key cascades for their local profiles/data.

## Safety and cleanup boundaries

The command requires `--local-disposable`, the repository marker
`project_id = "sudan-birds-local"`, default local API port 54321, and a regular,
owner-controlled status file with no group/other permission. Symlinks are refused.
Only canonical `http://127.0.0.1:54321` or `http://[::1]:54321` is accepted
(optional single trailing slash); hostnames, alternate ports, URL userinfo,
paths, queries, fragments and parser-normalized alternatives are rejected before
sending any credentials. Every request, including cleanup, rechecks the target.
The explicit opt-in is the caller's assertion that this is a disposable stack;
a loopback address by itself cannot prove that a port is not forwarded.

A narrow method/path allowlist and separate Admin/caller headers prevent the
service key from being used on the application data routes. Direct `http.client`
connections do not consult environment proxies and never follow redirects.
Every 3xx fails. Request and response bodies are bounded to 64 KiB. There are at
most 80 normal requests and a separate eight-request cleanup allowance, with no
automatic retries. Socket timeouts are five seconds; response body reads check a
ten-second request deadline between chunks and normal work checks a 120-second
budget. These are **not absolute whole-request deadlines**: slow header reads
can exceed a socket timeout budget. CI must additionally enforce the 180-second
process deadline below; the final always-run stack teardown covers termination.

Before creating an account, an exact-ID Admin lookup must return the specific
`user_not_found` error. The UUID is recorded before POST so a lost create response
can be handled. Cleanup checks that exact ID and verifies its email and per-run
Admin metadata marker before deletion. It never enumerates accounts, searches by
email, retries a write, deletes an unverified user, or writes directly to
`auth.users`. A failed cleanup does not prevent attempting the other fixture and
makes the suite fail. The disposable stack must still be destroyed, including on
cancellation or if a response/cleanup outcome is uncertain. Local Auth audit logs
may persist until that teardown; they must not be exported as public artifacts.

Only static assertion labels, counts and source fingerprints are printed. Error
bodies, URLs, identities, passwords, status-file data and arbitrary exception text
are suppressed. The CLI status file remains private and is removed by the shell
trap. Do not enable shell tracing or upload status/startup/container logs.

## Reproduce and retain source evidence

Offline, with Python 3.11 or newer:

```sh
python3 -m unittest discover -s scripts -p 'auth_lifecycle_test.py'
```

After starting the already-approved disposable CLI stack and applying migrations,
CI runs the new step after the existing PostgREST harness has cleaned its fixtures:

```sh
umask 077
trap 'rm -f "$RUNNER_TEMP/birds-status.json"' EXIT
"$RUNNER_TEMP/birds-cli/node_modules/.bin/supabase" status --output json > "$RUNNER_TEMP/birds-status.json"
timeout --signal=TERM --kill-after=10s 180s \
  python3 scripts/auth_lifecycle.py --local-disposable "$RUNNER_TEMP/birds-status.json"
```

The workflow's always-run `supabase stop --no-backup` remains mandatory. No test
credential should be copied into GitHub secrets or committed to the repository.

At runtime the harness prints the checked-out Git commit and SHA-256 fingerprints
of the implementation, its tests, CLI installer, CI workflow, local configuration
and migration chain. These distinguish a dirty checkout from its base SHA. Record
the exact CI run URL and passing assertion count for the final committed source
before changing this pending status. Offline tests and older green CI runs do not
certify a later source revision or authorize merge, deployment or release.

## Upstream contract references

Reviewed 2026-11-09; these references establish expected behavior, not execution:

- [CLI 2.67.1 image pins](https://github.com/supabase/cli/blob/v2.67.1/pkg/config/templates/Dockerfile)
  select GoTrue 2.184.0 and PostgREST 14.1.
- [GoTrue 2.184.0 Admin API](https://github.com/supabase/auth/blob/v2.184.0/internal/api/admin.go)
  supports explicit user IDs, email confirmation, Admin metadata, exact-user
  retrieval and deletion (AdminUserParams, adminUserCreate, adminUserDelete).
- [GoTrue 2.184.0 Auth validation](https://github.com/supabase/auth/blob/v2.184.0/internal/api/auth.go)
  verifies JWT signatures/expiry and looks up nonempty session IDs; a missing
  session returns `session_not_found`.
- [GoTrue 2.184.0 logout](https://github.com/supabase/auth/blob/v2.184.0/internal/api/logout.go)
  selects `LogoutSession` for `scope=local` and returns HTTP 204.
- [GoTrue 2.184.0 refresh validation](https://github.com/supabase/auth/blob/v2.184.0/internal/api/token_refresh.go)
  returns `validation_failed` for the deliberately malformed refresh string.
- [Supabase sign-out documentation](https://supabase.com/docs/reference/javascript/auth-signout)
  distinguishes refresh-token invalidation from already-issued access JWTs, which
  remain valid until expiry. Auth session lookups and plain PostgREST JWT/RLS
  therefore need separate assertions.
