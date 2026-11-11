import { readExactImageStream } from "./image_stream.ts";
function assert(v: unknown): asserts v {
  if (!v) throw new Error("Assertion failed");
}
const stream = (chunks: Uint8Array[]) =>
  new ReadableStream<Uint8Array>({
    start(c) {
      for (const chunk of chunks) c.enqueue(chunk);
      c.close();
    },
  });
Deno.test("image download checks actual stream length, not Content-Length", async () => {
  const result = await readExactImageStream(
    stream([new Uint8Array(2), new Uint8Array(2)]),
    4,
    new AbortController().signal,
  );
  assert(result.length === 4);
  for (const chunks of [[new Uint8Array(5)], [new Uint8Array(3)], []]) {
    let failed = false;
    try {
      await readExactImageStream(stream(chunks), 4, new AbortController().signal);
    } catch {
      failed = true;
    }
    assert(failed);
  }
});
Deno.test("hanging image download can be cancelled without publishing partial bytes", async () => {
  const controller = new AbortController();
  const waiting = new ReadableStream<Uint8Array>({
    start(c) {
      c.enqueue(new Uint8Array(1));
    },
  });
  const promise = readExactImageStream(waiting, 1, controller.signal);
  controller.abort();
  let failed = false;
  try {
    await promise;
  } catch {
    failed = true;
  }
  assert(failed);
});

Deno.test("stream cancellation catches synchronous throws without leaking the cleanup exception", async () => {
  const { cancelImageStream } = await import("./image_stream.ts");
  const original = console.error;
  const logs: unknown[] = [];
  console.error = (value) => logs.push(value);
  try {
    await cancelImageStream({
      cancel() {
        throw new Error("SECRET_URL");
      },
    });
    assert(JSON.stringify(logs) === JSON.stringify(['{"event":"stream_cleanup_failed"}']));
  } finally {
    console.error = original;
  }
});

Deno.test("image stream lock-release errors preserve exact bytes and original length failures", async () => {
  const original = ReadableStreamDefaultReader.prototype.releaseLock;
  ReadableStreamDefaultReader.prototype.releaseLock = function () {
    original.call(this);
    throw new Error("SECRET_STREAM_CONTEXT");
  };
  try {
    assert(
      (await readExactImageStream(stream([new Uint8Array(4)]), 4, new AbortController().signal))
        .length === 4,
    );
    let code;
    try {
      await readExactImageStream(stream([new Uint8Array(5)]), 4, new AbortController().signal);
    } catch (error) {
      code = (error as { code?: string }).code;
    }
    assert(code === "invalid_image");
  } finally {
    ReadableStreamDefaultReader.prototype.releaseLock = original;
  }
});

Deno.test("unexpected cancellation scheduling failure stays contained", async () => {
  const { cancelImageStream } = await import("./image_stream.ts");
  const original = globalThis.setTimeout;
  globalThis.setTimeout = (() => {
    throw new Error("SECRET_TIMER_CONTEXT");
  }) as typeof setTimeout;
  try {
    await cancelImageStream({ cancel: () => Promise.resolve() });
  } finally {
    globalThis.setTimeout = original;
  }
});
