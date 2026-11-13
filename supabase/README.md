# Backend foundation and release gates

The two historical migrations are immutable deployment history. The third forward
migration removes the discontinued timeline and changes uploads to listing-only.
The removal was applied once to the owner's designated staging project on
2026-11-09, after explicit approval of the exact project and permanent deletion.
All 23 hosted schema/privilege checks and 12 GET-only API checks passed. See
`../docs/verification.md` for exact migration evidence and remaining gates.
Local functional tests do not prove hosted end-to-end behavior. No credential is
contained here.

## Timeline removal and compatibility

`202611090002_remove_timeline.sql` uses a transaction and exclusive locks, fails
if timeline content, related media/reservations/reports, audit actions or publishing
history exist, and removes only the six known development topic labels. Unknown
topic labels also block migration. A populated instance needs a separately approved
retention/export/cleanup plan. It never deletes the shared object registry.

Tables `posts`, `replies`, `topics`, their local policies/indexes/triggers and the
reply validator are removed. Reports keep listing/account targets. Media and upload
intents require a listing. The old four-argument `reserve_upload` RPC is removed;
the new arguments are `p_listing`, `p_bytes`, `p_mime`. Old endpoints or payloads
fail closed. The Edge reserve endpoint rejects legacy and unknown input fields,
including a `post_id` even when null. Coordinate the database, Edge and client
release; old clients are incompatible. Hosted schema cleanup is complete; no
Edge function or application deployment is implied by that cleanup.

## Data/API contract

- Anonymous reads: visible profiles, listings and verified media metadata.
- Authenticated mutations use caller JWT + RLS; IDs, owners, ranking timestamps,
  expiry and moderation state cannot be changed by clients.
- Offers require finite nonnegative numeric `price`; requests allow an optional budget.
  Currency is an ISO-shaped three-letter code. Prices must be filtered by currency.
- Listing states: active, reserved (offers only), fulfilled, closed, expired. Display
  fulfilled as sold for an offer and found for a request. New expiry is 30 days.
- Feed clients must filter active + `expires_at > now()` by default, order by
  `(created_at DESC,id DESC)`, and use both values as cursor. Historical content remains readable.
- Reports target exactly one listing or account. Only reporter and
  trusted moderators read them. No client may mutate report processing state. Target
  deletion preserves the report and its target UUID; no deleted-content snapshot is
  retained. The moderation UI must show a missing/deleted target honestly. Reporter
  account deletion still cascades submitted reports pending the final retention policy.
- `profiles.accepted_terms_at` is required before publishing. The client supplies
  the acceptance time after showing the versioned terms; server attestation of
  terms version is not yet implemented.
- Profile contacts are owner-only. `reveal_listing_contact(p_listing,
  p_explicit_consent)` only reveals an owner's opted-in contact for a live listing
  after explicit requester consent. Blocks deny this RPC in both directions.
- Blocks filter logged-in API reads and contact access. Anonymous content
  remains public by product design; blocking is not a confidentiality boundary
  against somebody signing out or using a different account.
- Moderator/admin roles are provisioned only by trusted maintenance, never JWT
  user metadata. `moderate_content` supports listing-only audited hide/restore; `resolve_report`
  supports audited reviewing/resolved/dismissed states, and `moderator_report_target`
  exposes only sanitized target content, including an explicit missing-target state.
  Private contacts are excluded. Account bans and permanent moderator account
  deletion are not part of these RPCs.
- All public tables have RLS. Private quota events survive content deletion and
  impose serialized rolling daily budgets. Configure `private.publish_limits`
  through trusted maintenance only (50 listings and 20 reports).

## Edge boundaries

`contact`, `media`, `media-read`, `account-delete` and `lifecycle` accept POST JSON only.
Protected callers must pass Supabase `Auth.getUser` verification before any database,
service-client or storage operation. Caller-scoped queries retain that exact bearer
token and public API key for RLS; privileged operations derive ownership from the
verified Auth user, never unverified JWT claims or request JSON. A malformed Auth
response, missing identity or invalid UUID fails as `401 invalid_session`, including
malformed HTTP 200 bodies that the SDK can normalize into a truthy user. `lifecycle` also
requires its caller-RLS admin check, unless a separately configured, scoped job
credential authorizes the scheduled path. No such credential or schedule is enabled.
`media-read` allows anonymous RLS reads with no bearer or a configured public key;
any supplied user token must pass Auth verification, with no anonymous fallback.
All five bound JSON bodies to 8 KiB, return safe error codes and never log request
headers, JWTs, contact details, signed URLs or arbitrary errors.
The outer try/catch is an API boundary, not a replacement for validation or tests.
Database constraint errors intentionally abort their transaction; swallowing SQL
exceptions would weaken the security controls.

### Modern signing keys and gateway deployment settings

The approved configuration in `config.toml` sets `verify_jwt=false` for exactly
those five application functions. Supabase's **Verify JWT with legacy secret**
gateway rejects modern asymmetric signing-key tokens; disabling that legacy check
does not disable the handler's `Auth.getUser` verification or database RLS.
The expired, undeployed `codec-diagnostic` retains `verify_jwt=true` and is outside
this approval. Keep `MEDIA_PIPELINE_ENABLED` absent or `false`.

