# Read-only staging API capability probe

This diagnostic is disabled by default. It does not declare an environment,
read environment secrets, sign, upload, contact Apple, or change any service.
It uses only the built-in short-lived GitHub token with the same three read-only
scopes as the inert signing workflow. No broader credential is a fallback.

After reviewing a final source commit, set repository variable
`BIRDS_ACCESS_PROBE_HEAD_SHA` to its exact head and `BIRDS_ENABLE_ACCESS_PROBE=true`.
Owner `dukkanai` adds the existing `question` label to PR 1 once. Confirm no prior
run is uncertain before triggering. The same-repository development PR, owner,
approved head, fresh hosted runner and first-attempt checks must pass.
Set the enable variable back to `false` after that one outcome; do not rerun blindly.

The probe reads only `sudan-birds-ios-staging`, its branch policies, and historical
job `131231183815` from run `43232491842`. It checks that job's pinned checkout
evidence equals `542aa22d970e0219fbf329e16c77067e10f2bab8`. These fixed historical
identifiers are deliberate capability fixtures, not current-source CI evidence.
If their logs expire, that is a blocked diagnostic, not permission failure proof.

Only fixed statuses and a `bypass_field_present` boolean are printed. In particular,
missing `can_admins_bypass` or an inaccessible policy blocks the environment check;
UI screenshots or local attestations do not substitute for the runtime API proof.
The existing environment validator and bounded/no-auth-forwarding log reader are
reused unchanged. No raw response, log, exception, token or signed URL is emitted.

A pass proves these specific API reads and the current policy are available to
this restricted workflow token now. It does not validate final-source CI, Apple
credentials, profile, archive/export, upload, real devices or release readiness.
The full signing gate must still run independently on the final approved source.
