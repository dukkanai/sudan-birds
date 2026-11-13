# Fixed-window, two-account media trial gate

Local candidate only. This change does not enable uploads, deploy an Edge function, change secrets,
create accounts, or authorize a hosted trial. The existing default-off state must remain off until
the exact candidate passes independent review and the required release checks. Historical local
bundle/SDK resource experiments are preparation, not hosted capacity or release evidence.

## Configuration contract

The `media` handler admits `reserve` and `complete` only when all four values are present and valid:

| Setting                   | Required value                                                                                                                                                                                                                |
| ------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `MEDIA_PIPELINE_ENABLED`  | The exact string `true`; absent, false, and other spellings deny.                                                                                                                                                             |
| `MEDIA_TRIAL_ACCOUNT_IDS` | A JSON array of exactly two distinct, structurally valid UUIDs. Case is normalized before uniqueness and membership checks. Wildcards, additional IDs, non-arrays, invalid UUIDs, and values longer than 256 characters deny. |
| `MEDIA_TRIAL_STARTS_AT`   | A real, canonical UTC timestamp in `YYYY-MM-DDTHH:mm:ss.sssZ` format.                                                                                                                                                         |
| `MEDIA_TRIAL_EXPIRES_AT`  | The same timestamp format, strictly later than start and at most 20 minutes after it.                                                                                                                                         |

Only `starts_at <= server time < expires_at` is open. The timestamps are absolute, not a renewable
duration calculated at startup or per request. The flag alone never opens uploads, and there is no
production or allow-all override.

An operator must independently verify that the two configured accounts are the approved synthetic
fixtures. A valid UUID cannot prove an account is synthetic, and this gate cannot classify uploaded
content as synthetic. Do not put real account identifiers, credentials, tokens, configuration
values, or signed URLs in repository files, evidence, screenshots, logs, or user-facing errors. This
document intentionally supplies no activation command or real configuration.

The application verifies the exact bearer token with `Auth.getUser` first. The gate uses only that
returned, validated user ID, never JWT claims, a body owner, or a client-provided allowlist. Denial
is always the existing generic 503 `media_pipeline_unavailable`, without revealing the allowlist or
timestamps. Auth failures retain the existing 401 authentication boundary. The trial gate also
rejects identities that are not exactly 36-character UUIDs.

## Expiry behavior and preserved boundaries

- The gate reads configuration and server time for every new mutation. In-flight requests also
  recheck at effect boundaries. Changing their admitted account set or start/expiry window denies
  continuation rather than extending it.
- Reservation rechecks immediately before the caller-RLS RPC and after it, then requests a signed
  PUT with `min(120, floor(remaining milliseconds / 1000))` seconds. Less than one whole second
  denies signing. The same TTL is returned as `expires_in`. After asynchronous signing, the handler
  again checks that the full TTL fits the remaining window before disclosing the URL. This is
  conservative near second boundaries and can reject a reservation after it has already consumed
  quota. With the existing TTL-only signer API, an asynchronous signer can internally construct a
  URL whose signed absolute expiry exceeds the window. The post-sign check withholds that URL; it
  does not prevent internal construction or revoke the signature. No such URL is included in errors
  or logs.
- Completion rechecks before privileged preparation, after preparation, before download, before
  decoding, before canonical write, and before commit. The canonical writer receives the earlier of
  the existing intent expiry and the trial expiry. After canonical signing, the writer recomputes
  remaining time and refuses to start PUT unless its full signed TTL still fits that absolute
  deadline. Its request timeout uses the fresh remaining milliseconds, capped at 15 seconds.
  Existing create-only signing, conditional writes, ownership, caller RLS, service-client
  separation, codec limits, concurrency gate and durable object registry remain in place.
- If preparation or download crosses expiry, later upload effects stop. If a canonical write
  finishes after expiry, commit is not started; the registered unpublished object remains for normal
  authorized cleanup. It is not deleted speculatively.
- A commit already dispatched before expiry can complete after it. The handler returns its definite
  result, even after expiry; an uncertain result never triggers deletion of a potentially published
  winner. Cleanup of a definite losing output is still permitted after expiry.
- Existing authenticated `read`, anonymous/caller-RLS `media-read`, account deletion and lifecycle
  cleanup are not gated by this upload trial.

