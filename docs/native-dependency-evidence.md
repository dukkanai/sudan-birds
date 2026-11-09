# Native dependency evidence

## Status and scope

The existing `native-checks.yml` jobs now have local, post-build evidence-capture support. Adding the workflow and passing offline fixture tests does **not** mean the changed mobile candidate has compiled, resolved natively, or produced an artifact. A future authorized CI run must pass for its exact checked-out commit. Earlier successful runs of another commit do not validate this candidate.

The jobs remain Android **debug** and iOS **unsigned debug simulator** checks. They use the existing Flutter 3.38.5 setup. Android retains its isolated `GRADLE_USER_HOME` and scoped Flutter plugin repository init script. There are no new workflow permissions, signing inputs, provider credentials, deployment steps, or changes to the application's media-upload gate.

## Exact artifact allowlists

Each platform uploads exactly four named text files after its build, staging checks and redacted secret scan succeed. The workflow lists individual paths, not directories or globs, and treats missing files as errors. Artifacts are retained for seven days; download availability does not grant release approval.

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

A missing/empty lock, mismatching installed manifest, missing local podspec metadata, unsafe entry, or inconsistent pod identity fails. There is no “simulator passed, so resolution evidence is optional” fallback. If the project moves to Swift Package Manager, explicitly implement and review collection of `Package.resolved` and local-package resolution evidence before changing this CocoaPods gate.

Pod and Dart package version namespaces can differ. For example, the reviewed secure-storage Darwin Dart package version is `0.4.3`, while its podspec identifies itself as `10.0.0`. Do not call the latter the Dart package version or infer package provenance from either number alone.

## Source identity and capture boundaries

The source snapshot hashes the exact Dart lock and manifest, all files under `app/lib` (required to be Dart source), selected native build/entrypoint/privacy configuration, this capture implementation, and the native workflow. These paths are explicit in `scripts/native_dependency_evidence.py`. It is a bounded post-build snapshot, **not** a whole-repository source manifest, a reproducible-build proof, an attestation, or a signature. The actual Git commit can be a PR merge commit; the dirty flag does not include untracked files. The simulator executable hash does not cover all of `Runner.app` or its frameworks/native assets.

The capture script writes raw command output to a fresh private temporary directory and removes it when the script exits. Raw output never becomes an artifact path and is not printed on command failure. No shell tracing, Gradle debug logging, build scans or environment dumps are used. Only known local root prefixes are redacted in the Android reports; unknown private absolute paths fail validation.

Staging uses Python's standard library with explicit file allowlists. All expected input files must exist, be nonempty regular files, and remain within size bounds. Symlinks, hardlinks, special files, unexpected files in capture/podspec/staging directories, malformed/duplicate-key JSON, binary/control bytes, credential-like content, stale output directories, and digest mismatches fail closed. Source hashes are published instead of source-file content. Text inputs/outputs are limited to 1 MiB per file and the final bundle to 4 MiB; only the two fixed build-product paths may be read up to 256 MiB, for their hashes. No binary is staged.

The final exact-file-set, size, digest and content validation runs before and after the workflow's redacted Gitleaks v8.21.2 directory scan. A failed scanner/install or validation step prevents artifact upload. Neither the built-in content checks nor Gitleaks guarantees detection of every possible secret. This workflow is intended for unprivileged, secret-free CI; it is not a sandbox for hostile build code or a reason to inject credentials into builds.

**Never extend artifact paths to include** APK/AAB/IPA files, simulator app bundles, whole `Pods`, Gradle/Pub caches, workspace directories, `local.properties`, generated environment exports, `.env`, keys, profiles, account details, raw logs or credential stores. Full build logs remain governed by the existing CI service; this feature only controls the additional evidence captures and artifacts.

## Action pin provenance

The official GitHub [`actions/upload-artifact` v7.0.2 release](https://github.com/actions/upload-artifact/releases/tag/v7.0.2) links to the verified full commit [`cf430e030ddbb5b0abf93d22962f4752f3646cd9`](https://github.com/actions/upload-artifact/commit/cf430e030ddbb5b0abf93d22962f4752f3646cd9). The workflow pins that SHA, not the mutable tag. Its [action schema](https://github.com/actions/upload-artifact/blob/cf430e030ddbb5b0abf93d22962f4752f3646cd9/action.yml) supports explicit paths, missing-file errors, hidden-file exclusion and retention. It runs on Node 24 using the existing GitHub-hosted runners. Pinning is provenance control, not a security audit of the action or its dependencies.

## Offline verification

From the repository root:

```sh
python3 -m unittest discover -s scripts -p 'native_dependency_evidence_test.py' -v
python3 -m unittest discover -s scripts -p 'flutter_plugin_repositories_test.py' -v
python3 scripts/check_repository.py
bash -n scripts/capture_native_dependency_evidence.sh
git diff --check
```

The native-evidence tests use synthetic files and mocked Git identity. They cover both platform allowlists; exact lock preservation; source/binary hashes; path redaction; missing, unresolved or mismatched evidence; symlink/hardlink/FIFO/size/content boundaries; staging tampering; and workflow ordering/pins/path scope. No native tools, builds, network calls or uploads are performed by these tests. The existing Gradle integration tests require `GRADLE_TEST_BIN`; skipped tests are not passing integration evidence.

## Remaining native and release gates

This capture closes only part of the resolution-evidence gap when it actually runs successfully. It does **not** clear:

1. Native compilation of the exact candidate or exact-release `releaseRuntimeClasspath` and APK/AAB/device build. Debug/simulator results cannot stand in for signed distribution results.
2. Complete Maven/POM and Pod transitive source/checksum/license inventory, native locking/verification, package provenance, or a reviewed SBOM/advisory scan. Local podspec hashes are metadata hashes, not an independent rehash of upstream package archives.
3. Dart/FFI and embedded-source license coverage, generated Flutter notices, Pod acknowledgements, packaged license/NOTICE retention, or distribution rights. JNI's embedded C/header notices and Objective-C native build outputs need separate review. This minimal bundle deliberately does not claim to collect these.
4. Final APK/AAB/app-bundle content, native-library reachability, privacy manifest bundling, entitlements, signing, reproducibility or supply-chain attestations.
5. Real-device secure-storage/backup/reinstall behavior, actual Google/Apple OAuth redirects, callback interception tests, accessibility, runtime security and release approval.

Any missing, failed or unexecuted required security/release gate remains blocking. Do not convert successful graph capture into a claim that native dependencies, licenses or binary content are cleared.
