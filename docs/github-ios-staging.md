# GitHub iOS staging: disabled-by-default TestFlight trial

The workflow definition is registered, but **no application signing or upload has
been executed**. The repository enable flag is absent/off by default; the checked-in
configuration retains `enabled: false` and `staging_limitations_acknowledged: false`.
The runtime requires explicit enabling plus a limitations acknowledgement bound to
the exact approved source head. These settings do not replace the existing protected
owner review, all eight exact-source CI checks or the single approved upload run ID.
Existing `beta.yml` / `release.yml` remain fail closed. Do not merge PR #1 or change
`main` for this trial.

The prepared identity is `com.nextaura.sudanbirds`, NEXTAURA team `9G7GPBG7FB`,
App Store Connect app `6833994816`, version `0.1.0`, build `1`. The owner approved
creation and protected GitHub storage of the Team Developer uploader and distribution
materials. The nonsecret configuration pins those existing assets; it neither creates
credentials nor proves they can sign/export/upload an app. Actual signing remains
unverified until the protected run completes.

This trial uses [existing email/password accounts](email-password-trial.md).
Google and Apple OAuth are disabled; photos remain disabled at the hosted gate.
No password is compiled into the app. A bounded hosted synthetic-account login check
has passed separately, not as proof of on-device login or this final build. The trial
is not a public release and must not use real customer content. No Android APK delivery,
external beta invitations, automatic group distribution or store submission is enabled.

## Files and trust boundary

- `.github/workflows/ios-staging.yml`: disabled-by-default, deliberate-label workflow.
- `docs/examples/ios-staging/workflow.yml.example`: matching reference definition.
- `docs/examples/ios-staging/config.json`: nonsecret approved-asset configuration; static runtime-consent flags remain false.
- `scripts/ios_staging_guard.py`: read-only, fail-closed GitHub evidence validation.
- `scripts/ios_staging_prepare.py`: nonsecret Flutter native preparation.
- `scripts/ios_staging_sign.py`: **unexecuted macOS adapter** for manual signing,
  private export, exported signature verification, and a single Apple upload.
- `scripts/ios_staging_guard_test.py`: synthetic offline regression coverage.

GitHub is the first choice. Codemagic is a fallback requiring its own reviewed
credential destination and protections, not an automatic alternative.

Only `dukkanai/sudan-birds`, PR **1**, `build/foundation` into `main` is allowed.
Forks, bot/Dependabot authors or actors, `pull_request_target`, dispatches, pushes,
and run attempts above 1 are rejected. Checkout uses the approved **head SHA**,
not a floating branch or an assumed merge SHA. All third-party actions are pinned.
The built-in token has only contents/actions/pull-requests read permissions.

The trusted source/dependency review and fresh GitHub-hosted macOS runner are
essential. Removing secrets from child-process environment variables is **not a
sandbox**: code running as the same user can inspect files, processes or the
keychain. A reviewed immutable PR workflow can itself be malicious if review is
inadequate. The owner must review the workflow, scripts, native build phases,
locked dependencies and changes at the exact approved head before releasing
credentials. Repository administrators can change configuration; this template
cannot cryptographically prevent that. Keep credentials **only in the protected
environment**, with no repository/organization-secret copies or signed caches.

## How exact-source CI is checked

There is no copied/stale second set of CI jobs. The gate reads three explicitly
selected run IDs **and attempts**, requires successful completed `pull_request`
runs for PR #1 and the approved head, and requires these eight jobs, all successful:

- `ci.yml`: flutter, database, edge, repository-security.
- `native-checks.yml`: android-debug, ios-simulator, ios-native-storage.
- `codec-resource.yml`: local-edge-probe.

For **each job**, it reads the actual checkout `git log -1 --format=%H` result,
inside the successful pinned checkout step's API timestamp interval. It fetches
the Git commit's complete tree and compares it with the approved head's complete
tree. A different synthetic merge commit is acceptable **only if the full trees
match**. A green badge, run `head_sha`, partial source manifest, artifact name,
or another job's checkout output is not sufficient. Missing/truncated/expired
logs, an unexpected log-storage redirect, unknown checkout timestamps, skipped
jobs or unavailable commit objects block signing. No failed upload is retried.

