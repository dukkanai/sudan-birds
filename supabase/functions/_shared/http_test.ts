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
