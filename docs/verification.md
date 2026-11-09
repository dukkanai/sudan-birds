# Verification record

This is development evidence, not release approval. Tests use synthetic data and the owner's designated staging services. A check for an older commit does not validate later changes.

## Follow-up endpoint and API hardening, 2026-11-09

Five application entrypoints now register testable handlers. Strict field/action checks, complete storage configuration before reservations, validation before privileged client construction, returned deletion-job ownership checks and bounded JSON stream failures are covered by 84 passing local Deno tests. The 37 new endpoint tests use the actual Supabase SDK and authentication/RPC adapters with a synthetic transport; no network or real credentials are involved. An independent rerun passed all 84 tests. Formatting, lint and all six entrypoint type checks also passed.

The disposable-loopback PostgREST harness now exercises synthetic caller JWTs for CRUD ownership, terms gating, price constraints, bilateral blocks, contact consent, private reports, moderator operations, search/pagination and invalid/expired tokens. Its 31 offline boundary tests passed, including an independent rerun. At this pre-CI checkpoint, the 173 planned live assertions have only been statically counted, not executed. The live suite is configured to run against the full disposable Supabase stack in CI; it is not a GoTrue sign-in, refresh, revocation or hosted integration test. Check the exact commit's [GitHub Actions results](https://github.com/dukkanai/sudan-birds/actions) before relying on live-suite success. The unchanged schema separately passed 100 PostgreSQL assertions again.

No hosted function, diagnostic credential, storage key or production deployment is implied by these local changes. Media remains disabled. Historical baseline counts below apply only to their named commits.

## Two-tab implementation baseline, 2026-11-09

The requested scope is now requests and offers only. Application, backend, fixtures, active documentation and seed data were updated together. The first two already-applied migrations remain immutable; a third forward migration removes the retired tables and rewrites shared listing security. It fails if affected user data remains, and preserves populated listings and their media, moderation and account-deletion safeguards.

Current local checks:

- PostgreSQL 17.6: 100/100 assertions passed, including a populated-listing upgrade, empty fresh install, rollback guards, listing ownership, blocking, quotas/concurrency, media races, reports and account deletion.
- Deno 2.5.6: 47 tests passed, plus formatting, lint and all six endpoint type checks. npm audit reported zero known vulnerabilities.
- Python: 10 harness tests, syntax compilation and repository policy checks passed.
- Final removal migration SHA-256: `577f7cbb6e39a6934f4c1f0a027d01fcbc134d858e2254f3433a2ef99b97d487`.

Flutter 3.38.5 formatting, analysis and 44 tests passed locally. Independent source review found no blocking regression or remaining active consultation feature. All seven CI jobs passed for implementation commit `4acb569fa63173e09b1255b0ff2f93498f7570d9`: Flutter, Deno, repository security, database, Android debug, unsigned iOS simulator and the bounded local codec experiment. The disposable full Supabase run passed 58 pgTAP assertions and 14 actual PostgREST checks. The repository job included the full-history secret scan. These results identify the implementation commit; later documentation commits require their own CI status.

