# Security and disclosure

This repository is a development foundation, not a security certification. Do not store real user data or expose a production endpoint until all release gates in `docs/release-runbook.md` pass for the exact candidate commit.

- Never commit secrets, database passwords, service-role keys, OAuth provider secrets, R2 keys, signing keys, contacts, or user exports.
- Do not report a live vulnerability in a public issue with personal data or exploitation details. The maintainer must configure a private security reporting channel before launch.
- Client checks are for usability. PostgreSQL constraints, column grants and RLS enforce ownership and moderation boundaries.
- The anonymous/publishable Supabase key does not bypass RLS. Service credentials belong only in protected server-side deployment secrets.
- Admin roles are assigned only through a controlled trusted operation, never from user-editable metadata.
- Upload authorization is not image validation. Until byte decoding, metadata removal and finalized-object delivery are verified end-to-end, image publication must fail closed.
- Public repositories must never run privileged `pull_request_target` workflows on untrusted changes. CI has read-only permissions and no deployment secrets.

Testing is limited to synthetic data and systems the owner is authorized to test. No production attacks are performed by the workflows.
