import { ApiError, boundary } from "./http.ts";
import { uploadInput } from "./upload_input.ts";
const listing = "00000000-0000-4000-8000-000000000001";
const valid = { action: "reserve", listing_id: listing, bytes: 100, mime: "image/jpeg" };
function assert(condition: unknown) {
  if (!condition) throw new Error("Assertion failed");
}
Deno.test("listing reservation emits only the new RPC arguments", () => {
  const args = uploadInput(valid);
  assert(
    JSON.stringify(args) === JSON.stringify({
      p_listing: listing,
      p_bytes: 100,
      p_mime: "image/jpeg",
    }),
  );
});
Deno.test("obsolete, missing, mixed and unknown targets fail closed", () => {
  for (
    const input of [
      { ...valid, post_id: listing },
      { ...valid, post_id: null },
      { action: "reserve", post_id: listing, bytes: 100, mime: "image/jpeg" },
      { ...valid, listing_id: null },
      { ...valid, listing_id: "bad" },
      { ...valid, target: listing },
    ]
  ) {
    let rejected = false;
    try {
      uploadInput(input);
    } catch (error) {
      rejected = error instanceof ApiError && error.status === 400;
    }
    assert(rejected);
  }
});
Deno.test("reservation rejects unsafe sizes and MIME values", () => {
  for (
    const input of [
      { ...valid, bytes: 0 },
      { ...valid, bytes: 2097153 },
      { ...valid, bytes: 1.5 },
      { ...valid, bytes: "100" },
      { ...valid, bytes: null },
      { ...valid, mime: "image/svg+xml" },
    ]
  ) {
    let rejected = false;
    try {
      uploadInput(input);
    } catch (error) {
      rejected = error instanceof ApiError && error.code === "invalid_upload";
    }
    assert(rejected);
  }
});
Deno.test("obsolete upload input returns safe bounded API error", async () => {
  const response = await boundary(() => {
    uploadInput({ ...valid, post_id: listing });
    return new Response();
  })(new Request("https://example.invalid", { method: "POST" }));
  assert(response.status === 400);
  const result = await response.json();
  assert(result.error === "invalid_upload" && typeof result.request_id === "string");
  assert(!JSON.stringify(result).includes(listing));
});
