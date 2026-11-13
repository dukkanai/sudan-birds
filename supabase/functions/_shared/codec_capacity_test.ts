import { requireCodecCapacity, singleVerification } from "./codec_capacity.ts";
function assert(v: unknown): asserts v {
  if (!v) throw new Error("Assertion failed");
}
Deno.test("codec memory admission fails closed with retained buffers or nonfinite metrics", () => {
  requireCodecCapacity({ rss: 64e6, heapUsed: 20e6, external: 2e6 });
  for (
    const values of [
      { rss: 1, heapUsed: 120e6, external: 1 },
      { rss: 1, heapUsed: 120e6, external: 1 },
      { rss: 1, heapUsed: 1, external: 40e6 },
      { rss: 1, heapUsed: NaN, external: 1 },
    ]
  ) {
    let failed = false;
    try {
      requireCodecCapacity(values);
    } catch {
      failed = true;
    }
    assert(failed);
  }
});
Deno.test("burst admits one verification and releases lease after errors", async () => {
  const lease = singleVerification();
  let release: () => void = () => {};
  const waiting = new Promise<void>((resolve) => {
    release = resolve;
  });
  const first = lease(() => waiting);
  const burst = await Promise.allSettled(
    Array.from({ length: 19 }, () => lease(() => Promise.resolve())),
  );
  assert(burst.every((r) => r.status === "rejected"));
  release();
  await first;
  try {
    await lease(() => Promise.reject(new Error("Synthetic failure")));
  } catch { /* expected */ }
  assert(await lease(() => Promise.resolve(true)));
});
