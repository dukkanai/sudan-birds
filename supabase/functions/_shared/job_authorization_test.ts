import { authorizedJob } from "./job_authorization.ts";
function assert(v: unknown): asserts v {
  if (!v) throw new Error("Assertion failed");
}
Deno.test("scheduler authorization is absent by default and rejects wrong credentials", async () => {
  assert(await authorizedJob(null, undefined) === false);
  const synthetic = "synthetic_test_only_".repeat(3);
  assert(await authorizedJob(synthetic, synthetic));
  for (
    const [provided, configured] of [[synthetic, undefined], ["wrong", synthetic], [
      "x".repeat(300),
      synthetic,
    ], ["short", "short"]]
  ) {
    let failed = false;
    try {
      await authorizedJob(provided!, configured);
    } catch {
      failed = true;
    }
    assert(failed);
  }
});
