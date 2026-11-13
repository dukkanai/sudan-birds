/** Offline checks only. No HTTP service, Auth identities or external requests. */
import { syntheticJpeg, validateDestination } from "./media_http_local.ts";
import { sanitizeJpeg } from "../supabase/functions/_shared/images.ts";

Deno.test("routing rejects nonlocal, alternate ports, userinfo, fragments and unknown paths", () => {
  for (
    const value of [
      "https://example.supabase.co/auth/v1/user",
      "http://localhost:54321/auth/v1/user",
      "http://127.0.0.1:54322/auth/v1/user",
      "http://user@127.0.0.1:54321/auth/v1/user",
      "http://127.0.0.1:54321/auth/v1/user#fragment",
      "http://127.0.0.1:54321/unknown",
      "http://127.0.0.1:54321/auth/v1/admin/users/unknown",
      "http://127.0.0.1:54321/rest/v1/rpc/unknown",
    ]
  ) {
    let denied = false;
    try {
      validateDestination(value);
    } catch {
      denied = true;
    }
    if (!denied) throw new Error("Unexpected destination allowed");
  }
});
Deno.test("routing accepts only expected local Auth and RPC paths", () => {
  for (
    const path of [
      "/auth/v1/user",
      "/auth/v1/token?grant_type=password",
      "/auth/v1/admin/users",
      "/rest/v1/profiles",
      "/rest/v1/listings",
      "/rest/v1/media",
      "/rest/v1/user_blocks",
      "/rest/v1/rpc/reserve_upload",
      "/rest/v1/rpc/prepare_media_verification",
      "/rest/v1/rpc/commit_verified_media",
    ]
  ) validateDestination("http://127.0.0.1:54321" + path);
});
Deno.test("synthetic metadata fixture decodes to bounded canonical JPEG", () => {
  const input = syntheticJpeg();
  const output = sanitizeJpeg(input);
  const text = new TextDecoder();
  if (
    !text.decode(input).includes("SYNTHETIC_PRIVATE_METADATA") ||
    text.decode(output.bytes).includes("SYNTHETIC_PRIVATE_METADATA") ||
    output.width !== 16 || output.height !== 16 || output.bytes.length >= input.length
  ) {
    throw new Error("Invalid synthetic fixture or canonical output");
  }
});