[Required checks](https://github.com/dukkanai/sudan-birds/actions/runs/42559659049), [native compilation](https://github.com/dukkanai/sudan-birds/actions/runs/42559658882), [local resource experiment](https://github.com/dukkanai/sudan-birds/actions/runs/42559659098).

## Hosted removal verified, 2026-11-09

The owner explicitly approved permanent removal in project `tkfhcjdxovivsrmoxpjm`, including its Supabase default `main PRODUCTION` branch label. This project is designated for staging; the label does not imply a released application. A fresh preflight again found zero affected user content and exactly six known development topic rows. No function deployment had occurred.

Migration `202611090002_remove_timeline.sql`, SHA-256 `577f7cbb6e39a6934f4c1f0a027d01fcbc134d858e2254f3433a2ef99b97d487`, was executed once as an atomic batch. The batch locked migration history, required the exact two preceding versions, ran the guarded migration, registered its exact 42 source statements and committed together. No history was overwritten. A separate local synthetic test had verified exact registration and rejection of repeat execution before mutation.

All 23 read-only hosted SQL assertions passed: the three retired tables, reply helper, legacy columns, old upload overload and quota settings are absent; media and upload intents require listings; all 11 remaining public tables retain RLS; client/service RPC grants and private registry restrictions are preserved. History contains the three exact versions and the 42 stored statements match the committed source. Auth users, listings and object registry remain empty. Nine bird types and five locations remain unchanged.

All 12 hosted GET-only API checks passed: reference data and empty listing/media reads returned 200, the three retired table endpoints and old upload overload returned 404, and four private table endpoints returned 401. No accounts, fixture rows, secrets, uploads or writes were introduced by these API checks. These checks establish schema/API boundaries, not authenticated application or real R2 behavior.

## Read-only hosted preflight, 2026-11-09

Direct SQL confirmed:

- Zero Auth users, listings, posts, replies and consultation-target media/upload intents.
- Zero consultation-target reports, moderation actions and publication events.
- Six seeded topic reference rows remained at preflight and were subsequently removed by the approved migration above.
- Migration history contains exactly `202611080001` and `202611090001`.
- The Edge function list is empty. No previous function deployment was submitted before the scope change.

No data, security settings, credentials or functions were changed by this preflight.

## Previous exact-commit baseline, 2026-11-08

Commit `d8340621792ac3d2a1e33577aa71231925faee07`, before the two-tab change, passed all seven CI jobs:

- Flutter 3.38.5: formatting, static analysis and 40 tests, including Arabic 320×568 screens at 200% text scale, touch targets, duplicate submission, navigation after asynchronous operations, image metadata stripping and native staging callback configuration.
- Disposable full Supabase stack: 49 pgTAP assertions and 10 actual PostgREST checks.
- Deno 2.5.6: formatting, lint, six endpoint type checks, 43 tests and npm dependency audit.
- Repository policy and full-history redacted secret scan.
- Android debug and unsigned iOS simulator compilation.
- Local bounded codec resource experiment and 10 harness tests.

[Required checks](https://github.com/dukkanai/sudan-birds/actions/runs/42530133576), [native compilation](https://github.com/dukkanai/sudan-birds/actions/runs/42530133723), [local resource experiment](https://github.com/dukkanai/sudan-birds/actions/runs/42530133708).

A separate PostgreSQL 17.6 harness passed 93 security assertions. It uses minimal synthetic Auth/session equivalents and real PostgreSQL transactions, grants and RLS. It is not the complete Supabase Auth/PostgREST runtime.

Earlier review repaired deletion-resistant upload quotas, report retention, search quoting, session-bound recent authentication, durable cleanup-error visibility, API-key precedence, upload-response timeouts and retention disclosures. Those safeguards must remain covered after the scope change.

## Hosted baseline established before the scope change

Both migrations were applied atomically and registered with their exact source statements. The second migration has SHA-256 `da37035a01eb5c8ca4bbe0ef9937a69581d28c331ca9b40d240b8aad5d119cbe`. All 14 pre-removal public tables had RLS. Private registries and ten service-only RPCs denied client access. Thirteen live anonymous API checks passed without creating or modifying rows. No moderator roles, scheduled cleanup, service credentials or R2 uploads were created.

## Local codec limits and temporary diagnostic

The current implementation's resource run passed 20/20 sequential requests for one fixed synthetic 640×640 JPEG. It retained production R2 and Auth helper imports without calling their services. Official Edge Runtime v1.69.28 used 256MiB memory supervision and its local per-worker CPU policy. Codec time was 225–275ms. Maximum sampled post-processing heap-used plus external memory was 51.43MiB; this is not a continuous peak measurement. Warm workers handled up to four requests before expected retirement.

The local CPU policy differs from hosted behavior. These results do not establish hosted capacity, real SDK network allocations, adversarial image safety or R2 integration. Media remains disabled.

The committed hosted diagnostic is expired and fail-closed. It accepts only its fixed synthetic fixture, never arbitrary images, database or R2 work. A separately approved temporary credential and literal short deadline are still required. It has not been deployed.

## Unverified or undelivered gates

- Deployment of the listing-only Edge functions and their hosted authenticated integration tests.
- Connected authenticated API, Google/Apple sign-in, native callbacks and hosted moderation/deletion flows.
- Real R2 image delivery, conditional writes, retained deletion fences, cleanup and abuse scenarios.
- Real-device VoiceOver/TalkBack, weak-network interruption and upload recovery.
- Final privacy/retention terms, support operations, signed beta distribution and store review.

Native compilation does not establish runtime behavior or store delivery. Failed, blocked or unexecuted required checks remain blockers. No merge or production release is authorized by this record.
