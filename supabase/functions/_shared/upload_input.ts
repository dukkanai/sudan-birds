import { ApiError, uuid } from "./http.ts";
import { IMAGE_LIMITS } from "./images.ts";

// A strict target contract makes obsolete clients fail closed rather than silently
// dropping a discontinued target or changing which content receives the upload.
export function uploadInput(input: Record<string, unknown>) {
  if (
    Object.keys(input).some((key) => !["action", "listing_id", "bytes", "mime"].includes(key)) ||
    typeof input.bytes !== "number" || !Number.isInteger(input.bytes) ||
    input.bytes < 1 || input.bytes > IMAGE_LIMITS.maxBytes || input.mime !== "image/jpeg"
  ) throw new ApiError(400, "invalid_upload");
  return { p_listing: uuid(input.listing_id), p_bytes: input.bytes, p_mime: input.mime };
}
