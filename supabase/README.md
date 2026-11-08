# Backend foundation and release gates

This directory is a locally tested foundation, not a deployed Supabase application.
No credential is contained here. The separately provisioned staging R2 bucket is
private; bucket existence does not mean uploads or image verification work.

## Data/API contract

- Anonymous reads: visible profiles, listings, posts, replies and verified media metadata.
- Authenticated mutations use caller JWT + RLS; IDs, owners, ranking timestamps,
  expiry, moderation state and reply parent links cannot be changed by clients.
- Offers require finite nonnegative numeric `price`; requests allow an optional budget.
  Currency is an ISO-shaped three-letter code. Prices must be filtered by currency.
- Listing states: active, reserved (offers only), fulfilled, closed, expired. Display
  fulfilled as sold for an offer and found for a request. New expiry is 30 days.
- Feed clients must filter active + `expires_at > now()` by default, order by
  `(created_at DESC,id DESC)`, and use both values as cursor. Historical content remains readable.
- Post kinds: education, consultation. Replies have immutable post/parent identity.
- Reports target exactly one listing, post, reply or account. Only reporter and
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
- Blocks filter logged-in API reads, replies and contact access. Anonymous content
  remains public by product design; blocking is not a confidentiality boundary
  against somebody signing out or using a different account.
- Moderator/admin roles are provisioned only by trusted maintenance, never JWT
  user metadata. `moderate_content` supports audited hide/restore. Account bans,
  report-resolution tools and operator UI are not implemented.
- All public tables have RLS. Private quota events survive content deletion and
  impose serialized rolling daily budgets. Configure `private.publish_limits`
  through trusted maintenance only (50 posts, 50 listings, 200 replies, 20 reports).

## Edge boundaries

`contact` and `media` accept POST JSON only. They validate the user using Auth,
retain the caller's RLS context, bound JSON bodies to 8 KiB, return safe error codes
and never log request headers, JWTs, contact details, signed URLs or arbitrary errors.
The outer try/catch is an API boundary, not a replacement for validation or tests.
Database constraint errors intentionally abort their transaction; swallowing SQL
exceptions would weaken the security controls.

## R2 pipeline: explicitly incomplete, fail closed

The code includes short-lived signed PUT and GET adapters. The runtime configuration
`MEDIA_PIPELINE_ENABLED` defaults off. `media action=complete` always returns 503.
Nothing in this repository claims a client upload is a verified image.

Do NOT enable uploads until ALL of these exist and are tested:

1. A separately permissioned verifier retrieves the exact intent's quarantined object,
   enforces actual byte limits, decodes supported images in a resource-limited worker,
   bounds dimensions/pixels/frames, rejects malformed/polyglot and decompression-bomb
   inputs, strips EXIF/GPS by reencoding and writes a fresh immutable clean object.
2. Verification atomically marks a still-valid, owned intent verified and creates
   matching media metadata. A raw upload key must never be used as the published key.
   Signed PUT URLs may remain reusable until expiry, so verification must never publish
   the same mutable object. A HEAD request or magic-byte sniff is not verification.
3. Quarantine lifecycle expiry, orphan cleanup, account/content deletion cleanup,
   quota-event retention cleanup, revocation policy and bounded retries are deployed.
4. R2 public access remains disabled; credentials are bucket-scoped and staging-only.
   The uploader cannot choose a key, arbitrary bucket, or an unsigned public URL.
5. Real R2 end-to-end tests cover incorrect lengths/MIME, replay, overwrite races,
   expired URLs, blocked/hidden/deleted content and parallel completion requests.

Reservations are limited to 5 MiB, three pending/verified attachments per content
item and twenty intents per rolling day with a per-user transaction lock. Clients
cannot write upload intent state or media rows. Pending intents expire in five minutes;
PUT URLs expire in two minutes; read URLs expire in sixty seconds. A read URL already
issued is a bearer capability until it expires, even if a block is added immediately.
No public CDN or cache invalidation is configured.

## Tests

From repository root:

```sh
supabase start
supabase test db
cd supabase/functions
npm ci --ignore-scripts
deno fmt --check
deno lint
deno check --node-modules-dir=manual media/index.ts contact/index.ts
deno test --node-modules-dir=manual _shared/http_test.ts
```

Dependencies are pinned in both `deno.json` and npm package-lock. Use npm ci so that
manual npm resolution uses the reviewed transitive versions. Do not commit node_modules.

`tests/embedded_security.mjs` is an additional disposable real PostgreSQL 17.6
harness. Install `embedded-postgres@17.6.0-beta.15` outside the repository and set
`EMBEDDED_POSTGRES_MODULE` to its absolute dist/index.js. It creates only synthetic
users and local database roles, binds PostgreSQL to loopback, disables Unix sockets,
uses no external service and stops/deletes its database on completion. It uses a minimal
auth.uid stub; it does not emulate Supabase Auth, API gateway or PostgREST.

Actual verification performed locally:
- Migration applied to real PostgreSQL 17.6 and 48 database/security assertions passed,
  including deletion-resistant daily upload quotas and a six-concurrent-request test that allowed exactly three reservations.
- Deno 2.5.6 type checking, formatting and lint passed; five HTTP boundary tests passed.
- Final npm audit reported zero known vulnerabilities after updating AWS SDK to 3.1164.0.
- All **24 pgTAP assertions passed** against the disposable full Supabase stack in [CI run 42519691942](https://github.com/dukkanai/sudan-birds/actions/runs/42519691942), SHA `0b0cfd6e54880cf412f4a6864a880b71be80e3b8`. That aggregate run had a separate Flutter formatting failure, so it is not an all-checks approval.
- No deployed Supabase/R2 integration, provider login, email verification, account
  deletion, mobile integration, load test or penetration-test certification is claimed.

## Mandatory remaining gates

Provision/configure separate staging Supabase with approved secrets, run migrations
and connected hosted API flows, finish image verification, account deletion and retention,
complete moderation/report workflows, test expiry/search/Arabic on representative data,
exercise PostgREST JWT/RLS and expired/revoked sessions, test rate limits under load,
verify real device accessibility and publish a signed staging build. Until then this
is not production ready. Do not expose a service-role key to Flutter or commit secrets.

## Local starter reference data

`supabase/seed.sql` supplies nine common Arabic bird labels, six educational topics
and a deliberately small five-location subset: الخرطوم، أم درمان، بحري، كسلا،
بورتسودان. Local Supabase database initialization/reset loads it through `[db.seed]`.
It creates no fake users or user content and is idempotent by the reference tables'
unique names/location pairs. It does not overwrite existing labels or assume fixed IDs.

This is local development starter data, not a complete or officially validated
geography or species taxonomy. Review names, permitted bird categories, location
coverage and educational topics, and complete the reference catalog before public
launch. The seed is not an automatic production migration; provision reviewed
reference data in staging/production as a separate explicit deployment step.
