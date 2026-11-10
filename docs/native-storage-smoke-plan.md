# Native storage runtime smoke: preparation, not execution evidence

Initial source base: `40ad627c2f508dd7cd1771d0b49dece173dc9efd`.
Integrated for review on `1238acd753fb77d48ceaa75b8d4379995c35de44`.
The source is `app/integration_test/native_storage_test.dart`. Production Dart,
Kotlin, Swift, storage options and entitlements are unchanged. The test does not
start application `main`, configure Supabase, or initialize provider/HTTP flows.

## Assertions

- Production `NativeCredentialStore` performs write/read/delete on native plugins.
  A new adapter sees the written value; a second fixed namespace remains empty.
- Production `NativeAuthRestoreFence` reads a never-written scope as blocked,
  writes allow/block, and a new adapter sees the result. A malformed method-channel
  write is rejected and cannot change a previously blocked fence.
- `SecureAuthStorage` clears stale synthetic session/verifier keys when the fence
  is missing. Allowed synthetic session storage survives fresh **object** creation;
  startup clears orphan PKCE. Persisting the logout block before deletion prevents
  a fresh owner from restoring a deliberately retained synthetic session.
- Cleanup blocks restore for the two written test fence scopes, deletes only the
  exact session/PKCE keys in three fixed `.invalid` namespaces and verifies absence.
  All cleanup operations are guarded and each is attempted after prior failure.
  Cleanup never calls delete-all and never writes the never-written fence scope.
  Nonsecret blocked markers intentionally remain until the disposable app is removed.
- Values are non-login strings, not JWTs or real PKCE verifiers. Tests compare
  booleans and suppress arbitrary native exception detail instead of printing
  stored values. A cleanup failure is a failure, not a success-with-warning.

## Current checks and blockers (2026-11-10)

No native runtime test has run. Initial local preparation made no hosted app
request, deployment, real account/credential, signing or permission change.
The subsequently published CI attempt and its failure are recorded below.
The editing environment has no Android SDK, adb, Xcode or native device.
Official Flutter 3.38.5 (Dart 3.10.4) was restored into a private toolchain after
checking the official release manifest and archive SHA-256:
`a264940cfc431c1778f34f7413fa6ab71443ad52c71f38c50b0284397a4039b0`.
An earlier dependency attempt was cancelled before decision; this resumed,
user-authorized attempt succeeded using the official SDK and pub.dev.

Verified on this private source:

- `flutter pub get` succeeded. All 119 existing lock entries are unchanged.
  Exactly six additions: SDK `integration_test`, `flutter_driver`,
  `fuchsia_remote_debug_protocol`; hosted `process` 5.0.6, `sync_http` 0.3.1,
  `webdriver` 3.2.0. No existing versions or checksums drifted.
- `flutter pub get --offline --enforce-lockfile` succeeded.
- `dart format --output=none --set-exit-if-changed lib test integration_test`
  passed: 35 files, zero changes.
- `flutter analyze --no-pub` passed with no issues, including integration source.
- `flutter test --no-pub --reporter expanded` passed all 139 existing tests.
  This command does not execute the integration test.
- `python3 scripts/check_repository.py` passed.
- All tracked production app files byte-match candidate
  `1238acd753fb77d48ceaa75b8d4379995c35de44`, except the intended pubspec and lock
  changes. Native platform sources, security options and entitlements are unchanged.

Compile attempt:
`flutter build bundle --debug --no-pub --target integration_test/native_storage_test.dart --target-platform android-arm64 --dart-define=NATIVE_STORAGE_SMOKE=true`
failed with `Android SDK could not be found` in the native-assets build target.
This is a blocked build, **not compilation or native-execution success**. No SDK
installation, alternative device or mocked integration run was attempted.

An independent offline review previously found no blocking source defect within
its storage-scope review. Android ownership recommendations below remain
unexecuted documentation, not a tested cleanup script. Source analysis and unit
tests do not clear native security or release gates.

## Parent integration sequence (not executed)

1. Integrate only the source, pubspec, reviewed lockfile and plan into the candidate.
   Do not overwrite unrelated evidence changes made since the original base.
2. On the final candidate use official Flutter **3.38.5**, an isolated writable
   HOME/PUB_CACHE/XDG configuration and `CI=true BOT=true FLUTTER_SUPPRESS_ANALYTICS=true`.
   CI must use `flutter pub get --enforce-lockfile`, never resolve an uncommitted lock.
3. Repeat format, analysis, existing tests and native builds on that final source.
4. Extend existing read-only native jobs only after coordination with the native
   dependency-evidence owner. The new isolated iOS job is described below; existing provenance jobs stay unchanged.
   Use a fresh disposable runner/app sandbox, never a personal device or a runner
   containing real sessions. Set `NATIVE_STORAGE_SMOKE=true` only for a disposable
   emulator/simulator. Never run `flutter test integration_test` without an exact
   native device ID: desktop/mocked execution is not native evidence.

