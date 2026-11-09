# Verification record

This is development evidence, not release approval. Tests use synthetic data and the owner's designated staging services. A check for an older commit does not validate later changes.

## Current two-tab revision, 2026-11-09

The requested scope is now requests and offers only. Application, backend, fixtures, active documentation and seed data are being updated together. The first two already-applied migrations remain immutable; a third forward migration removes the retired tables and rewrites shared listing security. It must fail if affected user data remains, and must preserve populated listings and their media, moderation and account-deletion safeguards.

Current local checks:

- PostgreSQL 17.6: 100/100 assertions passed, including a populated-listing upgrade, empty fresh install, rollback guards, listing ownership, blocking, quotas/concurrency, media races, reports and account deletion.
- Deno 2.5.6: 47 tests passed, plus formatting, lint and all six endpoint type checks. npm audit reported zero known vulnerabilities.
- Python: 10 harness tests, syntax compilation and repository policy checks passed.
- Final removal migration SHA-256: `577f7cbb6e39a6934f4c1f0a027d01fcbc134d858e2254f3433a2ef99b97d487`.

Flutter formatting passed. Local analysis/tests are awaiting a cold dependency restore; independent review and exact-commit CI remain in progress. Hosted removal has not been executed. Do not treat historical results below as a pass for this revision.

## Read-only hosted preflight, 2026-11-09

Direct SQL confirmed:

- Zero Auth users, listings, posts, replies and consultation-target media/upload intents.
- Zero consultation-target reports, moderation actions and publication events.
- Six seeded topic reference rows remain until the approved removal migration.
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

The previous resource run passed 20/20 sequential requests for one fixed synthetic 640×640 JPEG. It retained production R2 and Auth helper imports without calling their services. Official Edge Runtime v1.69.28 used 256MiB memory supervision and its local per-worker CPU policy. Codec time was 136–180ms. Maximum sampled post-processing heap-used plus external memory was 51.9MiB; this is not a continuous peak measurement. Warm workers handled up to seven requests before expected retirement.

The local CPU policy differs from hosted behavior. These results do not establish hosted capacity, real SDK network allocations, adversarial image safety or R2 integration. Media remains disabled.

The committed hosted diagnostic is expired and fail-closed. It accepts only its fixed synthetic fixture, never arbitrary images, database or R2 work. A separately approved temporary credential and literal short deadline are still required. It has not been deployed.

## Unverified or undelivered gates

- New revision's complete local and exact-commit CI checks, and guarded hosted schema cleanup.
- Connected authenticated API, Google/Apple sign-in, native callbacks and hosted moderation/deletion flows.
- Real R2 image delivery, conditional writes, retained deletion fences, cleanup and abuse scenarios.
- Real-device VoiceOver/TalkBack, weak-network interruption and upload recovery.
- Final privacy/retention terms, support operations, signed beta distribution and store review.

Native compilation does not establish runtime behavior or store delivery. Failed, blocked or unexecuted required checks remain blockers. No merge or production release is authorized by this record.
