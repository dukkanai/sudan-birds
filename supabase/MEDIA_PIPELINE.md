# JPEG verification: implemented, operational enablement blocked

## Current bounds

- Baseline single-scan JPEG only; 2,097,152 encoded bytes maximum.
- Each dimension 1–640 and total pixels <=409,600. Fresh pixel-only encoding at quality80.
- jpeg-js0.4.4, useTArray=true, tolerantDecoding=false, maxResolutionInMP=0.4096,
  maxMemoryUsageInMB=16. Header limits run before decoding; decoder limits independently
  bound allocation. No EXIF/XMP/IPTC/ICC/COM or thumbnail data is passed to the encoder.
- One in-flight verification per isolate; three prepared attempts per intent before
  any object download/decoding; three attachments per content item; twenty intents/day.
- Encoded stream is bounded while reading and checked against expected bytes, not
  only a caller-supplied Content-Length/Content-Type. Network operations have deadlines.
- Heap/external admission fails closed before decoding. RSS is measured for diagnosis,
  NOT used as an absolute limit because a hosted process can contain multiple isolates.

The small image dimensions are a temporary quality tradeoff. Do not claim full-size
photography or support for all JPEG variants. Client reencoding helps bandwidth but
never substitutes for server decoding.

## RPC and object ordering

1. Caller-authenticated reserve_upload serializes per-user quotas and reserves a
   quarantined key. Its durable registry entry survives content/account cascades.
2. `media reserve` issues a two-minute PUT capability. The signed condition permits only creation, never replacement; reusing the URL
   after a successful write receives412. The object is private and cannot be attached merely after PUT.
3. `media complete` verifies the caller with Auth; service-only prepare RPC checks
   owner/expiry/visible target, bounds attempts and registers a fresh unique clean key.
4. One bounded GET supplies the bytes decoded and reencoded. Never refetch/copy the
   mutable quarantine object after validation. Each competing attempt gets a distinct key.
5. The clean bytes are written using a short server-only PUT capability expiring no
   later than the intent. They are not written over any published or quarantine key.
6. Row-locked commit rechecks owner, deletion status, expiry, target and dimensions.
   Exactly one canonical key is published. Replay returns the existing media ID.
7. A definite loser can delete only its own key. An ambiguous database commit never
   triggers deletion of a potentially published key. The durable registry retains
   failed/uncertain outputs for later reconciliation.
8. Manual admin lifecycle cleanup selects expired quarantine/orphan objects only
   after their safe expiry; it never selects a referenced image except in a confirmed
   account-deletion job. Cleanup repeats in batches of three. It replaces payloads with retained zero-byte
   commit-time fences and verifies those tombstones before acknowledging cleanup. No recurring schedule is configured.

GET URLs expire after60seconds. Already-issued URLs remain bearer capabilities until
expiry despite a later block. Public R2 access stays disabled. The application must
never receive R2 credentials or a Supabase service key.

## Edge API contract

POST `media` with JSON and authenticated user bearer token:

- reserve: `{action:"reserve", listing_id, bytes, mime:"image/jpeg"}`
  returns intent_id, put_url, expires_in120 and exact Content-Type/Content-Length/If-None-Match headers.
- complete: `{action:"complete", intent_id, alt_text?:string<=500}` returns
  `{media_id,status:"verified"}` only after successful canonical commit.
- read: `{action:"read",media_id}` applies the caller's RLS and returns URL/60seconds.

Safe errors include invalid_image, invalid_upload, verification_denied,
verification_pending_retry, verification_busy and image_verifier_busy. A temporary
failure is not publication. Retain the intent for an explicit verification retry.

## Resource evidence and blocker

Local Deno2.5.6, fixed noisy JPEG pre-generated in a separate process:

- Original1MP sample: approximately304–349ms per sanitize; ten tight iterations grew
  processRSS to550MB. This motivated narrowing the cap.