Signing-key inspection found current ECC P-256, previous HS256 and an ES256 public
JWKS. After explicit owner approval and all seven exact-commit checks, all five
wrappers were updated to immutable source
`3c0cecf232ca3ed4c4df5ae7c905ef6e9a6e9d7f`, containing the Auth identity guard,
before the five legacy switches were saved off. Do not use a moving source branch.
No diagnostic, credential, scheduler or upload enablement was added.

All 29 actual handler-boundary checks passed: method restrictions, missing/public
credentials and forged tokens for protected functions, plus anonymous media-read
errors and refusal to downgrade an invalid user token. Every response included
an application request ID and no-store caching. See `../docs/verification.md`.
Unsigned expired-shaped forgeries are not valid-token expiry proof. Actual
signed-in users, modern GoTrue issuance/refresh/revocation, cross-user hosted RLS
and successful protected operations remain unverified. Custom secrets are empty
and media mutations remain disabled.

## Verified media and self-account deletion

The second migration and Edge code implement a JPEG-only verification pipeline,
registered immutable output objects, race-safe service-only finalization, durable
orphan cleanup and self-account deletion jobs. These new operations are locally
tested, not yet proven in the deployed staging stack.

**Keep `MEDIA_PIPELINE_ENABLED=false`.** The pure-JavaScript JPEG codec is bounded
and strips metadata, but warm-isolate memory/availability remains an explicit blocker.
The current conservative limit is 640×640 / 409,600 pixels, 2 MiB JPEG bytes, three
attachments per item and twenty upload intents per rolling day. PNG, WebP, progressive,
multi-scan and concatenated JPEGs are deliberately rejected in this first pipeline.

See [MEDIA_PIPELINE.md](MEDIA_PIPELINE.md) for contracts, resource measurements and
required actual-Edge/R2 tests. See [ACCOUNT_DELETION.md](ACCOUNT_DELETION.md) for the
explicit confirmation, recent-sign-in requirement, cleanup-before-Auth sequence,
retry semantics and reviewable retention choices. No cleanup schedule is enabled.

## Tests

From repository root:

```sh
supabase start
supabase test db
cd supabase/functions
npm ci --ignore-scripts
deno fmt --check
deno lint
deno check --node-modules-dir=manual media/index.ts contact/index.ts account-delete/index.ts lifecycle/index.ts media-read/index.ts
bash test.sh
```

Top-level dependencies use explicit versioned npm imports for dashboard bundling,
and npm package-lock pins the locally tested transitive graph. The no-import-prefix
lint exception is intentional for that deployment route. A dashboard remote import
must pin an immutable reviewed Git SHA, never a moving branch; without a lock there,
resolved transitive versions must be audited again before release. Use npm ci so that
manual npm resolution uses the reviewed transitive versions. Do not commit node_modules.

`tests/embedded_security.mjs` is an additional disposable real PostgreSQL 17.6
harness. Install `embedded-postgres@17.6.0-beta.15` outside the repository and set
`EMBEDDED_POSTGRES_MODULE` to its absolute dist/index.js. It creates only synthetic
users and local database roles, binds PostgreSQL to loopback, disables Unix sockets,
uses no external service and stops/deletes its database on completion. It uses a minimal
auth.uid stub; it does not emulate Supabase Auth, API gateway or PostgREST.

## Verification evidence

Run the current migration chain and suites on the exact release candidate. Past
foundation test counts do not certify this removal. The independent PostgreSQL
suite tests the final schema, preserved listing security and upgrade guardrails.
Deno tests include rejection of legacy upload targets. Actual API smoke exercises
listing pagination/search and removed endpoint rejection. These tests do not
replace hosted Supabase/R2 integration, load tests or a security release review.

## Mandatory remaining gates

The approved forward removal migration has been applied and verified on the
designated staging project. Verify approved service configuration, run
connected hosted API flows, verify deployed image/account-deletion flows and finalize retention,
complete moderation/report workflows, test expiry/search/Arabic on representative data,
exercise PostgREST JWT/RLS and expired/revoked sessions, test rate limits under load,
verify real device accessibility and publish a signed staging build. Until then this
is not production ready. Do not expose a service-role key to Flutter or commit secrets.

## Local starter reference data

`supabase/seed.sql` supplies nine common Arabic bird labels
and a deliberately small five-location subset: الخرطوم، أم درمان، بحري، كسلا،
بورتسودان. Local Supabase database initialization/reset loads it through `[db.seed]`.
It creates no fake users or user content and is idempotent by the reference tables'
unique names/location pairs. It does not overwrite existing labels or assume fixed IDs.

This is local development starter data, not a complete or officially validated
geography or species taxonomy. Review names, permitted bird categories, location
coverage, and complete the reference catalog before public
launch. The seed is not an automatic production migration; provision reviewed
reference data in staging/production as a separate explicit deployment step.

The Edge test wrapper grants only an explicit SDK runtime/config metadata env
allowlist, with no credential-variable, filesystem, network or sys access. AWS
presigning uses fixed synthetic credentials and a fixed user-agent provider. No
real service call occurs in those unit tests. Probe-only tests need no permissions.
