import { ApiError, body, boundary, fields, json, uuid } from "../_shared/http.ts";
import { authenticated } from "../_shared/auth.ts";
export function createContactHandler(deps = { authenticated }) {
  return boundary(async (req) => {
    const { client } = await deps.authenticated(req);
    const input = await body(req);
    fields(input, ["listing_id", "explicit_consent"]);
    if (input.explicit_consent !== true) throw new ApiError(403, "consent_required");
    const { data, error } = await client.rpc("reveal_listing_contact", {
      p_listing: uuid(input.listing_id),
      p_explicit_consent: true,
    });
    if (error) throw new ApiError(403, "contact_denied");
    if (!data?.length) throw new ApiError(404, "contact_unavailable");
    return json({ contact: data[0] });
  });
}
