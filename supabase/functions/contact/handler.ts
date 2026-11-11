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
    if (error?.code === "42501") throw new ApiError(403, "contact_denied");
    // A transport/database outage is not evidence that the caller is forbidden.
    // Keep failures closed and sanitized while preserving a retryable status.
    if (error) throw new ApiError(503, "contact_unavailable");
    if (data === null || (Array.isArray(data) && data.length === 0)) {
      throw new ApiError(404, "contact_unavailable");
    }
    const contact = Array.isArray(data) && data.length === 1 ? data[0] : null;
    if (
      !contact || !["phone", "whatsapp", "email"].includes(contact.contact_kind) ||
      typeof contact.contact_value !== "string" || !contact.contact_value
    ) throw new ApiError(502, "invalid_contact_response");
    // Return only the contract fields, never an unexpected backend field.
    return json({
      contact: { contact_kind: contact.contact_kind, contact_value: contact.contact_value },
    });
  });
}