The configuration also pins SHA-256 digests of the three reviewed CI definitions.
When those workflows change, review the checks before updating their digests.
The gate rechecks the live PR and environment after reading CI evidence, and runs
again in the signing job. This cannot eliminate every concurrent administrator
change, nor replace real hosted OAuth, R2, device or release security gates.

## Exact activation procedure

1. Review the final source, locked dependencies, native build phases, signing scripts,
   trial account behavior and limitations. Verify the prepared certificate/profile and
   uploader are still the intended assets. Version/build `0.1.0 (1)` must not already
   exist in Apple; uncertain prior outcomes require reconciliation, never a blind retry.
2. Complete all eight jobs for the final head. Set repository variables
   `BIRDS_APPROVED_HEAD_SHA` and `BIRDS_CI_RUNS_JSON` to that exact source and the three
   run IDs/attempts. Every job's actual checkout tree must equal the approved full tree.
   Native and codec workflows also watch staging definitions so signing-only changes
   cannot inherit old test evidence.
3. After the owner reviews the limitations above, set
   `BIRDS_TRIAL_LIMITATIONS_HEAD_SHA` to that same head and
   `BIRDS_ENABLE_IOS_STAGING` to the exact string `true` as repository variables.
   These are nonsecret action gates, not substitutes for consent. Absent/false enable,
   absent/mismatched acknowledgement or a newer source fails closed. Static JSON is
   never rewritten to claim that review occurred.
4. Apply the deliberate `birds-testflight-trial` PR label. No synchronize, reopened,
   push, dispatch or arbitrary-label event can initiate this workflow. The workflow
   is read-only and does not create the label or change source. Remove/reapply only
   after reconciling any previous invocation; attempts above 1 are rejected.
5. Preflight verifies the existing `sudan-birds-ios-staging` environment: only reviewer
   `dukkanai`, administrator bypass disabled, `prevent_self_review: false`, and exactly
   `refs/pull/1/merge` branch policy. Never loosen protections to make the run work.
6. Before the owner approves the pending protected job, set environment variable
   `BIRDS_APPROVED_UPLOAD_RUN_ID` to that one numeric run ID. The owner reviews the
   exact source, evidence, app/version/build and limitations before releasing credentials.
   Environment variables may further restrict the enable/acknowledgement values, but
   no environment change or repository setting bypasses the owner approval gate.
7. Existing protected secrets only: `BIRDS_DISTRIBUTION_P12_BASE64`,
   `BIRDS_P12_PASSWORD`, `BIRDS_APP_PROFILE_BASE64`, `BIRDS_ASC_P8_BASE64`.
   Existing nonsecret environment variable `BIRDS_STAGING_PUBLISHABLE_KEY` must contain
   the project's modern publishable key. Never embed an account password, secret key,
   admin token or legacy service credential. No repository/organization secret copies.
8. Nonsecret preparation checks exact toolchain `macos-15`, Xcode `26.3 / 17C529`,
   iOS SDK `26.2`, locked Flutter `3.38.5`, source identity and installed modern altool
   support. Signing revalidates all evidence and one-run approval before writing secrets.
   Manual provisioning only; no credential, account, legacy CLI or provisioning fallback.
9. Reconcile Apple processing after an accepted upload. Turn the enable flag off after
   the invocation. A successful upload is not installed-device validation. No invitation,
   public release, store review, automatic retry or further build is implied.

The existing uploader is a Team Developer key with authority across NEXTAURA apps,
not an app-scoped key. That authority was disclosed and approved separately. Runtime
Apple reads, exported bundle identity and upload arguments constrain this workflow to
this app, not the key's inherent authority. The distribution key is likewise a team
credential; the profile and signature checks constrain this workflow only.

## Private signing and outcome handling

A new mode-0700 temporary directory holds files and private tool output. The
adapter imports only the approved P12 into a new temporary keychain, preserves
and restores the prior keychain search list, and creates only an absent named
profile. It never alters the default keychain or overwrites an existing profile.
It archives and exports manually, without `-allowProvisioningUpdates`, selecting
an internal-TestFlight-only App Store Connect export.

