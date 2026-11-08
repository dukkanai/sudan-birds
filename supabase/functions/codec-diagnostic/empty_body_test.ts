import { hasEmptyBody } from "./empty_body.ts";
function assert(value: unknown): asserts value {
  if (!value) throw new Error("Assertion failed");
}
function request(body?: BodyInit): Request {
  return new Request("https://test.invalid", { method: "POST", body });
}
Deno.test("probe accepts null, empty-string and EOF stream bodies", async () => {
  assert(await hasEmptyBody(request()));
  assert(await hasEmptyBody(request("")));
  assert(
    await hasEmptyBody(request(
      new ReadableStream({
        start(c) {
          c.close();
        },
      }),
    )),
  );
});
Deno.test("probe rejects nonempty body regardless of declared length", async () => {
  const req = request("x");
  req.headers.set("content-length", "0");
  assert(!await hasEmptyBody(req));
});
Deno.test("probe bounds hanging read and hanging cancellation", async () => {
  let cancelled = false;
  const req = request(
    new ReadableStream({
      cancel() {
        cancelled = true;
        return new Promise(() => {});
      },
    }),
  );
  const start = performance.now();
  assert(!await hasEmptyBody(req));
  assert(cancelled && performance.now() - start < 2000);
});
Deno.test("probe rejects unbounded empty-chunk streams and read errors", async () => {
  let reads = 0;
  const req = request(
    new ReadableStream({
      pull(c) {
        reads++;
        c.enqueue(new Uint8Array(0));
      },
    }),
  );
  assert(!await hasEmptyBody(req));
  assert(reads <= 9); // Stream implementation may prefetch one chunk.
  assert(
    !await hasEmptyBody(request(
      new ReadableStream({
        start(c) {
          c.error(new Error("private error"));
        },
      }),
    )),
  );
});
