import { ApiError, body, boundary, json, uuid } from "../_shared/http.ts";
import { authenticated, requiredEnv } from "../_shared/auth.ts";
import { signRead, signUpload } from "../_shared/r2.ts";
Deno.serve(boundary(async (req) => {
  const { client } = await authenticated(req);
  const input = await body(req);
  if (input.action === "reserve") {
    // Remains OFF until a real isolated decode/reencode verifier + cleanup worker
    // is deployed and tested. Merely configuring R2 does not enable uploads.
    if (Deno.env.get("MEDIA_PIPELINE_ENABLED") !== "true") {
      throw new ApiError(503, "media_pipeline_unavailable");
    }
    requiredEnv("R2_ACCESS_KEY_ID");
    requiredEnv("R2_SECRET_ACCESS_KEY");
    requiredEnv("R2_BUCKET");
    const post = input.post_id == null ? null : uuid(input.post_id);
    const listing = input.listing_id == null ? null : uuid(input.listing_id);
    if (
      (post === null) === (listing === null) || !Number.isInteger(input.bytes) ||
      typeof input.bytes !== "number" || input.bytes < 1 || input.bytes > 5242880 ||
      !["image/jpeg", "image/png", "image/webp"].includes(String(input.mime))
    ) throw new ApiError(400, "invalid_upload");
    const { data, error } = await client.rpc("reserve_upload", {
      p_post: post,
      p_listing: listing,
      p_bytes: input.bytes,
      p_mime: input.mime,
    });
    if (error || !data) throw new ApiError(403, "upload_denied");
    const url = await signUpload(data.object_key, data.expected_bytes, data.expected_mime);
    return json({
      intent_id: data.id,
      put_url: url,
      expires_in: 120,
      required_headers: {
        "Content-Type": data.expected_mime,
        "Content-Length": String(data.expected_bytes),
      },
    });
  }
  if (input.action === "read") {
    const id = uuid(input.media_id);
    const { data, error } = await client.from("media").select("object_key").eq("id", id)
      .maybeSingle();
    if (error || !data) throw new ApiError(404, "media_not_found");
    return json({ url: await signRead(data.object_key), expires_in: 60 });
  }
  if (input.action === "complete") {
    // Do NOT trust Content-Type, HEAD, client dimensions or a magic-byte-only test.
    // No public write can mark media verified. No fabricated success response.
    throw new ApiError(503, "media_verifier_not_deployed");
  }
  throw new ApiError(400, "invalid_action");
}));
