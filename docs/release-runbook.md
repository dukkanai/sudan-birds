# Release runbook: blocked by default

No workflow in this foundation publishes to an app store or deploys production. A successful CI run is not launch authorization.

1. Review the exact Git commit and all checks, including negative SQL/RLS scenarios, image abuse, quotas, blocked-user interactions and unauthenticated API attempts. Failed, missing or unexecuted required checks block approval.
2. Configure separate Supabase staging and production projects after checking current account limits and charges. Credential generation and persistent access expansion require explicit action-time approval. Never paste secrets in source, logs or chat.
3. Apply migrations to synthetic staging data. Test auth, every CRUD path, ownership changes, expiry, pagination ties, report privacy, role escalation, terms acceptance, quotas and account deletion through the actual API.
4. Complete R2 verification, EXIF stripping, orphan cleanup, retention, abuse limits and private image delivery. Test truncated files, MIME spoofing, excessive dimensions, parallel uploads, replay and expired permissions.
5. Test Arabic search and filters with representative synthetic text. Test interruption, duplicate tap, cancellation, network loss, stale sessions and app restart. Verify VoiceOver and TalkBack, focus order, screen zoom and large text on real iOS/Android devices.
6. Configure store identities, signing and protected environment permissions. Do not issue or upload store keys without required approval. Replace temporary app identifiers after reserving the real identifiers.
7. Produce a signed staging build and deliver it to the actual internal distribution channel. Unsigned iOS simulator builds are not TestFlight distribution.
8. Build and test the production-connected signed release candidate internally. Record SHA, version/build number, artifact digest, test evidence and approved migration plan. Promote the same verified artifact, not an untested rebuild.
9. Obtain explicit release approval. Configure manual deployment workflows only after security review and environment protections are verified. Publish without auto-merge or automatic main-branch deployment.
10. Observe health, define rollback compatible with current and previous app versions, and use forward-safe migrations. Restoring an old mobile binary does not undo a destructive schema migration.

The placeholder `beta.yml` and `release.yml` intentionally fail with these instructions. They cannot be used to imply a delivered signed build.

### Application Edge gateway compatibility

Use `supabase/config.toml` as the reviewed deployment target: `verify_jwt=false`
for `contact`, `media`, `media-read`, `account-delete` and `lifecycle`, while
`codec-diagnostic` remains `true` and undeployed. The owner approved disabling only
these five legacy-secret gateway checks for modern signing-key compatibility.
The approved staging change was applied after all seven checks passed for
`3c0cecf232ca3ed4c4df5ae7c905ef6e9a6e9d7f`: all five wrappers were repinned to
that immutable source before the five switches were saved off. All 29 direct
negative/public-read checks passed; see `verification.md`. Do not infer a valid
signed-in session or production readiness from that bounded result.

Protected requests must still pass `Auth.getUser`, caller-RLS authorization and any
endpoint-specific consent, role or recent-session checks before protected effects.
Malformed Auth success bodies must fail without a valid Auth-returned UUID identity.
Public image reads remain anonymous-RLS reads unless a user token is supplied; an
invalid user token must fail, never downgrade to anonymous. Keep upload enablement
off and do not create diagnostic/scheduler credentials or change RLS in this step.
The remaining hosted authentication gate must exercise real modern-token sign-in,
expiry/revocation and wrong-user/RLS cases on the exact source with approved test
identities or provider configuration.
Synthetic SDK transport regressions are not hosted cryptographic proof. Neither
this approval nor passing local tests authorizes a production release.

### Staging mobile OAuth callback (client implementation only)

The only supported mobile callback in this source is `dev.sudanbirds.staging://auth/callback`, configured with `AUTH_REDIRECT_URL`. Android registers that exact scheme, host and path; iOS registers the staging scheme. Dart rejects unrelated routes, fragments/implicit tokens, duplicate codes and arbitrary redirect configuration. Supabase Auth uses explicit PKCE. Flutter's competing default deep-link router is disabled so the `app_links`-based Supabase handler receives callbacks.

This does not configure Supabase's hosted redirect allowlist, Google/Apple providers or OAuth credentials. Those must be authorized and configured separately, then verified on real staging devices. Final store identities, production domain-linked redirects, ownership verification and signed-device tests remain release gates. The staging scheme must not be described as an approved production identity.
