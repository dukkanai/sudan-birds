import { createCodecDiagnostic } from "./handler.ts";
function assert(v: unknown): asserts v {
  if (!v) throw new Error("Assertion failed");
}
Deno.test("diagnostic is closed without a valid fixed short deadline", async () => {
  for (
    const value of [
      "invalid",
      new Date(0).toISOString(),
      new Date(Date.now() + 21 * 60000).toISOString(),
    ]
  ) {
    const response = await createCodecDiagnostic(value)(
      new Request("https://test.invalid", { method: "POST" }),
    );
    assert(response.status === 410);
  }
});
Deno.test("diagnostic rejects arbitrary images, bodies and query parameters", async () => {
  const token = "SYNTHETIC_ONLY_".padEnd(43, "x");
  const handler = createCodecDiagnostic(new Date(Date.now() + 60000).toISOString(), token);
  for (
    const req of [
      new Request("https://test.invalid/?input=x", {
        method: "POST",
        headers: { "x-codec-diagnostic-token": token },
      }),
      new Request("https://test.invalid", {
        method: "POST",
        body: "not accepted",
        headers: { "x-codec-diagnostic-token": token },
      }),
      new Request("https://test.invalid", { headers: { "x-codec-diagnostic-token": token } }),
    ]
  ) {
    assert((await handler(req)).status === 400);
  }
});
Deno.test("probe requires configured exact-length token and never echoes it", async () => {
  const expected = "SYNTHETIC_ONLY_".padEnd(43, "x");
  const expires = new Date(Date.now() + 60000).toISOString();
  for (
    const [configured, supplied] of [[undefined, expected], [expected, undefined], [
      expected,
      "wrong",
    ], [expected, "x".repeat(43)]]
  ) {
    const handler = createCodecDiagnostic(expires, configured);
    const response = await handler(
      new Request("https://test.invalid", {
        method: "POST",
        headers: supplied ? { "x-codec-diagnostic-token": supplied } : {},
      }),
    );
    const text = await response.text();
    assert(response.status === 403);
    assert(!text.includes(expected));
    assert(!text.includes("elapsed_ms"));
    assert(!text.includes("output_bytes"));
  }
});
