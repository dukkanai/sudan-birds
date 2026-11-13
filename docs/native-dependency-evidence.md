# Native dependency evidence

## Status and scope

The existing `native-checks.yml` jobs now have local, post-build evidence-capture support. Adding the workflow and passing offline fixture tests does **not** mean the changed mobile candidate has compiled, resolved natively, or produced an artifact. A future authorized CI run must pass for its exact checked-out commit. Earlier successful runs of another commit do not validate this candidate.

The jobs remain Android **debug** and iOS **unsigned debug simulator** checks. They use the existing Flutter 3.38.5 setup. Android retains its isolated `GRADLE_USER_HOME` and scoped Flutter plugin repository init script. There are no new workflow permissions, signing inputs, provider credentials, deployment steps, or changes to the application's media-upload gate.

## Exact artifact allowlists

Android uploads exactly four named text files; iOS uploads exactly five. Upload happens only after the build, staging checks and redacted secret scan succeed. The workflow lists individual paths, not directories or globs, and treats missing files as errors. Artifacts are retained for seven days; download availability does not grant release approval.

Common files:

- `pubspec.lock`: the exact post-build Dart lock bytes, with no rewriting or redaction. Its digest is recorded. A secret or private absolute path in the lock blocks staging rather than producing an altered lock.
- `manifest.json`: actual checked-out Git commit, tracked working-tree dirty flag after the build, hashes of selected source/build inputs, selected tool versions, evidence-file digests, and a hash/size of the debug APK or simulator's main `Runner` executable. The binary itself is **not** uploaded. The manifest explicitly denies release clearance.

Android also includes:

- `android-debugRuntimeClasspath.txt`: the selected `:app:dependencies --configuration debugRuntimeClasspath` report.
- `android-tink-insight.txt`: `:app:dependencyInsight --configuration debugRuntimeClasspath --dependency com.google.crypto.tink:tink-android`, including available selection reasons.

Both reports run after the successful APK build, in the same Gradle home with the same verified init script. They use `--offline --no-daemon --console=plain`: missing cached resolution fails instead of silently resolving a different online graph. Missing Tink, unresolved components, failure markers, absent target configuration, and unsuccessful report output block staging. This does not pin Maven artifacts or prove which classes/native libraries survived packaging.

iOS also includes:

- `Podfile.lock`: exact CocoaPods lock bytes, required to byte-match `Pods/Manifest.lock`.
- `pod-resolution.json`: the installed local pod identities, pod versions, SHA-256 of each local podspec, and normalized top-level/iOS dependency declarations. Private source/cache paths, authors and arbitrary podspec fields are excluded. Pod identities must occur at the same version in the lock. These declarations are not a second full resolver: `Podfile.lock` remains the resolved graph.
- `ios-project.pbxproj`: exact post-build bytes from the single fixed source path `app/ios/Runner.xcodeproj/project.pbxproj`. The file is subject to the same regular-file, size, UTF-8, control-byte, credential and private-path checks as other evidence. It is never redacted. Its evidence digest must also match that path's source-manifest digest, both before staging and during final validation. A disagreement fails instead of presenting inconsistent source evidence.

A missing/empty lock, mismatching installed manifest, missing local podspec metadata, unsafe entry, or inconsistent pod identity fails. There is no “simulator passed, so resolution evidence is optional” fallback. If the project moves to Swift Package Manager, explicitly implement and review collection of `Package.resolved` and local-package resolution evidence before changing this CocoaPods gate.

Pod and Dart package version namespaces can differ. For example, the reviewed secure-storage Darwin Dart package version is `0.4.3`, while its podspec identifies itself as `10.0.0`. Do not call the latter the Dart package version or infer package provenance from either number alone.

## Source identity and capture boundaries

