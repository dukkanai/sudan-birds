import { S3Client } from "npm:@aws-sdk/client-s3@3.1164.0";
import { Readable } from "node:stream";
import { ApiError } from "./http.ts";
import { downloadImage, removePayloadAndFence, signRead, signUpload, writeVerified } from "./r2.ts";

function assert(value: unknown, message: string): asserts value {
  if (!value) throw new Error(message);
}
function equal(actual: unknown, expected: unknown) {
  assert(JSON.stringify(actual) === JSON.stringify(expected), "Unexpected lifecycle result");
}
async function rejects(operation: Promise<unknown>, code?: string) {
  let rejected = false;
  try {
    await operation;
  } catch (error) {
    rejected = true;
    if (code) {
      assert(error instanceof ApiError && error.code === code, "Unexpected safe error code");
    }
  }
  assert(rejected, "Expected rejection");
}
function latch() {
  let release!: () => void;
  return { promise: new Promise<void>((resolve) => release = resolve), release: () => release() };
}
const key = "synthetic/sample.jpg";
const bytes = new Uint8Array([1, 2, 3, 4]);
const synthetic: Record<string, string> = {
  R2_ACCOUNT_ID: "a".repeat(32),
  R2_BUCKET: "synthetic-bucket",
  R2_ACCESS_KEY_ID: "SYNTHETIC_TEST_ONLY",
  R2_SECRET_ACCESS_KEY: "SYNTHETIC_NOT_A_REAL_CREDENTIAL",
};
interface Lifecycle {
  client: S3Client;
  events: string[];
  destroys: number;
  handlerDestroys: number;
  signals: AbortSignal[];
}
interface Request {
  method: string;
  hostname: string;
  path: string;
  headers: Record<string, string>;
  body?: unknown;
}
interface Response {
  response: { statusCode: number; headers: Record<string, string>; body?: unknown };
}
type Transport = (request: Request, state: Lifecycle) => Promise<Response>;

