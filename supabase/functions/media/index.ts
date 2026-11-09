import { ApiError, body, boundary, json, uuid } from "../_shared/http.ts";
import { authenticated, requiredEnv, serviceClient } from "../_shared/auth.ts";
import {
  downloadImage,
  removePayloadAndFence,
  signRead,
  signUpload,
  writeVerified,
} from "../_shared/r2.ts";
import { requireCodecCapacity, singleVerification } from "../_shared/codec_capacity.ts";
import { uploadInput } from "../_shared/upload_input.ts";
import { completeMedia } from "../_shared/media_service.ts";
// Pure JS decode is synchronous. Do not pretend a Promise timeout preempts it.
// One in-flight verification per isolate bounds retained buffers/SDK responses.
const verification = singleVerification();
Deno.serve(boundary(async (req) => {
  const { client, user } = await authenticated(req);
  const input = await body(req);
  if (input.action === "read") {
    const { data, error } = await client.from("media").select("object_key").eq(
      "id",
      uuid(input.media_id),
    ).maybeSingle();
    if (error || !data) throw new ApiError(404, "media_not_found");
    return json({ url: await signRead(data.object_key), expires_in: 60 });
  }
  if (Deno.env.get("MEDIA_PIPELINE_ENABLED") !== "true") {
    throw new ApiError(503, "media_pipeline_unavailable");
  }
  if (input.action === "reserve") {
    requiredEnv("R2_ACCESS_KEY_ID");
    requiredEnv("R2_SECRET_ACCESS_KEY");
    requiredEnv("R2_BUCKET");
    const { data, error } = await client.rpc("reserve_upload", uploadInput(input));
    if (error || !data) throw new ApiError(403, "upload_denied");
    return json({
      intent_id: data.id,
      put_url: await signUpload(data.object_key, data.expected_bytes, data.expected_mime),
      expires_in: 120,
      required_headers: {
        "Content-Type": data.expected_mime,
        "Content-Length": String(data.expected_bytes),
        "If-None-Match": "*",
      },
    });
  }
  if (input.action === "complete") {
    const intent = uuid(input.intent_id);
    if (input.alt_text !== undefined && typeof input.alt_text !== "string") {
      throw new ApiError(400, "invalid_alt_text");
    }
    return await verification(async () => {
      requireCodecCapacity(Deno.memoryUsage());
      const service = serviceClient();
      return json(
        await completeMedia(user.id, intent, (input.alt_text as string | undefined) ?? "", {
          async prepare(owner, id) {
            const { data, error } = await service.rpc("prepare_media_verification", {
              p_owner: owner,
              p_intent: id,
            });
            if (error || !data?.[0]) throw new ApiError(409, "verification_denied");
            return data[0];
          },
          capacity: () => requireCodecCapacity(Deno.memoryUsage()),
          download: downloadImage,
          write: writeVerified,
          remove: removePayloadAndFence,
          async commit(owner, id, key, bytes, width, height, alt) {
            const { data, error } = await service.rpc("commit_verified_media", {
              p_owner: owner,
              p_intent: id,
              p_key: key,
              p_bytes: bytes,
              p_width: width,
              p_height: height,
              p_alt: alt,
            });
            if (error || !data?.[0]) throw new ApiError(409, "verification_pending_retry");
            return data[0];
          },
        }),
      );
    });
  }
  throw new ApiError(400, "invalid_action");
}));
