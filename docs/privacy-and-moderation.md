# Privacy and moderation draft

**Draft for owner/legal review. Not a published privacy policy or accepted user agreement.**

Public content: display name, listings and verified image descriptions. Contact data is stored separately and revealed only to an authenticated eligible viewer after explicit owner consent. Never expose private report details to a reported account.

Before first publication, show the final terms and record the accepted version and time. Ban illegal wildlife trade, deceptive listings, animal cruelty, harassment, doxxing and unsolicited private information.

User safety must include reporting listings/accounts and blocking users. The server applies both directions of a block to authenticated content visibility and interactions. Public anonymous browsing cannot provide identity-based secrecy: content intentionally made public may still be visible while signed out. Explain this limit to users.

Moderator operations must require a server-held role and append an audit record. Agree handling times, appeals, support contact and staffing before accepting public content. No real support email or moderation SLA is invented here.

Account deletion must be available in-app before store submission. It must stop new writes, remove/revoke sessions and Auth account, delete or lawfully anonymize content according to the final policy, remove R2 originals and derivatives, invalidate relevant caches, and retry orphan cleanup safely. The implementation freezes content and uses durable cleanup jobs before Auth deletion. Local tests are not evidence that the hosted end-to-end process succeeds. Private zero-byte object tombstones and minimal UUID-based security records may remain to prevent late in-flight uploads from restoring deleted payloads. Final retention scope and duration must be approved and disclosed before real users accept the policy. Do not claim erasure of every identifier or object key. Existing signed image reads may remain usable for their short validity period unless the payload is fenced first.

Set and disclose retention for expired listings, rejected uploads, reports and audit records. Confirm regional data-hosting requirements and subprocessors before launch.