### Android job recommendation

Retain the existing Ubuntu 24.04 job, Flutter pin, Gradle init policy and job
permissions. After the debug compile succeeds, inventory official installed
runtimes with `$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager --list_installed`
and `$ANDROID_HOME/emulator/emulator -list-avds`. An installed system image and
usable virtualization are prerequisites, not assumed properties of the runner.
Select one exact installed Google Android x86_64 image (API >= app minimum) and
record its exact package as `IMAGE`. Do not accept licenses, change host device
permissions, install unpinned third-party emulator actions, or silently download
images as part of this narrow recommendation. If unavailable, report the
prerequisite as blocked and obtain a separately reviewed setup plan.

Before turning this recommendation into CI, implement all of these ownership
checks and finite deadlines. A fresh runner alone is not proof of AVD ownership:
all inspection commands and each ownership/absence check must finish within
10 seconds; create/delete/boot/test have the explicit limits below. Enforce a
further ten-second termination grace before forcibly ending a hung helper. No
unbounded polling or wait is permitted.

1. Allocate a new private invocation directory under `RUNNER_TEMP` and a new,
   empty `ANDROID_AVD_HOME` inside it. Do not reuse an existing directory. Generate
   a filesystem-safe `AVD_NAME` such as `birds-storage-smoke-<random-UUID>` for this
   invocation, and verify that neither that AVD name nor its metadata already
   exists. Create with `avdmanager create avd --name "$AVD_NAME" --package "$IMAGE"`
   under a 60-second deadline. **Do not use `--force`.** Set a `created` ownership
   flag only after successful exit and verification that the exact AVD's name,
   image and canonical metadata/data paths match this invocation's new private
   directory. Refuse symlinks or paths escaping that directory. A failed or
   timed-out create is not permission to retry, adopt or delete an uncertain AVD.
2. Select one valid even emulator console `PORT` and derive
   `SERIAL="emulator-$PORT"`. Within a 10-second preflight, verify that the serial
   is absent from `adb devices -l` and that both `PORT` and the adjacent ADB port
   are unoccupied on local interfaces. An occupied port/serial or an inconclusive
   check is a failure; never kill another process/device to free it. Recheck
   immediately before launch. These checks do not eliminate a launch race, so
   the exact post-launch identity check below is mandatory.
3. Launch only the successfully created AVD with
   `emulator -avd "$AVD_NAME" -port "$PORT" -no-window -no-audio -no-snapshot -wipe-data`
   in the same private `ANDROID_AVD_HOME`. Record the launched process identity
   (PID and start identity, not a reusable PID alone) and launch outcome in
   invocation-private state. Keep any emulator output private and temporary.
   Allow at most 120 seconds for boot, with every individual ADB query bounded to
   10 seconds. Require the original launched process to remain identifiable,
   `adb -s "$SERIAL" emu avd name` to return exactly `AVD_NAME` with a successful
   response, and `sys.boot_completed` to equal `1`. Reject extra/unexpected output,
   missing or mismatched identities, and timeouts. Do not fall back to another
   device. Repeat the identity check immediately before the test.

Only after those checks pass, run from `app/` with the verified serial:

```sh
timeout --signal=TERM --kill-after=10s 600s flutter test \
  integration_test/native_storage_test.dart -d "$SERIAL" \
  --dart-define=NATIVE_STORAGE_SMOKE=true --reporter expanded
```

Use always-run cleanup, but only for resources recorded as successfully created
by this invocation. If launch was never attempted, the verified new, unlaunched
AVD may be deleted after the metadata checks below, without querying or stopping
an occupied device. If launch was attempted but its outcome is uncertain, do not
assume the AVD is stopped or eligible for deletion. Before any kill, revalidate
the creation record, original process identity, private metadata paths and exact
`emu avd name` response. Then
allow at most 10 seconds for `adb -s "$SERIAL" emu kill` and 30 seconds to verify
that the owned process is gone, the serial is absent and both selected ports are
free. If it already exited, skip the kill and verify the same absence conditions.
Before deletion, revalidate the exact name/image/private metadata ownership and
confirmed stopped state; only then run `avdmanager delete avd --name "$AVD_NAME"`
in the same private `ANDROID_AVD_HOME` under a 30-second deadline and verify
absence. Never delete by a guessed name, global AVD listing, port or broad glob.

