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
  screen/account before continuing. Failed actions release their busy state.
- Failure messages and recovery controls remain accessible at larger text sizes;
  important asynchronously displayed messages are live regions for screen readers.
- A message about an unknown write outcome asks the user to check its state before
  repeating it. Media completion uses the existing upload intent for reconciliation.

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
live in `app/test/error_boundaries_test.dart` and
`supabase/functions/_shared/*_test.ts`.

Passing local tests does not establish hosted Auth/R2 integration, physical-device
VoiceOver/TalkBack behavior, signing or release readiness. Those checks remain
separate release gates and must apply to the final source being distributed.
Process termination, operating-system failures, out-of-memory termination and an
unavailable logging service cannot be guaranteed to produce an application error
report. The implementation does not claim absolute capture of every failure.
