# Verification record

Date: 2026-11-08. Environment: disposable Linux workspace, synthetic test data only. This record describes a development foundation, not a release approval.

## Executed checks

- Real PostgreSQL 17.6 migration, reference-seed idempotency and negative security harness: **48 assertions passed** after the final backend changes.
- Concurrency: six simultaneous attachment reservations allowed exactly three; ownership, privileged-column spoofing, price validation, report/contact privacy, blocks, reply identity, moderation audit and deletion-resistant quotas tested.
- Edge handlers: Deno 2.5.6 strict type checks, formatting, lint and five request-boundary tests executed.
- Dependency audit: initial AWS SDK dependency audit found a critical transitive advisory. Pins were updated to 3.1164.0 and the final npm audit returned zero known vulnerabilities. This is a point-in-time audit, not proof of absence of vulnerabilities.
- Gitleaks 8.21.2 local source scan: no leaks found. CI also scans Git history with redacted output.
- Repository policy and workflow YAML parsing checks executed.
- Flutter 3.38.5 / Dart 3.10.4: formatting passed, analysis reported no issues, and **12 tests passed** (domain, search escaping, HTTP-mocked repository pagination/error handling, and Arabic widget flows).

The local SQL harness creates minimal synthetic `auth.users` / `auth.uid()` equivalents. It tests real PostgreSQL grants, transactions and RLS, but is not the complete Supabase Auth/PostgREST runtime. A separate pgTAP suite runs against a disposable Supabase stack in CI. Do not confuse the two environments.

## Security review and regression work

Source review identified upload-quota reset via content deletion, report-queue deletion via cascading foreign keys, and incorrect search quoting. All three source findings were fixed and re-reviewed. Regression tests cover deletion-resistant quotas, report preservation and layered search escaping. CI must still confirm the final PR commit before approval. The review did not establish an RLS ownership bypass. Search parser integration still requires real PostgREST validation.

## Not yet verified / not delivered

- Hosted Supabase migration and connected end-to-end API/auth flow.
- Real Google/Apple sign-in and secure callback configuration.
- R2 image decoder/reencoder, EXIF removal, delivery, deletion and abuse scenarios. Image completion deliberately fails closed.
- Real-device VoiceOver/TalkBack, large-screen/font behavior across devices, network interruption and upload recovery.
- Signed Android/iOS beta delivery, store review or production release.
- Final privacy policy, support channel, full account-deletion lifecycle and moderator console.

Native compile workflows build an Android debug package and an unsigned iOS simulator app. Even if they pass, neither establishes real-device runtime behavior or TestFlight/Google Play delivery.

Do not deploy with real data until all release gates are fulfilled and explicitly approved. Failed, blocked or unexecuted required checks remain blockers, not waived successes.