// Exercise the production exports and factory, not a copy of the adapter. Each
// actual SDK client retains its handler; replace only handle() with a closed
// in-memory transport before send. Real middleware, signing, deserialization,
// stream mixins and Client.destroy -> handler.destroy still execute. This is
// test-local instrumentation, restored in finally, never a production injection.
async function withStorage(
  run: (states: Lifecycle[], setTransport: (transport: Transport) => void) => Promise<void>,
  env: (name: string) => string | undefined = (name) => synthetic[name],
) {
  const originalGet = Deno.env.get;
  const originalSend = S3Client.prototype.send;
  const originalDestroy = S3Client.prototype.destroy;
  const originalFetch = globalThis.fetch;
  const states: Lifecycle[] = [];
  let transport: Transport = () => Promise.reject(new Error("Unexpected closed transport call"));
  const record = (client: S3Client) => {
    let state = states.find((value) => value.client === client);
    if (state) return state;
    state = { client, events: [], destroys: 0, handlerDestroys: 0, signals: [] };
    states.push(state);
    const current = state;
    const handler = client.config.requestHandler;
    const destroyHandler = handler.destroy?.bind(handler);
    handler.destroy = () => {
      current.handlerDestroys++;
      current.events.push("handler-destroy");
      destroyHandler?.();
    };
    handler.handle = async (request) => {
      assert(current.destroys === 0, "Transport used after client destruction");
      const req = request as Request;
      assert(
        req.hostname ===
            `${synthetic.R2_BUCKET}.${synthetic.R2_ACCOUNT_ID}.r2.cloudflarestorage.com` &&
          req.path === `/${key}` && req.headers.authorization?.startsWith("AWS4-HMAC-SHA256 "),
        "Unexpected serialized or unsigned request",
      );
      current.events.push(`${req.method}:transport`);
      return await transport(req, current);
    };
    return current;
  };
  Deno.env.get = (name: string) => name.startsWith("R2_") ? env(name) : originalGet(name);
  globalThis.fetch = () => Promise.reject(new Error("Network transport forbidden"));
  S3Client.prototype.send = function (this: S3Client, command: unknown, options?: unknown) {
    const state = record(this);
    const signal = (options as { abortSignal?: AbortSignal })?.abortSignal;
    assert(signal instanceof AbortSignal, "Missing request abort signal");
    state.signals.push(signal);
    return Reflect.apply(originalSend, this, [command, options]);
  } as typeof originalSend;
  S3Client.prototype.destroy = function (this: S3Client) {
    const state = record(this);
    state.destroys++;
    state.events.push("destroy");
    originalDestroy.call(this);
  };
  try {
    await run(states, (next) => transport = next);
    for (const state of states) {
      equal(state.destroys, 1);
      equal(state.handlerDestroys, 1);
      equal(await state.client.config.maxAttempts(), 2);
      const retryMode = state.client.config.retryMode;
      equal(typeof retryMode === "function" ? await retryMode() : retryMode, "standard");
      equal(await state.client.config.region(), "auto");
      equal(await state.client.config.requestChecksumCalculation(), "WHEN_REQUIRED");
      equal(await state.client.config.responseChecksumValidation(), "WHEN_REQUIRED");
      equal(await state.client.config.useFipsEndpoint(), false);
      equal(await state.client.config.useDualstackEndpoint(), false);
    }
  } finally {
    Deno.env.get = originalGet;
    S3Client.prototype.send = originalSend;
    S3Client.prototype.destroy = originalDestroy;
    globalThis.fetch = originalFetch;
    // Test-failure cleanup only. Never mask a missing production destroy count.
    for (const state of states) if (state.destroys === 0) originalDestroy.call(state.client);
  }
}
function imageResponse(body: unknown, headers: Record<string, string> = {}): Response {
  return {
    response: {
      statusCode: 200,
      headers: { "content-length": "4", "content-type": "image/jpeg", ...headers },
      body,
    },
  };
}
function trackedStream(
  state: Lifecycle,
  chunks = [bytes],
  options: { cancel?: () => Promise<void>; hold?: Promise<void>; error?: boolean } = {},
) {
  let index = 0;
  return new ReadableStream<Uint8Array>({
    async pull(controller) {
      state.events.push("read");
      if (options.hold) await options.hold;
      assert(state.destroys === 0, "Client destroyed while stream is active");
      if (options.error) {
        state.events.push("stream-error");
        controller.error(new Error("Synthetic body failure"));
      } else if (index < chunks.length) {
        controller.enqueue(chunks[index++]);
      } else {
        state.events.push("stream-close");
        controller.close();
      }
    },
    async cancel() {
      state.events.push("cancel-start");
      assert(state.destroys === 0, "Client destroyed before cancellation");
      await options.cancel?.();
      assert(state.destroys === 0, "Client destroyed during cancellation");
      state.events.push("cancel-end");
    },
  }, { highWaterMark: 0 });
}
function errorResponse(statusCode = 403): Response {
  return {
    response: {
      statusCode,
      headers: { "content-type": "application/xml" },
      body: new TextEncoder().encode(
        `<Error><Code>${statusCode === 503 ? "SlowDown" : "AccessDenied"}</Code></Error>`,
      ),
    },
  };
}

Deno.test("R2 lifetime tests have no network, files, subprocess, sys or FFI access", async () => {
  for (const name of ["net", "read", "write", "run", "sys", "ffi"] as const) {
    assert(
      (await Deno.permissions.query({ name })).state !== "granted",
      "Unexpected permission grant",
    );
  }
  for (const variable of Object.keys(synthetic)) {
    assert(
      (await Deno.permissions.query({ name: "env", variable })).state !== "granted",
      "Real R2 environment access enabled",
    );
  }
});

Deno.test("R2 presigning destroys each own client after real signing without sending HTTP", async () => {
  await withStorage(async (states) => {
    const upload = new URL(await signUpload(key, bytes.length, "image/jpeg"));
    const read = new URL(await signRead(key));
    for (const url of [upload, read]) {
      assert(url.searchParams.has("X-Amz-Signature"), "No signature");
    }
    for (const header of ["if-none-match", "content-type", "content-length"]) {
      assert(
        upload.searchParams.get("X-Amz-SignedHeaders")?.split(";").includes(header),
        "Unbound header",
      );
    }
    equal(upload.searchParams.get("X-Amz-Expires"), "120");
    equal(read.searchParams.get("X-Amz-Expires"), "60");
    equal(states.length, 2);
    for (const state of states) equal(state.events, ["destroy", "handler-destroy"]);
  });
});

