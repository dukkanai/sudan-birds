import { ApiError, body, boundary, json, uuid } from "../_shared/http.ts";
import { authenticated } from "../_shared/auth.ts";
Deno.serve(boundary(async (req) => {
  const { client } = await authenticated(req);
  const input = await body(req);
  if (input.explicit_consent !== true) throw new ApiError(403, "consent_required");
  const { data, error } = await client.rpc("reveal_listing_contact", {
    p_listing: uuid(input.listing_id),
    p_explicit_consent: true,
  });
  if (error) throw new ApiError(403, "contact_denied");
  if (!data?.length) throw new ApiError(404, "contact_unavailable");
  return json({ contact: data[0] });
}));
