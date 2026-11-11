import { ApiError, body, boundary, uuid } from "./http.ts";
function assert(value: unknown): asserts value {
  if (!value) throw new Error("Assertion failed");
}
Deno.test("boundary catches unknown errors without leaking secrets", async () => {
  const response = await boundary(() => {
    throw new Error("SECRET_JWT_AND_CONTACT");
  })(new Request("https://test.invalid", { method: "POST" }));
  const text = await response.text();
  assert(response.status === 500);
  assert(!text.includes("SECRET"));
  assert(text.includes("internal_error"));
});
Deno.test("boundary returns safe recognized errors", async () => {
  const response = await boundary(() => {
    throw new ApiError(403, "denied");
  })(new Request("https://test.invalid", { method: "POST" }));
  assert(response.status === 403);
  assert((await response.json()).error === "denied");
});
Deno.test("boundary rejects unsafe method", async () => {
  const response = await boundary(() => new Response("unreachable"))(
    new Request("https://test.invalid"),
  );
  assert(response.status === 405);
});
Deno.test("JSON accepts object and rejects arrays, malformed data, and excess bytes", async () => {
  const make = (text: string) =>
    new Request("https://test.invalid", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: text,
    });
  assert((await body(make('{"ok":true}'))).ok === true);
  for (const text of ["[]", "null", "{", "x".repeat(8193)]) {
    let failed = false;
    try {
      await body(make(text));
    } catch (e) {
      failed = e instanceof ApiError;
    }
    assert(failed);
  }
});
Deno.test("IDs cannot be substituted with paths or keys", () => {
  assert(uuid("00000000-0000-4000-8000-000000000001").length === 36);
  for (const value of ["../../private/key", null, "", 42]) {
    let failed = false;
    try {
      uuid(value);
    } catch (e) {
      failed = e instanceof ApiError;
    }
    assert(failed);
  }
});

Deno.test("JSON stalled reads return a bounded timeout even when cancellation never settles", async () => {
  const originalTimer = globalThis.setTimeout;
  const delays: number[] = [];
  globalThis.setTimeout = ((callback: (...args: unknown[]) => void, delay?: number) => {
    delays.push(delay ?? 0);
    return originalTimer(callback, delay === 10_000 || delay === 1_000 ? 10 : delay);
  }) as typeof setTimeout;
  let cancelled = false;
  const stream = new ReadableStream<Uint8Array>({
    cancel() {
      cancelled = true;
      return new Promise<void>(() => {});
    },
  });
  try {
    const response = await boundary(async (req) => {
      await body(req);
      throw new Error("Must not reach handler work");
    })(
      new Request("https://test.invalid", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: stream,
      }),
    );
    assert(response.status === 408 && (await response.json()).error === "body_timeout");
    assert(cancelled && !stream.locked);
    assert(delays.includes(10_000) && delays.includes(1_000));
  } finally {
    globalThis.setTimeout = originalTimer;
  }
});

Deno.test("JSON oversized body keeps its original error when cancellation hangs", async () => {
  const stream = new ReadableStream<Uint8Array>({
    start(controller) {
      controller.enqueue(new Uint8Array(8193));
    },
    cancel() {
      return new Promise<void>(() => {});
    },
  });
  const response = await boundary(async (req) => {
    await body(req);
    return new Response("unexpected");
  })(
    new Request("https://test.invalid", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: stream,
    }),
  );
  assert(response.status === 413 && (await response.json()).error === "body_too_large");
  assert(!stream.locked);
});

Deno.test("server failure diagnostics contain only fixed event and correlation id", async () => {
  const original = console.error;
  const logs: string[] = [];
  console.error = (value) => logs.push(String(value));
  try {
    const response = await boundary(() => {
      throw new Error("SECRET_JWT_CONTACT_URL");
    })(new Request("https://test.invalid", { method: "POST" }));
    const result = await response.json();
    assert(logs.length === 1);
    assert(logs[0] === JSON.stringify({ event: "request_failed", request_id: result.request_id }));
    console.error = () => {
      throw new Error("Broken log sink");
    };
    const safe = await boundary(() => {
      throw new Error("SECRET");
    })(
      new Request("https://test.invalid", { method: "POST" }),
    );
    assert(safe.status === 500 && (await safe.json()).error === "internal_error");
  } finally {
    console.error = original;
  }
});

Deno.test("JSON lock-release failure cannot replace success validation or byte-limit results", async () => {
  const original = ReadableStreamDefaultReader.prototype.releaseLock;
  const originalLog = console.error;
  const logs: unknown[] = [];
  console.error = (value) => logs.push(value);
  ReadableStreamDefaultReader.prototype.releaseLock = function () {
    original.call(this);
    throw new Error("SECRET_STREAM_CONTEXT");
  };
  try {
    for (
      const [raw, status, code] of [
        ['{"ok":true}', 200, undefined],
        ["{", 400, "invalid_json"],
        ["x".repeat(8193), 413, "body_too_large"],
      ] as const
    ) {
      const response = await boundary(async (req) => Response.json(await body(req)))(
        new Request("https://test.invalid", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: raw,
        }),
      );
      assert(response.status === status);
      const result = await response.json();
      assert(code ? result.error === code : result.ok === true);
    }
    assert(logs.length === 3 && logs.every((log) => log === '{"event":"stream_cleanup_failed"}'));
  } finally {
    ReadableStreamDefaultReader.prototype.releaseLock = original;
    console.error = originalLog;
  }
});