Deno.test("R2 signing failure and post-construction configuration failure destroy owned clients", async () => {
  await withStorage(async (states) => {
    // Actual pinned SDK signer rejects an expiry over its seven-day maximum.
    await rejects(signUpload(key, bytes.length, "image/jpeg", 604801));
    equal(states.length, 1);
  });
  for (const operation of [() => signRead(key), () => removePayloadAndFence(key)]) {
    let bucketReads = 0;
    await withStorage(async (states) => {
      await rejects(operation(), "service_not_configured");
      equal(states.length, 1);
      equal(states[0].events, ["destroy", "handler-destroy"]);
    }, (name) => name === "R2_BUCKET" && ++bucketReads > 1 ? undefined : synthetic[name]);
  }
});

Deno.test("R2 download keeps its client alive until real SDK body consumption finishes", async () => {
  await withStorage(async (states, setTransport) => {
    const started = latch(), held = latch();
    setTransport((_request, state) => {
      started.release();
      return Promise.resolve(imageResponse(trackedStream(state, [bytes], { hold: held.promise })));
    });
    const download = downloadImage(key, bytes.length);
    await started.promise;
    equal(states[0].destroys, 0);
    held.release();
    equal(Array.from(await download), Array.from(bytes));
    equal(states[0].events.slice(-3), ["stream-close", "destroy", "handler-destroy"]);
  });
});

Deno.test("R2 mismatched metadata and streamed overflow await cancellation before destroy", async () => {
  for (const mode of ["length", "type", "overflow"]) {
    await withStorage(async (states, setTransport) => {
      const cancelStarted = latch(), cancelFinished = latch();
      setTransport((_request, state) =>
        Promise.resolve(imageResponse(
          trackedStream(state, [mode === "overflow" ? new Uint8Array(5) : bytes], {
            cancel: async () => {
              cancelStarted.release();
              await cancelFinished.promise;
            },
          }),
          mode === "length"
            ? { "content-length": "3" }
            : mode === "type"
            ? { "content-type": "text/plain" }
            : {},
        ))
      );
      const download = rejects(downloadImage(key, bytes.length), "invalid_image");
      await cancelStarted.promise;
      equal(states[0].destroys, 0);
      cancelFinished.release();
      await download;
      equal(states[0].events.slice(-4), [
        "cancel-start",
        "cancel-end",
        "destroy",
        "handler-destroy",
      ]);
    });
  }
});

Deno.test("R2 truncated and failed SDK streams destroy after exhaustion or terminal error", async () => {
  for (const failure of [false, true]) {
    await withStorage(async (states, setTransport) => {
      setTransport((_request, state) =>
        Promise.resolve(imageResponse(
          trackedStream(state, [bytes.subarray(0, 3)], { error: failure }),
        ))
      );
      await rejects(downloadImage(key, bytes.length), failure ? undefined : "invalid_image");
      equal(states[0].events.slice(-3), [
        failure ? "stream-error" : "stream-close",
        "destroy",
        "handler-destroy",
      ]);
    });
  }
});

Deno.test("R2 SDK GET denial, missing body and transport failure always destroy", async () => {
  for (const mode of ["denied", "missing", "transport"]) {
    await withStorage(async (states, setTransport) => {
      setTransport(() =>
        mode === "transport"
          ? Promise.reject(new Error("Synthetic closed transport failure"))
          : Promise.resolve(mode === "denied" ? errorResponse() : imageResponse(undefined))
      );
      await rejects(downloadImage(key, bytes.length));
      equal(states.length, 1);
      equal(states[0].events, ["GET:transport", "destroy", "handler-destroy"]);
    });
  }
});

