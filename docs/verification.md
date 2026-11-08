# Verification record

Date: 2026-11-08. Environments: disposable Linux workspace, GitHub CI, and the empty designated Supabase staging project. Synthetic fixtures only; no real user data. This record describes development verification, not release approval.

## Executed checks

- Real PostgreSQL 17.6 migration, reference-seed idempotency and negative security harness: **48 assertions passed** after the final backend changes.
- Concurrency: six simultaneous attachment reservations allowed exactly three; ownership, privileged-column spoofing, price validation, report/contact privacy, blocks, reply identity, moderation audit and deletion-resistant quotas tested.
- Foundation CI passed on exact SHA `d9952c74385a960b31d61686f94263ca9edd3cd8`: Flutter, database (**24 pgTAP assertions**), Edge checks, repository security, Android debug compile and unsigned iOS simulator compile. [Required checks](https://github.com/dukkanai/sudan-birds/actions/runs/42520396936), [native checks](https://github.com/dukkanai/sudan-birds/actions/runs/42520396938). Later commits require their own results.
- Edge handlers: Deno 2.5.6 strict type checks, formatting, lint and five request-boundary tests executed.
- Dependency audit: initial AWS SDK dependency audit found a critical transitive advisory. Pins were updated to 3.1164.0 and the final npm audit returned zero known vulnerabilities. This is a point-in-time audit, not proof of absence of vulnerabilities.
- Native compile success is not device testing or store distribution.
- Gitleaks 8.21.2 local source scan: no leaks found. CI also scans Git history with redacted output.
- Repository policy and workflow YAML parsing checks executed.
- Flutter 3.38.5 / Dart 3.10.4: formatting passed, analysis reported no issues, and **12 tests passed** (domain, search escaping, HTTP-mocked repository pagination/error handling, and Arabic widget flows).

The local SQL harness creates minimal synthetic `auth.users` / `auth.uid()` equivalents. It tests real PostgreSQL grants, transactions and RLS, but is not the complete Supabase Auth/PostgREST runtime. A separate pgTAP suite runs against a disposable Supabase stack in CI. Do not confuse the two environments.

## Security review and regression work

Source review identified upload-quota reset via content deletion, report-queue deletion via cascading foreign keys, and incorrect search quoting. All three source findings were fixed and re-reviewed. Regression tests cover deletion-resistant quotas, report preservation and layered search escaping. CI must still confirm the final PR commit before approval. The review did not establish an RLS ownership bypass. The real local PostgREST 16.5 regression script passed ten checks, including tied-timestamp pagination, combined search/cursor conditions, literal special-character search, and anonymous access denials. It used a temporary loopback adapter and PostgreSQL 17.6; the full Supabase gateway version runs separately in CI.

## Phase-two local verification

The expanded source in this revision passed the following checks with synthetic data before publication:

- Flutter: **40 tests**, exact formatting and analysis. Includes 320×568 Arabic screens at 200% text scaling, three-tab semantics, touch targets, duplicate submission and navigation-after-await, image metadata stripping, moderation contracts, deletion status, and native staging callback configuration.
- Backend: **93 real PostgreSQL assertions** and **39 Deno tests**, endpoint type checks, formatting, lint, npm audit and secret scan. Tests cover private data/role boundaries, signed create-only uploads, metadata sanitization, concurrent finalization, durable cleanup failures, live-session recent-authentication requirements and report-resolution auditing.
- Independent source review identified and repaired account-wide recent-auth checks, hidden permanent deletion failures, legacy-key precedence, unbounded upload-response draining and incomplete retention disclosures. The staging source review is conditional on keeping media disabled until hosted tests pass.
- Frozen migration SHA-256: `da37035a01eb5c8ca4bbe0ef9937a69581d28c331ca9b40d240b8aad5d119cbe`.

These are local source checks, not successful hosted media/deletion/OAuth flows. GitHub checks for this exact revision must pass separately. The preceding diagnostic-only commit `a2bad5f0b901d6cdf444a70e1115ccc5fc31be9e` passed all six jobs, including 24 pgTAP assertions and ten actual PostgREST API checks in the disposable full Supabase stack: [required checks](https://github.com/dukkanai/sudan-birds/actions/runs/42524075116), [native compilation](https://github.com/dukkanai/sudan-birds/actions/runs/42524075028).

## Hosted staging verification

- Applied only foundation migration `202611080001`, verified 14 public tables with RLS and 25 policies, and registered its exact 110 statements in migration history using the official CLI schema.
- Reference seed applied twice with stable totals: 9 bird types, 6 topics, 5 locations. No auth users created.
- Existing public publishable key used for read-only API checks: public taxonomy and empty feeds returned HTTP 200; contacts, reports, moderator roles and upload intents returned HTTP 401 to anonymous clients.
- No service credentials generated, no R2 object uploads, no production deployment.

## Temporary codec diagnostic

A fail-closed fixed-synthetic diagnostic is included for a separately approved staging resource test. Its committed entry is expired. It accepts no arbitrary images, database operations, R2 operations or user data. A fresh literal expiry and an explicitly approved temporary secret are both required. Local codec timing or process RSS is not proof of Supabase's per-isolate memory behavior; the image feature remains disabled until hosted resource and end-to-end tests pass.

## Not yet verified / not delivered

- Connected end-to-end authenticated API flow.
- Real Google/Apple sign-in and secure callback configuration.
- Actual R2 image delivery, conditional writes/fencing, deletion and abuse scenarios. Local decoder/EXIF tests pass, but the deployed media feature deliberately remains disabled.
- Real-device VoiceOver/TalkBack, large-screen/font behavior across devices, network interruption and upload recovery.
- Signed Android/iOS beta delivery, store review or production release.
- Final privacy/retention policy, support channel, and hosted account-deletion/moderator flows. The source includes deletion and moderation, but end-to-end hosted verification is pending.

Native compile workflows build an Android debug package and an unsigned iOS simulator app. Even if they pass, neither establishes real-device runtime behavior or TestFlight/Google Play delivery.

Do not deploy with real data until all release gates are fulfilled and explicitly approved. Failed, blocked or unexecuted required checks remain blockers, not waived successes.