The source snapshot hashes the exact Dart lock and manifest, all files under `app/lib` (required to be Dart source), selected native build/entrypoint/privacy configuration, this capture implementation, and the native workflow. These paths are explicit in `scripts/native_dependency_evidence.py`. It is a bounded post-build snapshot, **not** a whole-repository source manifest, a reproducible-build proof, an attestation, or a signature. The actual Git commit can be a PR merge commit; the dirty flag does not include untracked files. The simulator executable hash does not cover all of `Runner.app` or its frameworks/native assets.

The [run for candidate `40ad627c`](https://github.com/dukkanai/sudan-birds/actions/runs/42714845321) passed both native jobs and their secret scans. Its checkout was synthetic merge `262d808546f5a1283e4eaf13b9b65ec15848441c`, with the same tree as the candidate. Android's 30 captured source hashes matched. iOS reported a dirty tracked worktree: 23 of 24 captured source hashes matched, but `project.pbxproj` changed during the build. The original four-file iOS artifact contained only its hash, so it could not establish the exact change or its cause. A successful CI result does not imply unchanged effective iOS build inputs.

The added fifth iOS file enables a later authorized run's complete project diff to be reviewed locally against the verified checkout blob. Compare hashes, checkout parents/tree and the exact downloaded snapshot before classifying any change as expected CocoaPods integration. Do not assume that cause from a successful build or a `pod install` log line. Inspect the full diff before deciding whether stable generated configuration belongs in source control. This one snapshot does not inventory every changed tracked file, and does not waive signing, runtime or release gates. The extension needs a new exact-candidate CI run; earlier artifacts do not contain it.

iOS manifest schema is now `2`, requiring the fifth file. Android stays at schema `1` with four files. Validate older four-file iOS artifacts with their producing commit's validator and preserve their narrower scope; they cannot satisfy the new snapshot gate.

The capture script writes raw command output to a fresh private temporary directory and removes it when the script exits. Raw output never becomes an artifact path and is not printed on command failure. No shell tracing, Gradle debug logging, build scans or environment dumps are used. Only known local root prefixes are redacted in the Android reports; unknown private absolute paths fail validation.

Staging uses Python's standard library with explicit file allowlists. All expected input files must exist, be nonempty regular files, and remain within size bounds. Symlinks, hardlinks, special files, unexpected files in capture/podspec/staging directories, malformed/duplicate-key JSON, binary/control bytes, credential-like content, stale output directories, and digest mismatches fail closed. Source hashes are published instead of source-file content, except for the one fixed iOS project snapshot described above. Text inputs/outputs are limited to 1 MiB per file and the final bundle to 4 MiB; only the two fixed build-product paths may be read up to 256 MiB, for their hashes. No binary is staged.

The final exact-file-set, size, digest and content validation runs before and after the workflow's redacted Gitleaks v8.21.2 directory scan. A failed scanner/install or validation step prevents artifact upload. Neither the built-in content checks nor Gitleaks guarantees detection of every possible secret. This workflow is intended for unprivileged, secret-free CI; it is not a sandbox for hostile build code or a reason to inject credentials into builds.

**Never extend artifact paths to include** APK/AAB/IPA files, simulator app bundles, whole `Pods`, Gradle/Pub caches, workspace directories, `local.properties`, generated environment exports, `.env`, keys, profiles, account details, raw logs or credential stores. Full build logs remain governed by the existing CI service; this feature only controls the additional evidence captures and artifacts.

## Action pin provenance

The official GitHub [`actions/upload-artifact` v7.0.2 release](https://github.com/actions/upload-artifact/releases/tag/v7.0.2) links to the verified full commit [`cf430e030ddbb5b0abf93d22962f4752f3646cd9`](https://github.com/actions/upload-artifact/commit/cf430e030ddbb5b0abf93d22962f4752f3646cd9). The workflow pins that SHA, not the mutable tag. Its [action schema](https://github.com/actions/upload-artifact/blob/cf430e030ddbb5b0abf93d22962f4752f3646cd9/action.yml) supports explicit paths, missing-file errors, hidden-file exclusion and retention. It runs on Node 24 using the existing GitHub-hosted runners. Pinning is provenance control, not a security audit of the action or its dependencies.

## Scanner toolchain prerequisite

The [first candidate native run](https://github.com/dukkanai/sudan-birds/actions/runs/42712740594) compiled both Android debug and unsigned iOS simulator successfully. Android evidence passed scanning and uploaded. The [iOS evidence step](https://github.com/dukkanai/sudan-birds/actions/runs/42712740594/job/129486268215) failed with exit 127 because `go` was absent from the macOS runner's `PATH`; Gitleaks did not run, and no iOS evidence was uploaded. That was a missing scanner prerequisite, not a reported secret finding. The failed gate remains failed until a new exact-commit run succeeds.

The iOS job now explicitly provisions Go before building, with cache disabled. The official [`actions/setup-go` v7.0.0 release](https://github.com/actions/setup-go/releases/tag/v7.0.0) resolves to [`b7ad1dad31e06c5925ef5d2fc7ad053ef454303e`](https://github.com/actions/setup-go/commit/b7ad1dad31e06c5925ef5d2fc7ad053ef454303e). Go is fixed to `1.27.3`, verified as a stable release with macOS ARM64 and x64 distributions in the [official Go download metadata](https://go.dev/dl/?mode=json). The action adds the toolchain to `PATH`; no persistent credential or new workflow permission is added. Its standard Go configuration appears in job logs, not in evidence artifacts. Capture scripts do not dump the process environment.

Gitleaks remains exactly v8.21.2. Pre-scan and post-scan validation, explicit platform allowlists, failure behavior, unsigned build scope and upload ordering remain enforced. An offline regression test requires the exact setup action/version/cache configuration before the iOS build and scanner; removing the prerequisite or introducing an ignored-failure path fails that test. The `40ad627c` run verified this prerequisite on macOS; any later workflow change still needs its own exact-candidate CI run.

## Offline verification

From the repository root:

```sh
python3 -m unittest discover -s scripts -p 'native_dependency_evidence_test.py' -v
python3 -m unittest discover -s scripts -p 'flutter_plugin_repositories_test.py' -v
python3 scripts/check_repository.py
bash -n scripts/capture_native_dependency_evidence.sh
git diff --check
```

The native-evidence tests use synthetic files and mocked Git identity, plus the public candidate lock and iOS project as exact-byte fixtures. They cover both platform allowlists; exact lock and project preservation; source/binary hashes; path redaction; missing, unresolved or mismatched evidence; symlink/hardlink/FIFO/size/content boundaries; staging tampering; and workflow ordering/pins/path scope. iOS project tests also reject missing or unsafe snapshots, credentials/private paths, changes between capture and source hashing, and disagreement between evidence and source-manifest hashes. No native tools, builds, network calls or uploads are performed by these tests. The existing Gradle integration tests require `GRADLE_TEST_BIN`; skipped tests are not passing integration evidence.

## Remaining native and release gates

This capture closes only part of the resolution-evidence gap when it actually runs successfully. It does **not** clear:

1. Native compilation of the exact candidate or exact-release `releaseRuntimeClasspath` and APK/AAB/device build. Debug/simulator results cannot stand in for signed distribution results.
2. Complete Maven/POM and Pod transitive source/checksum/license inventory, native locking/verification, package provenance, or a reviewed SBOM/advisory scan. Local podspec hashes are metadata hashes, not an independent rehash of upstream package archives.
3. Dart/FFI and embedded-source license coverage, generated Flutter notices, Pod acknowledgements, packaged license/NOTICE retention, or distribution rights. JNI's embedded C/header notices and Objective-C native build outputs need separate review. This minimal bundle deliberately does not claim to collect these.
4. Final APK/AAB/app-bundle content, native-library reachability, privacy manifest bundling, entitlements, signing, reproducibility or supply-chain attestations.
5. Real-device secure-storage/backup/reinstall behavior, actual Google/Apple OAuth redirects, callback interception tests, accessibility, runtime security and release approval.

Any missing, failed or unexecuted required security/release gate remains blocking. Do not convert successful graph capture into a claim that native dependencies, licenses or binary content are cleared.