Deno.test("R2 SDK retry retains one client and destroys only after successful body completion", async () => {
  await withStorage(async (states, setTransport) => {
    let calls = 0;
    setTransport((_request, state) =>
      Promise.resolve(++calls === 1 ? errorResponse(503) : imageResponse(trackedStream(state)))
    );
    equal(Array.from(await downloadImage(key, bytes.length)), Array.from(bytes));
    equal(calls, 2);
    equal(states.length, 1);
    equal(states[0].events.slice(-3), ["stream-close", "destroy", "handler-destroy"]);
  });
});

Deno.test("R2 concurrent downloads own separate clients and never destroy another active stream", async () => {
  await withStorage(async (states, setTransport) => {
    const firstEntered = latch(), firstHeld = latch();
    let call = 0;
    setTransport((_request, state) => {
      const first = ++call === 1;
      if (first) firstEntered.release();
      return Promise.resolve(
        imageResponse(trackedStream(state, [bytes], first ? { hold: firstHeld.promise } : {})),
      );
    });
    const first = downloadImage(key, bytes.length);
    await firstEntered.promise;
    await downloadImage(key, bytes.length);
    equal(states.length, 2);
    equal(states[0].destroys, 0);
    equal(states[1].destroys, 1);
    firstHeld.release();
    await first;
    equal(states[0].destroys, 1);
  });
});

Deno.test("R2 fence owns one client through PUT and final HEAD including all failure paths", async () => {
  for (const mode of ["success", "put-denied", "head-denied", "bad-head"]) {
    await withStorage(async (states, setTransport) => {
      setTransport((request, state) => {
        assert(state.destroys === 0, "Fence client destroyed between commands");
        if (request.method === "PUT") {
          equal(request.headers["content-length"], "0");
          equal(request.headers["content-type"], "application/x-sudan-birds-tombstone");
          equal(request.headers["x-amz-meta-birds-tombstone"], "1");
          assert(request.body instanceof Uint8Array && request.body.length === 0, "Nonempty fence");
          return Promise.resolve(
            mode === "put-denied" ? errorResponse() : {
              response: { statusCode: 200, headers: {}, body: new Uint8Array() },
            },
          );
        }
        equal(request.method, "HEAD");
        return Promise.resolve(
          mode === "head-denied" ? errorResponse() : {
            response: {
              statusCode: 200,
              headers: {
                "content-length": "0",
                "x-amz-meta-birds-tombstone": mode === "bad-head" ? "0" : "1",
              },
              body: new Uint8Array(),
            },
          },
        );
      });
      if (mode === "success") equal(await removePayloadAndFence(key), true);
      else {await rejects(
          removePayloadAndFence(key),
          mode === "bad-head" ? "storage_cleanup_failed" : undefined,
        );}
      equal(states.length, 1);
      equal(states[0].events, [
        "PUT:transport",
        ...(mode === "put-denied" ? [] : ["HEAD:transport"]),
        "destroy",
        "handler-destroy",
      ]);
    });
  }
});

Deno.test("R2 signed write releases signing client before independent fetch and preserves create-only headers", async () => {
  await withStorage(async (states) => {
    globalThis.fetch = (_input, options) => {
      equal(states.length, 1);
      equal(states[0].destroys, 1);
      equal(options?.method, "PUT");
      equal(options?.redirect, "error");
      equal(options?.headers, {
        "Content-Type": "image/jpeg",
        "Content-Length": "4",
        "If-None-Match": "*",
      });
      assert(options?.signal instanceof AbortSignal, "Missing fetch timeout");
      return Promise.resolve(new Response(null, { status: 200 }));
    };
    await writeVerified(key, bytes, "2099-01-01T00:00:00Z");
    equal(states[0].events, ["destroy", "handler-destroy"]);
  });
});

