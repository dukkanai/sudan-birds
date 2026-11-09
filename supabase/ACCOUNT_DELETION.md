# Self-account deletion and manual lifecycle

POST `account-delete` requires a verified caller JWT and exactly
`{confirmation:"DELETE_MY_ACCOUNT"}`. Ownership is always the verified user, never
request JSON. The exact bearer token must first pass Auth.getUser; its subject and
session_id must match the user and a live Auth session. A selected interactive AMR
timestamp must be within10minutes, not refreshed iat or account-global last_sign_in_at.
The service RPC locks/checks session ownership, created_at and not_after again.
Missing/stale/revoked authentication yields403 recent_sign_in_required. The UI must show the scope and require explicit confirmation.

## Ordering and retries

- A service-only RPC creates/reuses a durable job under the same user lock as media
  reservation and completion. All user table writes and new uploads stop; public
  content is hidden while deletion is pending.
- The job first waits out URL validity using safe_delete_after (roughly6minutes).
  That wait is NOT proof that an older in-flight request cannot finish; the next
  step installs an atomic commit-time fence.
- R2 image payloads are replaced by trusted zero-byte tombstones in bounded batches.
  A HEAD verifies the tombstone, and signed create-only writes cannot overwrite it
  at commit. Any failure returns pending, never completed. The tombstones remain.
- Database readiness requires ALL registered payloads removed and fenced, not merely one batch.
  Only then does the server delete the Auth user; profile, private contacts, owned
  listings, blocks, roles and quota events cascade.
- A final RPC verifies Auth absence before marking completed. Repeated Auth deletion
  is considered successful only after a confirmed404 lookup. A network error is not
  proof of absence.
- HTTP200/status completed means these steps finished. HTTP202/status pending contains
  job_id and retry_after_seconds. While their session still exists, the owner can
  explicitly retry. After Auth removal, an interrupted final bookkeeping step needs
  an authorized admin resume because the former user's session is no longer valid.

No automatic worker/schedule is installed. `lifecycle` requires a verified current
admin role, not a metadata claim or ordinary moderator, unless the separately approved
scoped scheduler credential is configured. POST `{action:"cleanup"}`
processes up to3eligible payloads; repeat while more_may_remain. POST
`{action:"deletion_job",job_id}` resumes one job. The service functions cannot be
called by anon/authenticated roles directly. No endpoint accepts arbitrary object
keys or an arbitrary user ID for deletion.

## Reviewable retention choices, not a finalized privacy policy

- No automatic copy of deleted listing/profile/image content is retained.
- Other users' reports keep target UUIDs and their report reason after a target is
  removed; a moderation screen must say the target is missing, not fabricate content.
- Reports submitted by the deleted account currently cascade with that reporter.
- Moderation actions retain actor/target UUIDs, action, reason and timestamps; an
  actor account deletion no longer prevents removal of Auth. No profile snapshot is
  added. Operators must not paste unnecessary personal content into reasons.
- Private deletion-job/object-ledger UUIDs, keys, timestamps and completion state
  remain for retry/reconciliation. Completed-record purge timing, operational retention
  and any legal retention requirement require review before public release. No
  retention-cleanup schedule is represented as running.
- Existing signed read URLs can remain valid for at most60seconds; ordinary content
  deletion and account deletion do not revoke bearer URLs instantly.

The UI and privacy notice must disclose these distinctions before confirmation.
A completed job does not mean every pseudonymous moderation/operational reference
was erased. Actual Auth/R2 integration, network interruption and repeated-resume
scenarios still require staging validation before enabling this feature publicly.

## Required unattended completion before public enablement

The optional scheduler path is implemented but disabled: `LIFECYCLE_JOB_SECRET` is
unset and no cron exists. Creating this dedicated credential is an action-time
approval step, not covered by source implementation. The reviewed setup outline is
`operations/lifecycle_schedule.sql.example`; it contains no actual secret or active SQL.

After approval, place the same high-entropy base64url secret (minimum43characters)
in the Edge environment and Supabase Vault, and store the exact staging lifecycle
URL in Vault. Install/enable pg_cron and pg_net only if approved and absent. The
approved application gateway configuration in `README.md` disables the legacy
JWT check for all five application functions, including lifecycle; the hosted change
is still pending. Lifecycle independently requires either Auth-verified identity
plus its caller-RLS admin check, or the scoped constant-time job header. Turning
off the legacy gateway does not configure or authorize a scheduler. The separate
undeployed diagnostic retains its gateway check.

A once-per-minute job sends only `{action:"scheduled"}`. It claims one due deletion
with a two-minute retry lease, processing at most3objects, or handles one small orphan
batch. An interrupted worker's lease expires, and attempts rotate through jobs rather
than permanently starving behind one failure. Monitor repeated errors and queue age.
No credential, extension, Vault entry, scheduler or alert was created by this code.

**Public deletion enablement requires this unattended retry path to be configured
and tested.** Without it, a user closing the app can leave a pending job requiring
manual admin intervention. That is an operational blocker, not a completed feature.

## Payload erasure versus retained R2 security fences

R2 cleanup now replaces each payload with a verified zero-byte tombstone rather than
removing the key. All new uploads use signed create-only conditions, so R2's atomic
commit-time check prevents an earlier in-flight PUT from restoring the image afterward.
A404 or URL expiry alone is insufficient. Auth removal waits for acknowledged fencing
of every registered key. Legacy unconditional keys block completion pending review.

Zero-byte objects, opaque keys and private operational identifiers remain as security
fences; they contain no image pixels/metadata from the user. They must not be erased
by a generic bucket expiry rule while outstanding write outcomes are unproven. This
retention must be disclosed and reviewed before public launch. Completion means the
account and image payloads were removed as described, not instant deletion of every
security reference or copies already downloaded by another party.

`own_deletion_status()` returns only the caller's job_id, pending/completed state and
retry_after_seconds, with no user-ID input. Clients should check it before attempting
missing-profile onboarding after a restart. It never exposes another account's jobs.

## Durable, safe failure visibility

Pending responses and own_deletion_status expose blocker_code and requires_operator
when applicable. Storage setup/permission, legacy unconditional upload, Auth setup
and database setup blockers are distinct from normal batching and transient retries.
Only allowlisted codes are stored; no raw provider error, contact or credential is
returned. Permanent setup blockers back off automatic claims for an hour and require
operator intervention, while ordinary batches remain pending without a blocker.
Failure timestamps/counters persist for support, and successful completion clears
the active error. The app must not present a permanent setup problem as normal progress.
