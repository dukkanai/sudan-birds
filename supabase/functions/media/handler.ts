import { ApiError, body, boundary, fields, json, uuid } from "../_shared/http.ts";
import { authenticated, serviceClient } from "../_shared/auth.ts";
import {
  downloadImage,
  removePayloadAndFence,
  signRead,
  signUpload,
  storageConfiguration,
  writeVerified,
} from "../_shared/r2.ts";
import { requireCodecCapacity, singleVerification } from "../_shared/codec_capacity.ts";
import { uploadInput } from "../_shared/upload_input.ts";
import { completeMedia } from "../_shared/media_service.ts";
// Pure JS decode is synchronous. Do not pretend a Promise timeout preempts it.
// One in-flight verification per isolate bounds retained buffers/SDK responses.
export function createMediaHandler(deps = {
  authenticated,
  serviceClient,
  signRead,
  signUpload,
  storageConfiguration,
  downloadImage,
  writeVerified,
  removePayloadAndFence,
  pipelineEnabled: () => Deno.env.get("MEDIA_PIPELINE_ENABLED") === "true",
  capacity: () => requireCodecCapacity(Deno.memoryUsage()),
}) {
  const verification = singleVerification();
  return boundary(async (req) => {
    const { client, user } = await deps.authenticated(req);
    const input = await body(req);
    if (
      typeof input.action !== "string" || !["read", "reserve", "complete"].includes(input.action)
    ) {
      throw new ApiError(400, "invalid_action");
    }
    if (input.action === "read") {
      fields(input, ["action", "media_id"]);
      const { data, error } = await client.from("media").select("object_key").eq(
        "id",
        uuid(input.media_id),
      ).maybeSingle();
      if (error || !data) throw new ApiError(404, "media_not_found");
      return json({ url: await deps.signRead(data.object_key), expires_in: 60 });
    }
    if (!deps.pipelineEnabled()) {
      throw new ApiError(503, "media_pipeline_unavailable");
    }
    if (input.action === "reserve") {
      const upload = uploadInput(input);
      deps.storageConfiguration();
      const { data, error } = await client.rpc("reserve_upload", upload);
      if (error || !data) throw new ApiError(403, "upload_denied");
      return json({
        intent_id: data.id,
        put_url: await deps.signUpload(data.object_key, data.expected_bytes, data.expected_mime),
        expires_in: 120,
        required_headers: {
          "Content-Type": data.expected_mime,
          "Content-Length": String(data.expected_bytes),
          "If-None-Match": "*",
        },
      });
    }
    if (input.action === "complete") {
      fields(input, ["action", "intent_id", "alt_text"]);
      const intent = uuid(input.intent_id);
      if (
        input.alt_text !== undefined &&
        (typeof input.alt_text !== "string" || input.alt_text.length > 500)
      ) {
        throw new ApiError(400, "invalid_alt_text");
      }
      return await verification(async () => {
        deps.capacity();
        deps.storageConfiguration();
        const service = deps.serviceClient();
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
            capacity: deps.capacity,
            download: deps.downloadImage,
            write: deps.writeVerified,
            remove: deps.removePayloadAndFence,
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
  });
}
