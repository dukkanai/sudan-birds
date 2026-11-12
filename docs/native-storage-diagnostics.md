# Bounded native storage diagnostics

The same integration fixture runs on its owned disposable simulator, with the
same 600-second command deadline, assertions and verified cleanup. `--machine`
replaces only the expanded human reporter. It does not skip tests, retry, widen
timeouts or turn failure into success.

A concurrently drained pipe never prints or saves raw Flutter/native output.
Stderr remains discarded. Lines are bounded to 8 KiB; after 2 MB parsing stops,
and further bytes are drained and discarded so output cannot block the child.
Only fixed labels and an integer fixture identifier remain. Reader teardown is
bounded even if a descendant retains the pipe. Diagnostic errors preserve the
original command failure and mark observations unknown. Timings flush immediately.

Sources:
- Flutter 3.38.5 [EventPrinter](https://github.com/flutter/flutter/blob/3.38.5/packages/flutter_tools/lib/src/test/event_printer.dart)
  emits the one-element `test.startedProcess` event with a VM-service URI.
  The URI is discarded. This is an observation of a reported device process,
  not proof of responsive native storage or test success.
- The [Dart JSON reporter](https://github.com/dart-lang/test/blob/master/pkgs/test/doc/json_reporter.md)
  emits `testStart` for the exact `real native storage and restore fence smoke`
  fixture and its matching `testDone`. Loading tests and arbitrary print messages
  are not that fixture. A finish observation includes failed tests and is not a
  pass. Skipped, retried, duplicate or malformed completion leaves it unknown.

ANSI/decorated lines, invalid UTF-8, duplicate keys, partial lines and unsupported
formats do not become stage evidence. Observations do not control cleanup,
process exit status, CI success or signing readiness. Without a process event,
build/install/launch/VM discovery and earlier Flutter setup remain indistinguishable.
Do not guess from missing events or human logs.

## Evidence and limits

Source `b1d883f17b36758303546b2274b2c754d88884c1`, native
[run 43151658055](https://github.com/dukkanai/sudan-birds/actions/runs/43151658055),
timed out twice in the test command: 601299 ms and 600642 ms. Both attempts
confirmed a booted simulator before the command and deletion afterward. Raw
child output was discarded; new diagnostics cannot reconstruct those failures.

Successful source `6981015304351a46633e69f653a536b83dac3d46`, native
[run 43120062309](https://github.com/dukkanai/sudan-birds/actions/runs/43120062309),
used the same app, native fixture/orchestration, macOS image
`macos-15-arm64/20261104.0514.1` and Flutter 3.38.5. Its test command completed in
239704 ms. No root cause for later timeouts is established.

Local tests use synthetic machine events, real local child pipes, output floods,
timeout/reader faults and retained pipe handles. They do not run an iOS simulator
or establish machine-event compatibility on GitHub. Fresh CI on the resulting
source is required; signing remains blocked until all required checks pass.
