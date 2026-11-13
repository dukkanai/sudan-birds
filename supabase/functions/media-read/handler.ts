import { publicReadClient } from "../_shared/auth.ts";
import { ApiError, body, boundary, fields, json, uuid } from "../_shared/http.ts";
import { signRead } from "../_shared/r2.ts";
// Gateway JWT check is intentionally off for this read-only public endpoint.
// Real user tokens are still validated by Auth.getUser and retain block-aware RLS.
export function createMediaReadHandler(deps = { publicReadClient, signRead }) {
  return boundary(async (req) => {
    const client = await deps.publicReadClient(req);
    const input = await body(req);
    fields(input, ["media_id"]);
    const { data, error } = await client.from("media").select("object_key").eq(
      "id",
      uuid(input.media_id),
    ).maybeSingle();
    if (error || !data) throw new ApiError(404, "media_not_found");
    return json({ url: await deps.signRead(data.object_key), expires_in: 60 });
  });
}
