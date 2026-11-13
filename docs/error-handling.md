# Error handling and recovery

Sudan Birds uses local error handling at fallible boundaries and global safety
nets. The goal is to preserve privacy, explain failures, and avoid reporting an
unconfirmed write as successful or retrying it blindly. Adding a `try/catch` to
every getter or widget is not a substitute for those guarantees.

## Application

- Repository and platform operations return typed, Arabic user-facing failures.
  Raw exceptions, stack traces, credentials and private payloads are not shown.
- Flutter framework errors, uncaught asynchronous errors and platform-dispatcher
  errors have global fallbacks. Startup failures stop the indefinite loading
  indicator and explain how to recover without falling back to insecure storage.
- Account-bound screens invalidate their data and pending results after an
  account change or failed session observation. A late result must not replace
  the current failure or restore a previous account's state.
- Loading, forms, picker results and navigation callbacks check the current
  screen/account before continuing. Failed actions release their busy indicator,
  but uncertain writes keep their separate resubmission lock.
- Failure messages and recovery controls remain accessible at larger text sizes;
  important asynchronously displayed messages are live regions for screen readers.
- A message about an unknown write outcome asks the user to check its state before
  repeating it. Media completion uses the existing upload intent for reconciliation.

### Account-write fencing

Profile/contact saves and moderation/status actions hold an account/resource
fence in the repository instance. If the pre-write lookup times out, the caller
receives a definite no-write result and a late lookup cannot dispatch the expired
write. A later valid request may proceed. Once a write has been sent, an uncertain
result keeps the resource quarantined, including after a late response and across
navigation using the same repository. Concurrent callers cannot clear each
other's fence. Known pre-write validation failures and confirmed success release
it. There is no automatic retry or read-reload unlock.

Profile and contact writes request the returned owner key and require exactly one
matching row. Empty, mismatched or malformed replies do not display success.
Both listing-report entry points use the same reason validation and trimming.
Profile and moderation screens preserve an uncertainty warning and disable all
same-screen write actions after an unknown result, including exceptions caught
by the UI boundary; read-only refresh does not reopen them.

This is an in-process safety boundary, not server-wide exactly-once execution.
It cannot coordinate separate devices or repository instances, and it does not
persist across process termination. A stronger recoverable retry contract needs
server operation IDs/version checks and a reconciliation flow. Do not interpret
restarting the app or rereading one row as proof that an earlier write cannot
still arrive.

## Server

- Every application Edge handler uses the shared HTTP boundary. Responses contain
  a stable error code and correlation ID instead of the original exception.
- JSON bodies retain an 8 KiB streamed limit and a 10-second total read deadline.
  Shared backend requests have a 15-second abort signal. Timeout is not proof
  that a remote mutation did not happen, so no automatic mutation retry is added.
- Response-body cancellation has a one-second grace. Cancellation, lock release
  or client destruction failures cannot replace a confirmed result or the primary
  error. A completed grace period does not prove every transport handle closed.
- Media verification validates database replies. A malformed commit response
  leaves the outcome uncertain and never authorizes deletion of a possibly
  published image. Only a definite losing output is eligible for cleanup.
- Account deletion validates job and owner identities before privileged work.
  An uncertain Auth deletion requires independent absence verification before
  the job can be marked complete.
- Contact responses contain only the expected contact fields. Database
  authorization/validation failures remain transaction-aborting errors; they are
  not swallowed to manufacture successful results.
- Diagnostic events use fixed names. API failure logs may include a generated
  correlation ID, but not user identities, contacts, object keys, URLs, passwords,
  tokens, request bodies or raw exceptions. A failed log sink cannot change the
  operation's result.

## Verification and remaining limits

Regression tests exercise delayed responses, changed accounts, interrupted
pickers, missing navigation, malformed backend replies, failed/hung cleanup,
lost mutation replies, bounded streams and sanitized diagnostics. Relevant tests
live in `app/test/error_boundaries_test.dart`,
`app/test/account_write_safety_test.dart`,
`app/test/uncertain_write_ui_test.dart` and
`supabase/functions/_shared/*_test.ts`.

Passing local tests does not establish hosted Auth/R2 integration, physical-device
VoiceOver/TalkBack behavior, signing or release readiness. Those checks remain
separate release gates and must apply to the final source being distributed.
Process termination, operating-system failures, out-of-memory termination and an
unavailable logging service cannot be guaranteed to produce an application error
report. The implementation does not claim absolute capture of every failure.

## Local diagnostic coverage

`localDiagnostics.snapshot` is an immutable, in-process inspection interface for
up to 100 recent failure observations. `reset()` clears the live buffer; already
obtained snapshots remain unchanged. Process exit loses the buffer. Nothing is
written to disk, printed, uploaded, or shared. There is no export UI or telemetry
service. Events accept only closed boundary/code enums, a UTC timestamp, and an
outcome-unknown flag. Exceptions, stack traces, runtime types, messages, URLs,
account identifiers, contact data and tokens are never accepted by this recorder.
Recording is best effort and non-throwing: diagnostic failure must not replace an
operation's original failure or prevent its existing user-visible warning.

Covered observations: shared operation/mutation wrappers (timeout, known failure,
unexpected failure), UI guards (thrown and returned failures), startup, Flutter,
platform and zone safety nets, secure-storage queue failures, OAuth link delivery,
callback exchange/install and failed callback cleanup. Nested boundaries can
record more than one observation for one failure; this is not an incident count.
Known failures retain their existing result and uncertainty flags. Runtime safety
nets mark the outcome unknown conservatively and retain the Arabic warning.

These labels identify containment boundaries, not individual requests or users.
They do not claim universal error capture, native process-crash persistence,
backend monitoring, or production crash reporting. Existing operation-specific
failure/recovery behavior remains authoritative. The recorder cannot diagnose
unobserved native crashes, device termination or failures before Dart starts.

### Mutation review validation (2026-11-13)

The account-write/UI correction was checked locally with pinned Flutter 3.38.5
and the unchanged dependency lock: formatting and analysis passed, and all 238
Flutter tests passed. The 33 added regressions include lookup A timing out, B
succeeding, then A arriving without sending a stale write; sent A timing out with
B blocked before and after A's late reply; zero/mismatched returned rows; shared
report validation; and UI uncertainty locks surviving read refresh and captured
callbacks. The fixture creates/disposes the SDK's real JSON isolate outside the
fake clock; operation deadlines themselves use deterministic clock advances.
Repository policy checks passed. The Python suite had 411 passes and three
existing Gradle-tooling skips. These are local results, not new hosted-service,
physical-device, signed-build or TestFlight evidence. CI for the published source
must still be checked separately.