This is admission and checkpoint enforcement, **not process preemption**. It does not stop a
synchronous codec already running, cancel an RPC or PUT already in flight, revoke a previously
disclosed presign, or guarantee that an R2 operation finishes before expiry. The presign expiry
bounds authorization to initiate a request, not an upload's finish time. Turning the flag off also
does not revoke existing URLs. Absolute-time enforcement assumes a correctly synchronized server
wall clock and ordinary SDK signing with that clock; it is not a defense against an operator moving
the clock or modifying the deployed code/configuration.

No extra deletion is added. Previously authorized cleanup, fencing, retention and uncertain-outcome
rules remain necessary after the window closes, including if the caller/browser exits. Repeated
trials require a separately authorized fresh fixed window; this implementation does not schedule or
renew one.

## Local verification and harness compatibility

`supabase/functions/_shared/media_trial_test.ts` exercises malformed, absent, duplicate,
case-variant, excluded, future, expired, zero/oversized-window and clock/config-failure cases,
inclusive/exclusive boundaries, TTL rounding and configuration changes with an injected
deterministic clock.

`supabase/functions/media/handler_test.ts` exercises the real handler and Auth SDK through closed
synthetic transport, including no-effect denials, identity confusion, repeated requests, expiry
across asynchronous stages, delayed signing, canonical expiry bounds, safe commit/cleanup outcomes,
and unaffected reads and cleanup. A separate test calls `createMediaHandler()` with **no dependency
replacement**, intercepts only environment reads and network transport, and uses the production Auth
SDK and actual create-only presigner. It verifies the default handler refuses
flag-only/excluded/expired requests before privileged operations and checks the signed TTL, deadline
and required headers. Deterministic delayed actual-SDK signing tests drive both the gate clock and
SDK signing clock, verify returned signatures end within the fixed window, and verify internally
generated overrun signatures are withheld. Two additional tests in `_shared/r2_test.ts` cover
invalid/expired canonical deadlines and delayed actual signing, including a positive remaining
interval too short for the full signed TTL, before fetch. Successful cases check the actual signed
expiry and freshly calculated request timeout. No real environment values or remote accounts are
used.

The existing endpoint fixture and both local resource drivers now inject `getEnv` and `now` instead
of a permissive `pipelineEnabled` callback. Their allowlists contain only existing invented fixture
UUIDs. The bundle driver's clock is fixed; the SDK driver anchors its fixed 20-minute window once at
local start, since its real signing adapter uses the wall clock. Neither driver reads trial settings
from the host. These wiring edits do not reproduce old resource measurements or establish production
bounds.

Run the existing `supabase/functions/test.sh` with the approved prepared Deno binary/cache, plus
relevant lint, typecheck and resource-driver guard tests. No new package, secret permission or
network access is required. Do not remove or bypass the SDK launcher's source pins: a separate
source change that affects a pinned adapter must first receive its own correspondence review.

## Required before adoption or release

1. Independently review the precise helper, handler, fixture and test hashes, and rerun all affected
   security/functional checks for that same immutable candidate. Any later source edit invalidates
   earlier candidate attestation.
2. Review any other concurrent R2/resource-lifetime change separately and repeat the combined
   checks. Reconcile source pins only after that review. Local synthetic transport is not production
   SDK/Edge resource evidence.
3. Obtain the required authorization for deployment and a bounded hosted trial. Verify the deployed
   source matches the checked candidate; keep the flag off while doing so. Existing hosted functions
   do not gain this gate merely because it exists locally.
4. Before any approved activation, verify the exact two fixture accounts and fixed UTC window, fresh
   hosted Auth/RLS/storage configuration, create-only behavior, capacity limits, cleanup/fencing
   path, caller limits, and evidence collection/redaction. Test excluded-account and server-expiry
   refusal against the actual deployed gate. Do not use the two-account allowlist as a substitute
   for ownership/RLS tests or grant it production users.
5. Complete appropriate hosted security, abuse and resource tests, and applicable independent mobile
   security/accessibility/privacy/device checks. Document failed, blocked and unrun checks as
   release blockers. A passing local build, unit suite, or this gate alone is not authorization to
   enable production, merge, publish or release.
