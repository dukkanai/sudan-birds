# Apple grant primitives: offline, inert foundation

These shared modules are **not imported by any application endpoint**. They do
not enable Apple sign-in, change account deletion, load secrets, create keys,
install migrations, or schedule work. No hosted Apple/Supabase behavior has been
verified by these synthetic tests. Keep Apple disabled pending the broker,
durable retention/outbox, owner-approved configuration and integration review.

## Contracts

- `apple_grants.ts` pins `jose@6.2.17` and uses its JWS/JWT verification. Only
  RS256, `https://appleid.apple.com`, the exact configured client ID (a string,
  not a multi-audience token), canonical Apple subject, required integer `iat`
  and `exp`, and currently valid tokens are accepted. Token-controlled key URLs,
  embedded keys, unknown algorithms and unsupported JWKS shapes fail closed.
  A future Apple contract change requires explicit review, not a permissive
  fallback. The clock has no implicit tolerance.
- `validateRefreshToken` requires an identity obtained from Auth verification or
  a trusted service-only lookup. It checks that identity's user ID against the
  expected app owner. Its `id` is Apple's provider subject, **not** Supabase's
  `identity_id` UUID. Passing client-supplied identity data would defeat this
  trust boundary. This is not an endpoint, authorization check, or upload API.
- Refresh validation uses Apple's `/auth/token` and verifies the returned signed
  identity against that binding. It returns an immutable binding, token digest
  and validation timestamp, not access tokens. A repeated refresh token remains
  a repeated grant. This timestamp is **not** interactive reauthentication,
  consent, deletion approval, or replay prevention. Keep the existing verified
  session/AMR deletion checks. Future code must enforce durable fingerprint
  deduplication, attempt ownership, deletion gates and state transitions.
- `revoke` requires the retained token fingerprint and matching configured client
  ID. Only an empty HTTP 200 is accepted, including a repeat request for a token
  already invalidated. There are no automatic retries. All errors have fixed
  labels; `outcomeUnknown` marks transport/timeouts, unexpected successful
  statuses, malformed apparent successes and other potentially committed
  outcomes. Any error means **no confirmed receipt**, regardless of that flag.
  A later outbox may retry the same retained token. A returned receipt alone is
  not durable: erase ciphertext only in the transaction recording its success.
- `apple_http.ts` fixes HTTPS destinations to Apple's `/auth/token`,
  `/auth/revoke` and `/auth/keys`; rejects redirects/effective-URL changes; omits
  credentials/referrers and caching; and does not follow token-supplied URLs.
  Each request has a 15-second deadline spanning fetch and body reads, a 32 KiB
  decoded body limit (zero bytes for revoke), and at most 1,024 stream reads.
  Validation can make two sequential requests. There is no hidden JWKS fetch,
  retry, or remote cache in JOSE. Late fetch responses are canceled best effort;
  cancel/dispose failures never replace the primary error or receipt.
- `apple_crypto.ts` uses Web Crypto AES-256-GCM, a fresh CSPRNG 96-bit IV and
  128-bit authentication tag. Keys must be non-extractable AES-256-GCM keys with
  the required usage. Callers provision keys; this module never creates or loads
  production keys. Canonical versioned AAD binds owner, Apple subject, client,
  grant UUID, key version and token fingerprint. Decryption requires independently
  trusted context; do not take it from an untrusted ciphertext envelope. AEAD
  authenticates data/context but does not by itself prevent replay of an identical
  ciphertext at the same context. Future database state must reject retired grants.
- HTTP, deadlines, clock, randomness and Web Crypto operations are injectable for
  offline tests. Production must use the trusted defaults or reviewed equivalent
  dependencies. Synthetic tests generate ephemeral signing/encryption keys in
  memory, never store private signing keys, and make no live service calls.

Errors contain no raw cause, body, credential, token or identity. These modules
perform no logging. Temporary byte buffers are cleared where owned by this code;
JavaScript strings and runtime-internal copies cannot be guaranteed zeroized.

## Offline checks

From `supabase/functions`, after `npm ci --ignore-scripts`:

```sh
npm audit --omit=dev --audit-level=high
deno fmt --check
deno lint
deno check --no-lock --node-modules-dir=manual */index.ts _shared/apple_grants.ts _shared/apple_crypto.ts
deno test --no-lock --node-modules-dir=manual \
  --deny-net --deny-read --deny-write --deny-run --deny-env --deny-sys --deny-ffi \
  _shared/apple_crypto_test.ts _shared/apple_http_test.ts _shared/apple_grants_test.ts
bash test.sh
```

Also run `python3 scripts/check_repository.py` from repository root. The full Edge
test wrapper includes these tests. SDK dependencies use the existing reviewed
runtime-metadata environment allowlist; the focused Apple tests need none.

For this offline slice, a clean `npm ci --ignore-scripts --no-audit --no-fund`
completed, the focused denied-permission suite passed **80 tests**, and the full
Edge wrapper passed **252 tests**. Formatting, lint, endpoint/new-module type
checks, repository policy checks and `git diff --check` passed. The production
dependency audit reported **0 vulnerabilities**. These are local checks of this
slice, not hosted integration, a complete security assessment, or release approval.
An aggregate secret scan remains a separate final-candidate check.

## Deliberately remaining work

The later broker must obtain grants directly from a one-time Supabase PKCE
exchange, quarantine and durably retain its result before accepting the app
session, validate owner bindings, and handle consumed-code/uncertain-write gaps.
Retention cannot be made atomic with the remote exchange merely by these helpers.
Do not claim capture of every possible upstream-issued grant.

An encrypted private grant store and revocation outbox must handle multiple
logins, unlinking, account switches, late callbacks, re-registration during old
deletion, independent Auth deletion, leases/retries and confirmed ciphertext
erasure. Missing tokens require Apple's documented fallback without indefinitely
blocking local account/data deletion. Key provisioning/rotation, secret storage,
rate limits, unattended scheduling and hosted tests need their own review and
applicable owner approvals. No such work is activated here.

Official contracts:

- [Apple token validation](https://developer.apple.com/documentation/signinwithapplerestapi/generate-and-validate-tokens)
- [Apple token revocation](https://developer.apple.com/documentation/signinwithapplerestapi/revoke-tokens)
- [Apple account-deletion guidance](https://developer.apple.com/documentation/technotes/tn3194-handling-account-deletions-and-revoking-tokens-for-sign-in-with-apple)
- [Supabase provider-token responsibilities](https://supabase.com/docs/guides/auth/social-sign-in#provider-tokens)
