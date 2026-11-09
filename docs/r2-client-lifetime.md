# R2 operation-owned SDK clients

Local development change, 2026-11-09. No hosted call, resource workload, credential access, upload
enablement, deletion, deployment, commit or push was performed for this change. This is
resource-ownership hygiene, not evidence of a real socket leak or a measured memory improvement.

## Pinned implementation reviewed

The installed S3 client and presigner are both 3.1164.0, unchanged in the lockfile. The installed
Smithy core is 3.39.0 and Node HTTP handler is 4.14.2.

- The Node S3 runtime selects `NodeHttpHandler`. Its default HTTPS agent has `keepAlive: true` and
  `maxSockets: 50`; this limit is per handler, not global.
- Smithy `Client.destroy()` calls its configured request handler's `destroy()`. NodeHttpHandler
  destroys initialized HTTP/HTTPS agents. Its synchronous method does not await pending
  configuration initialization or an asynchronous close. A presign does not send HTTP or open a
  socket, and its destroy can occur before the handler's transport configuration is initialized.
- The SDK's `transformToWebStream()` returns a supplied Web ReadableStream directly or calls
  `Readable.toWeb()` for a Node Readable. These are different cancellation paths. The installed
  FetchHttpHandler's destroy is empty; no claim is made about which transport a hosted Edge bundle
  selects.

Reviewed installed source SHA-256 values:

| File below `supabase/functions/node_modules/`      | SHA-256                                                            |
| -------------------------------------------------- | ------------------------------------------------------------------ |
| `@smithy/core/dist-cjs/submodules/client/index.js` | `a020eb9c0a20f4d965f9e6651e2eb1cf6ecab7fe72fdb4c866d55d77665d7a5b` |
| `@smithy/node-http-handler/dist-cjs/index.js`      | `e962f7385fd2a1d8e4dca454ea78b3d4c61981baffedb841cb8fa67a84d308c0` |
| `@smithy/core/dist-cjs/submodules/serde/index.js`  | `56566ce6e4cc399bda5c20324586ebfd2a7719b5d007030b689dbcec75cb5bda` |

## Exact lifetime and cancellation guarantees

`_shared/r2.ts` still constructs a fresh private S3Client per operation. Each helper now destroys
only that client in `finally`:

- Upload/read presigning completes or fails before destruction. The independent signed-URL fetch
  used by `writeVerified` does not depend on that signing client.
- Download retains its client through SDK response deserialization and complete image consumption,
  terminal stream error, or bounded cancellation.
- Tombstoning retains the same client for the zero-byte PUT and final HEAD, including metadata
  verification. PUT or HEAD failure also destroys it.
- Concurrent operations do not share a client, so finishing one does not destroy a different active
  download.

`_shared/image_stream.ts` now records the abort-triggered cancellation promise rather than
discarding it. Cancellation gets a maximum **1,000ms grace**, also used for rejected metadata,
excess bytes and invalid expected sizes. A cancellation rejection is handled without replacing the
original `invalid_image` or `image_download_timeout`. Already-aborted readers initiate cancellation
too. The existing 15,000ms download and 10,000ms PUT/HEAD abort signals are unchanged; cancellation
cleanup can add up to the grace interval after an abort.

The grace is a bound on waiting, not a proof of cleanup. If cancellation never settles, the helper
returns after the grace and the owning R2 client is destroyed to force its transport cleanup. The
code does not wait forever for a broken source. It does not claim that every underlying handle has
closed by the time destroy returns. Event-loop starvation can delay any JavaScript timer.

An actual Node Readable fixture exposed a further pinned-Deno limit: `Readable.toWeb().cancel()`
settles after invoking Node destroy but before a held asynchronous `_destroy` callback completes.
The SDK client's destroy can therefore precede that callback even after the cancellation promise
settles. The regression test explicitly retains this observed ordering. An exploratory assertion
that cancellation awaited the Node callback failed and was corrected, not reported as a successful
guarantee. No real socket exists in that fixture.

The lifetime-only change did not alter credential configuration, signed headers, retry limits,
ownership/RLS, create-only writes, tombstone fencing or admission thresholds. The subsequent
[fixed-window trial change](media-trial-gate.md) adds admission and canonical-write deadline checks
without changing those storage security invariants.

## Offline verification

