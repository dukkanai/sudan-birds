# GitHub iOS staging: inert implementation, not a delivered build

**Nothing in this package currently signs or uploads.** The example is outside
`.github/workflows`, `config.json` has `enabled: false`, identity/credential inputs
are unconfigured, and `beta.yml` / `release.yml` still fail closed. The only active
CI addition runs offline guard tests. No environment, signing secret, App ID, App
Store record, provisioning asset or TestFlight build was created by this work.
Do not merge PR #1 or change `main` to activate a staging experiment.

## Files and trust boundary

- `docs/examples/ios-staging/workflow.yml.example`: proposed `pull_request` workflow.
- `docs/examples/ios-staging/config.json`: nonsecret configuration, deliberately incomplete.
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

## Decisions and setup required before any activation

These are future actions, **not approvals or claims that setup is complete**.

1. Approve a distinct real staging bundle ID, app name/SKU, Apple App Store record
   and build version/number. Replace the temporary identifier in all Runner source
   configurations and review that commit. The adapter refuses the current temporary
   IDs and does not silently rewrite them during a build. Confirm the Apple team;
   NEXTAURA LLC / `9G7GPBG7FB` was previously identified but the config remains blank.
2. Approve the exact Apple credential batch and GitHub environment destination.
   Manually pre-provision an Apple Distribution certificate **with its private
   key** in a password-protected P12, and a matching App Store distribution profile
   for this exact bundle/team. Record the certificate fingerprint and profile UUID.
   A distribution certificate is a team signing credential, not an app-scoped key;
   the profile and checks constrain this workflow, not the certificate's inherent
   authority. No automatic provisioning or account-credential fallback is present.
3. Prefer an **individual API key belonging to a Developer user whose app access
   is restricted to this one staging app**. Verify the actual user's role, app
   selection and key ownership in App Store Connect. An Account Holder's individual
   key is not narrow merely because it is individual. Apple **team keys apply across
   apps and cannot be app-limited**. This adapter rejects a team-key configuration.
   A broader key requires a separately reviewed design and specific approval.
   `uploader_access_reviewed` records this required human review, not an API proof.
   At runtime an unfiltered Apple app listing must return exactly this app with no
   next page. That read does **not** independently prove the user's Developer role.
4. Approve the protected environment name and self-review decision. Configure its
   only required reviewer as the owner `dukkanai`, disable administrator bypass,
   and select custom branch policies with exactly **`refs/pull/1/merge`**, type
   branch. Do not use `build/foundation`, `main` or a wildcard for this PR workflow.
   If preventing self-review is enabled, the owner cannot approve a run they
   initiated; arrange a separately authorized initiator rather than weaken/bypass
   the gate. Unknown/missing `can_admins_bypass` or branch-policy fields block the
   runtime verifier. The built-in read-only API must actually expose these fields;
   a checked-in screenshot/boolean is not an automatic substitute.
5. After the credential/storage approval, populate only these environment secrets:
   `BIRDS_DISTRIBUTION_P12_BASE64`, `BIRDS_P12_PASSWORD`,
   `BIRDS_APP_PROFILE_BASE64`, `BIRDS_ASC_INDIVIDUAL_P8_BASE64`.
   Do not put values in source, shell history, public logs, artifacts or chat.
   The uploader key is materialized only after building and verifying the IPA.
6. Set the nonsecret staging publishable key as environment variable
   `BIRDS_STAGING_PUBLISHABLE_KEY`. Only the modern `sb_publishable_` form is
   accepted; service credentials are forbidden. Confirm the existing staging URL
   and `dev.sudanbirds.staging://auth/callback`, and acknowledge the current known
   limitations. Google/Apple OAuth remain disabled. A synthetic-only staging upload
   does not prove sign-in, hosted RLS/session behavior, R2 or real-device readiness.
   Keep upload/media gates closed. Do not invite external testers or imply release
   readiness. Disable automatic TestFlight group distribution until separately
   approved; this adapter neither adds testers nor submits for store/beta review.
7. Complete nonsecret macOS preparation and inspect the installed uploader's
   supported authentication before approving real credentials. The proposed tuple
   is **macos-15, Xcode 26.3 / 17C529, iOS SDK 26.2**, listed in GitHub's official
   runner inventory, **not tested by this work**. Runtime checks require the exact
   tuple and modern `altool --api-key-subject user` support. Xcode may download a
   newer altool. The installed tool's actual individual-key behavior must be
   confirmed; old uploader support is not assumed and there is no team-key fallback.
   Missing Xcode, profile incompatibility, CocoaPods/manual-signing incompatibility,
   unrecognized entitlements or unsupported IPA layout must stop the run.
8. Only after reviewing the complete activation, configure the manifest, explicitly
   enable it, and place the example at `.github/workflows/ios-staging.yml` on the
   development PR, **not by merging main**. Existing beta/release blockers remain.
   `pull_request` can run a workflow introduced on the PR when GitHub admits the
   PR event. A new `workflow_dispatch` is **not assumed available before the workflow
   exists on the default branch**. GitHub's own run-approval controls still apply.
9. After the final commit, approve its exact head in repository variable
   `BIRDS_APPROVED_HEAD_SHA`. Set repository variable `BIRDS_CI_RUNS_JSON` to an
   object mapping each of the three full workflow paths to positive `id` and
   `attempt` integers, after all eight jobs on that source succeed. Obtain fresh
   evidence; do not reuse historical run IDs for a newer head. Trigger a PR label,
   reopen or synchronization event as authorized. The preflight must succeed.
10. Before approving the pending protected-environment job, set environment variable
    `BIRDS_APPROVED_UPLOAD_RUN_ID` to that one workflow run's numeric ID. The owner
    reviews the exact source, build number, evidence and upload destination, then
    approves the job. A stale/unavailable variable blocks, rather than uploads.
    No new run or rerun is authorized merely because a prior upload timed out.

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
successful individual-key authentication or TestFlight delivery.

Local validation is Linux-only. The nonsecret CI probe does not establish real
environment API visibility, certificate/profile import, manual archive/export,
codesign checks, individual-key authentication or TestFlight processing/delivery.
Those credential-bearing stages remain unexecuted by this implementation work.
Keep activation blocked until those relevant setup/verification steps are actually
possible and approved. Do not replace an inaccessible verification with `true`.

## References

- [GitHub runner inventory: macOS 15](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md), consulted 2026-11-11 for the proposed toolchain tuple.
- [GitHub environments and PR ref rules](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments).
- [Environment REST reads](https://docs.github.com/en/rest/deployments/environments) and [branch-policy reads](https://docs.github.com/en/rest/deployments/branch-policies).
- [Apple API key types and app-access limits](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api/).
- [Apple individual-key JWT format](https://developer.apple.com/documentation/AppStoreConnectAPI/generating-tokens-for-api-requests).
- [Apple build uploads](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds).
- [Published Xcode altool man-page mirror](https://keith.github.io/xcode-man-pages/altool.1.html), contextual reference only; installed-tool checks and real compatibility verification remain required.