Deno.test("R2 abort awaits delayed cancellation before destroy and preserves download timeout", async () => {
  const originalTimeout = AbortSignal.timeout;
  const controller = new AbortController();
  AbortSignal.timeout = (milliseconds) => {
    equal(milliseconds, 15_000);
    return controller.signal;
  };
  try {
    await withStorage(async (states, setTransport) => {
      const readStarted = latch(), cancelStarted = latch(), cancelFinished = latch();
      setTransport((_request, state) =>
        Promise.resolve(imageResponse(
          new ReadableStream<Uint8Array>({
            pull() {
              readStarted.release();
            },
            async cancel() {
              state.events.push("cancel-start");
              cancelStarted.release();
              await cancelFinished.promise;
              assert(state.destroys === 0, "Client destroyed during delayed abort cancellation");
              state.events.push("cancel-end");
            },
          }, { highWaterMark: 0 }),
        ))
      );
      const download = rejects(downloadImage(key, bytes.length), "image_download_timeout");
      await readStarted.promise;
      controller.abort();
      await cancelStarted.promise;
      // The pending read resolves as soon as cancellation starts; allow that
      // continuation to run while the underlying cancellation is still held.
      await new Promise((resolve) => setTimeout(resolve, 10));
      equal(states[0].destroys, 0);
      cancelFinished.release();
      await download;
      equal(states[0].events.slice(-4), [
        "cancel-start",
        "cancel-end",
        "destroy",
        "handler-destroy",
      ]);
    });
  } finally {
    AbortSignal.timeout = originalTimeout;
  }
});

Deno.test("R2 rejected cancellation preserves safe metadata overflow and timeout errors", async () => {
  for (const mode of ["metadata", "overflow", "abort"]) {
    const originalTimeout = AbortSignal.timeout;
    const controller = new AbortController();
    AbortSignal.timeout = (milliseconds) => {
      equal(milliseconds, 15_000);
      return controller.signal;
    };
    try {
      await withStorage(async (states, setTransport) => {
        const reading = latch();
        setTransport((_request, state) =>
          Promise.resolve(imageResponse(
            new ReadableStream<Uint8Array>({
              pull(c) {
                reading.release();
                if (mode === "overflow") c.enqueue(new Uint8Array(5));
              },
              cancel() {
                state.events.push("cancel-rejected");
                return Promise.reject(
                  new Error("Synthetic cancellation failure must not replace safe error"),
                );
              },
            }, { highWaterMark: 0 }),
            mode === "metadata" ? { "content-type": "text/plain" } : {},
          ))
        );
        const download = rejects(
          downloadImage(key, bytes.length),
          mode === "abort" ? "image_download_timeout" : "invalid_image",
        );
        if (mode === "abort") {
          await reading.promise;
          controller.abort();
        }
        await download;
        equal(states[0].events.slice(-3), ["cancel-rejected", "destroy", "handler-destroy"]);
      });
    } finally {
      AbortSignal.timeout = originalTimeout;
    }
  }
});

Deno.test("R2 never-settling cancellation has bounded grace then destroys only its owned transport", async () => {
  for (const mode of ["metadata", "overflow", "abort"]) {
    const originalTimeout = AbortSignal.timeout;
    const controller = new AbortController();
    AbortSignal.timeout = (milliseconds) => {
      equal(milliseconds, 15_000);
      return controller.signal;
    };
    try {
      await withStorage(async (states, setTransport) => {
        const reading = latch(), cancelling = latch();
        setTransport((_request, state) =>
          Promise.resolve(imageResponse(
            new ReadableStream<Uint8Array>({
              pull(c) {
                reading.release();
                if (mode === "overflow") c.enqueue(new Uint8Array(5));
              },
              cancel() {
                state.events.push("cancel-start");
                cancelling.release();
                return new Promise<void>(() => {});
              },
            }, { highWaterMark: 0 }),
            mode === "metadata" ? { "content-type": "text/plain" } : {},
          ))
        );
        const download = rejects(
          downloadImage(key, bytes.length),
          mode === "abort" ? "image_download_timeout" : "invalid_image",
        );
        if (mode === "abort") {
          await reading.promise;
          controller.abort();
        }
        await cancelling.promise;
        equal(states[0].destroys, 0);
        let watchdog: ReturnType<typeof setTimeout> | undefined;
        try {
          await Promise.race([
            download,
            new Promise<void>((_resolve, reject) =>
              watchdog = setTimeout(
                () => reject(new Error("Cancellation exceeded bounded grace")),
                5_000,
              )
            ),
          ]);
        } finally {
          clearTimeout(watchdog);
        }
        // Underlying cancellation did not settle. Only grace expiry and forced
        // transport destroy are claimed here, not real socket cancellation.
        equal(states[0].events.slice(-3), ["cancel-start", "destroy", "handler-destroy"]);
      });
    } finally {
      AbortSignal.timeout = originalTimeout;
    }
  }
});