`_shared/r2_test.ts` calls the actual production exports and private factory with synthetic
environment values. For each real SDK client, test-only instrumentation replaces the handler's
`handle()` with a closed in-memory transport before send. SDK middleware, signing, serialization,
deserialization, stream mixins and the Client-to-handler destroy delegation execute. Fetch is closed
by default; the signed-write test replaces it with a checked in-memory response. Instrumentation is
restored in `finally`. URLs, signatures and credential values are not logged.

The initial lifetime-only revision passed 18 new R2 tests and the two existing image-stream tests
under native Deno 2.5.6 with cached-only/no-remote modules, cleared environment and denied network,
file, subprocess, sys and FFI permissions. R2 environment names have no read grant. The SDK sees
only permitted metadata names and literal synthetic R2 values. Formatting, lint, type checking and
targeted whitespace checks also passed.

Coverage includes signing success/failure; configuration failure after client creation; exact bytes;
metadata mismatch; overflow/truncation; absent body; stream/transport/SDK errors; one actual SDK
retry; separate concurrent clients; PUT/HEAD errors and failed fence verification; held final HEAD;
delayed, rejected and never-settling cancellation; invalid expected size; signed write headers; and
actual SDK Web/Node stream paths. Abort tests use a controlled signal while asserting the production
call requests 15,000ms. The one-second cancellation races use real timers. They do not measure a
real network timeout or resource load.

The combined timed-trial candidate adds two R2 tests for invalid/expired canonical deadlines and
asynchronously delayed actual-SDK signing. The canonical writer now checks after signing that its
full TTL still fits the absolute intent/trial deadline before starting PUT, and derives the request
timeout from fresh remaining time. The resulting 20 R2 tests are included in the passing 149-test
Edge suite run with the existing `supabase/functions/test.sh`. This aggregate does not itself have
the separate strict-deny launcher's invocation guarantees; those belong to the focused run above.
The combined R2 source hash is recorded below, distinct from the initial lifetime-only hash
`00dd4e65418f6ed2513bcd6587f25627879552a7fc6e6c3341ce5472363cf279`.

Full combined repository checks, exact-candidate CI and hosted verification are separate gates. No
local lifecycle test establishes transport/socket closure, real R2 signature acceptance, tombstone
durability or production readiness.

## Source pins and prior experiment evidence

The historical [SDK resource report](media-sdk-local-experiment.md) and its
[evidence](evidence/media-sdk-local-2026-11-09.json) were not rewritten. Its no-destroy production
correspondence is now historical, not current.

At the lifetime-only review, `scripts/media_sdk_resource.sh` was intentionally **not** repinned. The
original source-drift guard rejects the combined candidate's two source changes:

| Source                    | Historical pinned SHA-256                                          | Combined candidate SHA-256                                         |
| ------------------------- | ------------------------------------------------------------------ | ------------------------------------------------------------------ |
| `_shared/r2.ts`           | `d79ce77751001bcc440bc68b37446a0f351e6a374da4595ef60c2b97ba5ee46d` | `3d5d123807e591ac2d0c87cfb0614221a0bcfb267333e1b4cd285608bf04b0ec` |
| `_shared/image_stream.ts` | `11123134e031d1c63a008037daa05cb0dd1f41bb2414a27f1e0d86624c1b0a0b` | `15da1ef31bbd24a6f2fd3ab2aa725609a2c8f2803ed2e264e50fd277589aebcf` |

The initial launcher unit run passed its argument/mutation guards and failed its positive
unchanged-pin check for precisely these two files. That was a real integration blocker requiring
independent reconciliation, not a passing aggregate check. Presign and package-lock pins remain
unchanged.

Before any new resource run, review the synthetic adapter against the final production source. At
the initial lifetime review, `scripts/media_sdk_fixture.ts` defaulted to no destroy, had optional
destroy comparison mode, and directly canceled metadata mismatches. It imports the changed shared
image-stream helper, so running that unreconciled version without reconciliation would mix
historical adapter behavior with new cleanup. The default/comparison semantics, bounded cancellation
behavior, tests and correspondence documentation need explicit review before any new pins are
accepted. Also reconcile the separate media trial gate changes to the resource workload. Keep the
earlier measurements immutable and attribute any new measurements to a new exact revision; never
relabel old evidence as proving this lifetime change.