If ownership, process state, creation or cleanup outcome is uncertain, fail the
job and report that uncertainty. Do not guess, retry destructive commands, adopt
an existing resource, or claim cleanup succeeded; leave final containment to
the disposable runner's teardown. Retain the job timeout as an outer bound and
fail on boot/test/cleanup failures. Remove only invocation-owned temporary output
after its process has stopped. Never retain or upload credentials, emulator app
data, snapshots, preferences, secure storage, logcat dumps, unfiltered native
logs or private ownership metadata as artifacts.

### Implemented isolated iOS CI job (not yet executed natively)

`ios-native-storage` in `native-checks.yml` uses `macos-15`, existing pinned
checkout/Flutter actions, Flutter 3.38.5 and contents-read-only permission.
It runs independently of `ios-simulator`; no integration target can overwrite
that job's dependency/provenance artifacts. It uploads no artifacts or app data.

`scripts/ios_native_storage.py` inventories installed `simctl list --json` only.
It requires an available iOS runtime >= 13 and iPhone type whose explicit encoded
min/max runtime bounds include that exact runtime. Missing/unknown compatibility
is a failure, not a download or physical-device fallback. The helper creates a
unique `birds-storage-<UUID>` name and records the exact new simulator UUID,
name, runtime and device type in an invocation-private directory. Existing names
or UUIDs cannot be adopted. Uncertain creation is reported and never guessed away.

The first pre-creation inventory has a 60-second cold-start bound with no retry;
all subsequent inventory commands, including cleanup inventories, retain
ten-second bounds; create 60 seconds; boot 30 seconds;
bootstatus 180 seconds; test 600 seconds. Failed, interrupted or timed-out subprocess groups receive TERM with a
ten-second leader wait, then KILL for surviving group descendants with another
ten-second leader wait. Group IDs come only from the invocation-owned
`Popen(start_new_session=True)`, never process discovery or saved/adopted PIDs.
Successful commands do not trigger group termination: launchd/CoreSimulator
services are not ours to stop.
The exact owned, available and booted identity is verified immediately before:

```sh
flutter --no-version-check test --no-pub integration_test/native_storage_test.dart \
  -d '<owned-UUID>' --dart-define=NATIVE_STORAGE_SMOKE=true --reporter expanded
```

An always-run three-minute cleanup step revalidates ownership, shuts down only a
verified booted owned simulator (30 seconds), verifies Shutdown before deletion
(30 seconds), and confirms absence. Missing/ambiguous ownership or transitional
state fails rather than deleting an uncertain resource. No global cleanup,
snapshot, app-data export, signing, entitlement, permission, license acceptance
or runtime install is performed. If the runner is forcibly lost before cleanup,
cleanup cannot be guaranteed; containment then relies on the disposable runner.

All simulator/Flutter subprocess output is discarded into temporary files and
never uploaded or echoed. Only fixed success/failure labels, allowlisted command stages and bounded numeric
exit codes (or `unknown`) are emitted, so no
Keychain values or arbitrary native diagnostics enter CI logs. This intentionally
limits diagnosis: a native failure requires a separately reviewed diagnostic
plan, not silently enabling raw logs. Offline orchestration tests mock native
operations and do not constitute simulator execution evidence.

Existing source/physical-device/restore/backup gates remain mandatory. No iOS
runtime result is claimed until the exact candidate job actually passes.

The initial CI attempt on `85fbeda1410336fa80e2c1019d21da42f97965b7`
(job `129701107128`) failed at the first inventory's previous ten-second limit.
It reported `stage=inventory reason=interrupted exit=unknown`; cleanup confirmed
that no owned simulator was created. No storage/runtime test executed. The
revised first-only 60-second limit addresses that bounded cold-start failure,
without claiming a successful rerun. Command timeouts now report `reason=timeout`
distinctly from `reason=interrupted`, with identical owned-group cleanup and no
raw diagnostic output.

### Evidence and limits

Record final checked-out commit, source/lock hashes, exact SDK/device/runtime
versions, execution command, CI run URL and assertion outcome. Do not treat an
older compile/dependency run as evidence for this new test. Raw app data is not
an artifact. Review any retained transcript for accidental sensitive content.

This tests real platform channels/plugins on an emulator/simulator **only if the
native runs actually pass**. Fresh Dart objects are not a process restart. A
never-written scope requires a fresh disposable app sandbox; a stale preexisting
block marker alone would not prove missing-file behavior. Malformed method
arguments are **not malformed on-disk fence contents**. Deliberately corrupting
native files would require a separate, nonshipping fixture harness and is not
provided here. No shipping test hook or arbitrary native writer was added.

Remaining gates: malformed on-disk fence behavior, full process restart/kill,
power loss, real hardware Keychain/Keystore, device lock/unlock accessibility,
reinstall, backup/restore/transfer exclusion, actual provider or hosted Auth flows,
physical-device failures, dependency/security audit and release authorization.
Simulator success cannot clear these gates or authorize publishing.