Before upload it checks the exported app's bundle/version/toolchain, verifies its
signature using `codesign --verify --deep --strict`, checks exact app/team/keychain
entitlements and the absence of unreviewed capabilities, validates the embedded
profile, and matches the exported signing certificate fingerprint. Unsafe archive
paths and symlinks are rejected. These checks are implemented, **not yet exercised
against a real signed build**. Code-signature validity is not app security proof.

The IPA goes only to Apple's uploader. No signed artifact, key, P12, profile,
archive, raw log or uploader response is uploaded to GitHub. The public result
contains only the source SHA, IPA digest, fixed outcome states and cleanup status.
Every subprocess return, failure or interruption checks the entire owned process
group, sends TERM, then KILL if any members remain after a bounded grace period.
Leader exit alone is not termination proof. Group shutdown is bounded; an
unconfirmed group is reported as a cleanup failure without replacing the primary
failure. SIGTERM/SIGINT are ignored while termination and cleanup finish. A process
that deliberately escapes into another session is outside this process-group
control; the reviewed-source/ephemeral-runner trust boundary still applies. Hard runner loss or
SIGKILL cannot guarantee cleanup; use only ephemeral GitHub-hosted runners and
revoke credentials if isolation is uncertain. Deletion is not secure erasure.

Any interrupted/nonzero upload is **outcome uncertain**, even when it looks like
an authentication/network error. Inspect App Store Connect for the exact app,
version/build and delivery before deciding what to do next. A zero exit is recorded
as upload accepted with processing unverified until a read observes `VALID`.
That still does not prove testers received or installed it. No automatic retry,
external distribution, production promotion or main merge exists here.

## First protected invocation (2026-11-12)