- 640² sample571,931bytes with128MiB V8 old-space limit, event-loop turns and no forced
  GC:121–173ms for accepted operations;11 of20 sequential operations accepted,9
  rejected by heap/external admission. Peak sampled heapUsed128,022,080bytes,
  external36,518,330bytes, processRSS300,695,552bytes.
- Burst admission test: one active operation,19 rejected while it is in flight;
  the lease releases on both success and error.

These numbers are process snapshots, not a peak-memory profiler or actual Edge
certification. **Warm-isolate availability remains unacceptable/unproven.** Do not
turn the feature on merely because unit tests pass. Reproduce cold/warm sequential
and burst behavior on the exact deployed Supabase runtime, with the full dependency
bundle. Keep the current flag false until resource/availability results are acceptable.
No Promise.race timeout is claimed to preempt synchronous decoding.

A later specifically approved hosted codec-only probe at immutable `3c0cecf`
completed 19/19 sequential sanitizations after one unauthorized-token rejection.
Codec time was 194–233 ms; maximum sampled heap-used plus external was 45.41 MiB,
not a peak. RSS was unavailable (zero), and counters reset across four observed
sequences with a highest observed call count of five, without isolate IDs. The function and temporary credential
were removed and verified absent within about 182 seconds. This narrows the fixed
fixture uncertainty but does not establish full media-bundle, burst, adversarial
or real R2 behavior. Keep uploads disabled; details are in `docs/verification.md`.

Required integration cases: revoked/expired sessions, wrong caller/owner, expiry,
malformed/truncated/oversized input, replayed and overwritten quarantine uploads,
concurrent completions, hidden/deleted target mid-flight, R2 GET/PUT/delete failure,
unknown commit outcome, orphan cleanup and signed URL expiry during deletion.

### Signed-out image browsing

POST `media-read` with `{media_id}` serves verified public images without an account
through the anon-key/RLS client, not a service client. Its repository gateway JWT
setting is off because anonymous browsing is intentional. The approved hosted
five-function correction is applied and its negative/public-read boundaries passed
as recorded in `README.md`; real image delivery is still unverified. No Authorization
header, or the exact
configured public/anon key, uses anon RLS. Any other bearer token must pass Auth.getUser
for this project and retains the authenticated user's blocks. Invalid/expired/foreign
user tokens fail; they never silently downgrade to anon. This endpoint has no upload,
verification, contact or deletion operation. The existing authenticated `media read`
action remains compatible, while clients should use media-read for public galleries.
Gateway behavior and token variants still need actual staging tests.

## Commit-time fencing replaces expiry-only deletion assumptions

R2 documents that `If-None-Match: *` is checked atomically at object commit. Every new
raw AND canonical PUT now includes that condition in its cryptographic signed headers,
along with content type and length. Clients must send the exact condition. A412 is a
conflict, not permission to retry without the header. Retry verification of the same
intent or obtain a new intent/key for a new image.

Expiry prevents new requests but is NOT proof that an older transfer cannot finish.
Deletion therefore removes the payload by an unconditional trusted replacement with
an acknowledged zero-byte, metadata-marked tombstone. A subsequent HEAD verifies that
fence. The tombstone stays present so any earlier create-only PUT is rejected at commit.
It is NEVER deleted by this application or an automatic bucket lifecycle. A late raw
object cannot be verified while an account deletion job exists.

The durable registry records both create_only provenance and fencing acknowledgement.
Legacy keys issued before this protocol default to create_only=false and cannot be
marked safely cleaned merely from404/expiry/elapsed time; such accounts remain pending
operator review. This staging project has not issued earlier upload capabilities,
but deployments over populated databases must check for legacy rows explicitly.

Tombstone key/metadata retention is a deliberate, reviewable security requirement.
No arbitrary fixed grace period is represented as proof that a fence can be removed.
A later purge requires evidence that no outstanding write can commit, plus explicit
retention review. Verify missing/altered conditional headers are rejected and a late
in-flight PUT cannot replace a tombstone against actual R2 before enabling uploads.
Sources: https://developers.cloudflare.com/r2/reference/consistency/
and https://developers.cloudflare.com/r2/api/s3/extensions/ .