Deno.test("R2 invalid expected size cancels received body before cleanup", async () => {
  await withStorage(async (states, setTransport) => {
    setTransport((_request, state) =>
      Promise.resolve(imageResponse(trackedStream(state), { "content-length": "0" }))
    );
    await rejects(downloadImage(key, 0), "invalid_image");
    equal(states[0].events, [
      "GET:transport",
      "cancel-start",
      "cancel-end",
      "destroy",
      "handler-destroy",
    ]);
  });
});

Deno.test("R2 final HEAD may stay pending without prematurely destroying fence client", async () => {
  await withStorage(async (states, setTransport) => {
    const headStarted = latch(), headFinished = latch();
    setTransport(async (request, state) => {
      if (request.method === "HEAD") {
        headStarted.release();
        await headFinished.promise;
        equal(state.destroys, 0);
      }
      return {
        response: {
          statusCode: 200,
          headers: { "content-length": "0", "x-amz-meta-birds-tombstone": "1" },
          body: new Uint8Array(),
        },
      };
    });
    const fence = removePayloadAndFence(key);
    await headStarted.promise;
    equal(states[0].destroys, 0);
    headFinished.release();
    equal(await fence, true);
    equal(states.length, 1);
    equal(states[0].events, ["PUT:transport", "HEAD:transport", "destroy", "handler-destroy"]);
  });
});

Deno.test("R2 consumes actual SDK Node Readable conversion before destroying its client", async () => {
  await withStorage(async (states, setTransport) => {
    setTransport((_request, state) =>
      Promise.resolve(imageResponse(
        new Readable({
          read() {
            equal(state.destroys, 0);
            this.push(bytes);
            this.push(null);
          },
        }),
      ))
    );
    equal(Array.from(await downloadImage(key, bytes.length)), Array.from(bytes));
    equal(states[0].events, ["GET:transport", "destroy", "handler-destroy"]);
  });
});

Deno.test("R2 SDK Node cancellation settlement does not imply its async destroy callback settled", async () => {
  await withStorage(async (states, setTransport) => {
    const cancelStarted = latch(), cancelFinished = latch(), callbackFinished = latch();
    setTransport((_request, state) =>
      Promise.resolve(imageResponse(
        new Readable({
          read() {},
          destroy(error, callback) {
            state.events.push("node-cancel-start");
            cancelStarted.release();
            void cancelFinished.promise.then(() => {
              state.events.push("node-cancel-end");
              callback(error);
              callbackFinished.release();
            });
          },
        }),
        { "content-type": "text/plain" },
      ))
    );
    const download = rejects(downloadImage(key, bytes.length), "invalid_image");
    await cancelStarted.promise;
    await download;
    // Pinned Deno's Readable.toWeb cancel resolves after calling destroy(),
    // before the Node source's asynchronous _destroy callback. The web consumer
    // is canceled and this operation's client is destroyed; underlying close is
    // not proven by either fact. No real socket exists in this fixture.
    equal(states[0].events, [
      "GET:transport",
      "node-cancel-start",
      "destroy",
      "handler-destroy",
    ]);
    cancelFinished.release();
    await callbackFinished.promise;
    equal(states[0].events.at(-1), "node-cancel-end");
  });
});

Deno.test("R2 canonical writer rejects invalid and too-short deadlines before client creation", async () => {
  for (const expiry of ["not-a-date", new Date(Date.now() - 1).toISOString()]) {
    await withStorage(async (states) => {
      await rejects(writeVerified(key, bytes, expiry), "upload_expired");
      equal(states.length, 0);
    });
  }
});

