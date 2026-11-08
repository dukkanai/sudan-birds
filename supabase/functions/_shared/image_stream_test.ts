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
