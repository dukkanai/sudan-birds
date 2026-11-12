# Guarded signing-key persistence proof

The registered workflow is **disabled by default**, and no real key recovery is
claimed until the protected run succeeds. It does not sign an app, contact Apple, issue/revoke a
certificate, upload an archive, or change any release gates. A public
certificate cannot recreate its private key.
Do not hand off another CSR until its matching encrypted key/password have been
saved durably and their recovery has been demonstrated.

The active copy is `.github/workflows/signing-key-proof.yml`; its reviewed example
is `docs/examples/signing-key-proof/workflow.yml.example`. Both contain the same
inline Python program and **no checkout or actions**.
The same embedded program is exercised by `scripts/ios_staging_key_proof_test.py`.
There are no package downloads, network/API calls, token permissions, artifact or
cache uploads. Only `BIRDS_DISTRIBUTION_KEY_PEM` (one encrypted PKCS#8 PEM) and
`BIRDS_P12_PASSWORD` are referenced. The existing Apple upload key is not read.

## Before any activation

1. Review the full exact example source, context guards and tests. Confirm the
   independently generated public CSR matches its encrypted private key locally.
   Pin that key's SHA-256 of DER SubjectPublicKeyInfo in `EXPECTED_SPKI_SHA256`.
   The example now pins the public digest of the single replacement key reported
   on November 12, 2026; this is not proof of successful secret recovery. Missing
   activation/source/run variables still fail closed. The password must be 32–128 printable non-space
   ASCII characters, without line endings; preserve it exactly when saving.
2. Verify that **sudan-birds-ios-staging already exists** in
   `dukkanai/sudan-birds`. It must require owner `dukkanai`, disallow admin bypass,
   and permit only branch policy `refs/pull/1/merge`. Self-review is allowed in the
   currently reviewed configuration. Never create/relax a protection to make the
   job pass. With zero token privileges and no API access, this small proof cannot
   itself re-read the protection policy: the owner must verify it before approval.
3. Save only the new encrypted PEM and matching password to the two named secrets
   in that protected environment. Save/reload metadata is not content validation.
   Keep source files private until proof succeeds; do not destroy the only copy.
4. Review the registered workflow on PR **1**, `build/foundation` into `main`,
   without merging `main`. No job runs by default.
   Set repository variables `BIRDS_ENABLE_KEY_PROOF=true` and
   `BIRDS_KEY_PROOF_HEAD_SHA` to that exact reviewed head. Owner `dukkanai` triggers
   a `labeled` PR event. Forks, another PR/branch, non-owner actors, dispatches,
   self-hosted runners and attempts above 1 fail closed. Only the approved single recovery proof is in scope; application signing and
   release remain disabled.
5. Once the labeled event has created a run waiting for environment review, read
   its numeric run ID. Independently resolve and review `refs/pull/1/merge` and
   confirm PR head/base have not changed since the event. Set environment variables
   `BIRDS_KEY_PROOF_WORKFLOW_SHA` to that reviewed merge commit and
   `BIRDS_KEY_PROOF_RUN_ID` to the pending run ID. The runtime requires its actual
   `GITHUB_SHA` to equal this expected merge. A run API `head_sha` is not proof of
   the synthetic merge SHA; do not substitute it. Review the workflow as it exists
   in that exact merge commit, not just the head label.
   These are nonsecret identifiers; never put credential values in variables.
   An unknown or stale head/run/merge digest blocks the proof.
6. The owner reviews and approves that one environment job. Do not self-approve
   or bypass the reviewer control on the owner's behalf. No retry is implied by
   approval of the first run. Recheck state before any new run.

The proof writes the encrypted PEM and password into one owner-only temporary
folder, supplies a minimal child environment, and invokes the system OpenSSL
without a shell. It checks private-key consistency, derives only the public SPKI and compares its digest with the
pinned value. Child stdout/stderr and exception details are never emitted.
Each of the two fixed commands is bounded to 15 seconds; its own process group is terminated and
reaped on success or failure, including when its leader has already exited.
Cleanup failure cannot be reported as successful recovery. The sole public JSON
contains fixed proof/stage/cleanup labels, not keys, digests, paths or responses.

A passing run demonstrates that **these stored secrets can recover this public
key on a fresh runner now**. It is not a new secret backup, cryptographic access
control, signing-certificate proof, revocation check, physical-device test or
release-readiness claim. Keep the durable secrets until a verified P12 supersedes
them under the approved cleanup plan. Disabling the proof variable after its
single result prevents an accidental later event from starting another proof.

This code is not a sandbox. An administrator who changes the workflow or its
protections can change what runs with secrets. Review is the trust boundary.
Python strings and the process's initial environment are not securely zeroed;
ordinary file deletion is not secure erasure. SIGKILL or runner loss can prevent
cleanup. Use only a fresh GitHub-hosted runner, never a persistent/shared runner.
Do not infer that an old inaccessible computer has been erased.

## Offline verification

```sh
python3 -m unittest discover -s scripts -p 'ios_staging_key_proof_test.py' -v
python3 scripts/check_repository.py
```

The existing `ios_staging*_test.py` CI discovery includes these tests without
changing its discovery pattern. The tests generate a short-lived **synthetic** RSA key locally and run the exact
inline proof. They do not read GitHub secrets or create an Apple identity. Any
hosted result must be verified separately for its exact run and workflow source.
The full app's existing security/device gates remain unchanged.