Deno.test("R2 delayed actual signer cannot start PUT past deadline and uses a fresh remaining timeout", async () => {
  const RealDate = Date;
  const originalTimeout = AbortSignal.timeout;
  try {
    for (
      const [remaining, delay, allowed, timeout] of [
        [5000, 1000, false, 0],
        [5000, 6000, false, 0],
        [3500, 200, true, 3300],
        [40000, 1000, true, 15000],
      ] as const
    ) {
      let now = RealDate.parse("2026-01-01T00:00:00.000Z");
      const deadline = now + remaining;
      globalThis.Date = class extends RealDate {
        constructor(value?: string | number) {
          super(value === undefined ? now : value);
        }
        static override now() {
          return now;
        }
      } as unknown as DateConstructor;
      const timeouts: number[] = [];
      AbortSignal.timeout = (ms) => {
        timeouts.push(ms);
        return new AbortController().signal;
      };
      let bucketReads = 0;
      let fetches = 0;
      await withStorage(async (states) => {
        globalThis.fetch = (input, init) => {
          fetches++;
          equal(init?.method, "PUT");
          equal(init?.redirect, "error");
          const url = new URL(String(input));
          const date = url.searchParams.get("X-Amz-Date")!;
          const signedAt = RealDate.parse(date.replace(
            /^(\d{4})(\d\d)(\d\d)T(\d\d)(\d\d)(\d\d)Z$/,
            "$1-$2-$3T$4:$5:$6.000Z",
          ));
          const ttl = Number(url.searchParams.get("X-Amz-Expires"));
          assert(signedAt + ttl * 1000 <= deadline, "Used signature exceeds deadline");
          assert(now < deadline, "PUT started after deadline");
          return Promise.resolve(new globalThis.Response(null, { status: 200 }));
        };
        const operation = writeVerified(key, bytes, new RealDate(deadline).toISOString());
        if (allowed) await operation;
        else await rejects(operation, "upload_expired");
        equal(fetches, allowed ? 1 : 0);
        equal(timeouts, allowed ? [timeout] : []);
        equal(states.length, 1);
        equal(states[0].destroys, 1);
      }, (name) => {
        // getSignedUrl awaits endpoint resolution after this configuration read.
        // Advance both wall clocks before actual SDK signingDate is selected.
        if (name === "R2_BUCKET" && ++bucketReads === 2) queueMicrotask(() => now += delay);
        return synthetic[name];
      });
    }
  } finally {
    globalThis.Date = RealDate;
    AbortSignal.timeout = originalTimeout;
  }
});

Deno.test("R2 signed PUT keeps confirmed HTTP outcomes when response cancellation rejects or hangs", async () => {
  for (const status of [200, 412, 503]) {
    for (const cleanup of ["reject", "hang"]) {
      await withStorage(async () => {
        let cancelled = false;
        globalThis.fetch = () =>
          Promise.resolve(
            new Response(
              new ReadableStream({
                cancel() {
                  cancelled = true;
                  return cleanup === "reject"
                    ? Promise.reject(new Error("SECRET_SIGNED_URL"))
                    : new Promise<void>(() => {});
                },
              }),
              { status },
            ),
          );
        const write = writeVerified(key, bytes, "2099-01-01T00:00:00Z");
        if (status === 200) await write;
        else await rejects(write, status === 412 ? "upload_conflict" : "image_storage_failed");
        assert(cancelled, "Response body was not cancelled");
      });
    }
  }
});

Deno.test("R2 client destruction failures do not replace original errors or confirmed signing", async () => {
  for (const failure of [false, true]) {
    await withStorage(async () => {
      const destroy = S3Client.prototype.destroy;
      S3Client.prototype.destroy = function () {
        destroy.call(this);
        throw new Error("SECRET_TRANSPORT_CONTEXT");
      };
      if (failure) await rejects(signUpload(key, bytes.length, "image/jpeg", 604801));
      else assert(new URL(await signRead(key)).searchParams.has("X-Amz-Signature"), "Signing lost");
    });
  }
});