Run [43284533641](https://github.com/dukkanai/sudan-birds/actions/runs/43284533641)
used source `f2afc1f`, after all eight exact-source checks and explicit owner
approval. Its live preflight passed. The signing adapter stopped at the uploader
capability check, before writing credential files, importing a keychain, creating
an IPA or calling Apple. Its sanitized result was `not_uploaded`,
`cleanup_complete: true`, with no IPA digest. This is not an uncertain upload or
an Apple authentication rejection. No upload retry was attempted.

The CI probe combined the help command's stdout/stderr, but the original signing
adapter inspected stdout alone. That code-path difference is verified; the exact
suppressed help output from the failed runner was not retained, so a stderr-only
response is a supported explanation rather than a directly observed fact. The
adapter now reuses the same fixed, bounded, credential-free query as the CI probe.
Exact required options, source/run/environment checks, and all signing/upload
boundaries remain unchanged. Raw signing diagnostics still stay private. New
source requires fresh checks and its own protected invocation; old green checks
are not evidence for the correction.

## Certificate import stop (2026-11-12)

The corrected source `175241b` passed all eight exact-source checks and protected
preflight. Run [43296727830](https://github.com/dukkanai/sudan-birds/actions/runs/43296727830)
passed the uploader capability check, then stopped at `certificate-import`.
The fixed outcome again reported `not_uploaded`, `cleanup_complete: true`, and
no IPA digest. The enable flag was subsequently verified false. The underlying
P12/import cause was not captured; neither a bad password nor an incompatible
algorithm is established, and no certificate was replaced.

A bounded diagnostic classifier now maps only known import-error phrases to
fixed labels. It never prints or persists the original stderr, credentials or
paths, and it never changes import behavior or retries. Unknown, ambiguous,
malformed, unreadable or oversized diagnostics remain `unclassified`. A MAC
verification label alone must not be described as proof of an incorrect password.
This diagnostic change needs its own exact-source checks before another protected
invocation. No algorithm downgrade, secret replacement or credential fallback is
part of it.

## Bounded import diagnosis (2026-11-13)

Source `7177d6f` passed all eight exact-source CI checks. Protected upload run
[43371573079](https://github.com/dukkanai/sudan-birds/actions/runs/43371573079)
passed preflight and its 103 guard tests, then stopped at certificate import with
the fixed category `pkcs12_mac_verification_failed`. It reported `not_uploaded`,
no IPA digest and complete cleanup. The enable flag was verified false afterward.
Neither a wrong password nor an incompatible P12 algorithm is established by
that category. No certificate or secret was replaced.

The next diagnostic is failure-only: after that exact import category, one
30-second `/usr/bin/openssl pkcs12 -info -noout -passin stdin` read uses the same
owned P12 and existing password. The password never enters this diagnostic's
command arguments or child environment. Unsupported password framing is not
trimmed, normalized or retried. Raw output remains private; only a fixed reader
outcome and strictly allowlisted MAC-presence status can be reported.

`read_check_passed_mac_present` means this reader accepted a container whose
metadata declared a MAC. An absent/unknown MAC does not establish password
validity: a synthetic MAC-less P12 can pass `-noout` even with a wrong password.
Reader differences do not by themselves prove why Apple's importer rejected
the file. Unknown, conflicting, malformed or oversized diagnostic metadata is
not promoted to positive MAC evidence. The metadata read is bounded to 4096
bytes, but the existing private subprocess capture files are not a strict
output-volume limit.

Every diagnostic outcome preserves the original import failure and prevents
signing/upload. Even a broken diagnostic output stream must not replace it.
No key extraction, container conversion, algorithm downgrade, password change,
credential fallback or upload retry is added. This source needs fresh CI and a
protected invocation before any actual macOS diagnostic result can be claimed.

## Local validation and remaining blockers

From repository root:

```sh
python3 -m unittest discover -s scripts -p 'ios_staging*_test.py' -v
python3 -m py_compile scripts/ios_staging_guard.py scripts/ios_staging_sign.py scripts/ios_staging_prepare.py
python3 scripts/check_repository.py
go run github.com/rhysd/actionlint/cmd/actionlint@v1.7.7 -shellcheck= -pyflakes= docs/examples/ios-staging/workflow.yml.example
```

The tests use only synthetic JSON/logs, temporary files and an ephemeral synthetic
P-256 key to verify JWT encoding with OpenSSL. They make no live account requests,
produce no signed application, and prove no runtime platform protection.

The existing `ios-simulator` CI job additionally runs
`scripts/ios_toolchain_probe.py` after its functional build and evidence steps.
This separate, nonsecret preparation probe only queries Xcode/SDK versions and
uploader help. It does not sign, authenticate to Apple, or upload anything. A
missing toolchain or uploader option fails the job as a signing-preparation
blocker, without reclassifying the earlier functional steps. Its fixed JSON
report is capability evidence only; an accepted help flag does not establish
successful authentication of either key type or TestFlight delivery. The probe
requires both modern authentication flag sets, including `--api-key` and
`--api-issuer`, while still executing only the same three fixed help/version queries.

Local validation is Linux-only. The nonsecret CI probe does not establish real
environment API visibility, certificate/profile import, manual archive/export,
codesign checks, individual/team-key authentication or TestFlight processing/delivery.
The dated run records above establish only the stages actually reached; archive,
export, Apple upload, processing and tester delivery remain unverified.
Keep activation blocked until those relevant setup/verification steps are actually
possible and approved. Do not replace an inaccessible verification with `true`.

## References

- [GitHub runner inventory: macOS 15](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md), consulted 2026-11-11 for the proposed toolchain tuple.
- [GitHub environments and PR ref rules](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments).
- [Environment REST reads](https://docs.github.com/en/rest/deployments/environments) and [branch-policy reads](https://docs.github.com/en/rest/deployments/branch-policies).
- [Apple API key types and app-access limits](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api/).
- [Apple JWT formats](https://developer.apple.com/documentation/AppStoreConnectAPI/generating-tokens-for-api-requests).
- [Apple build uploads](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds).
- [Apple online altool guide](https://help.apple.com/asc/appsaltool/en.lproj/static.html), consulted 2026-11-12; documents legacy argument spellings.
- [Published Xcode altool man-page mirror](https://keith.github.io/xcode-man-pages/altool.1.html), contextual reference only; installed-tool checks and real compatibility verification remain required.
