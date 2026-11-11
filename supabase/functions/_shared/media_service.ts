import { ApiError, uuid } from "./http.ts";
import { sanitizeJpeg } from "./images.ts";
import { reportFailure } from "./diagnostics.ts";
export interface VerificationClaim {
  intent_id: string;
  source_key: string;
  expected_bytes: number;
  clean_key: string | null;
  existing_media: string | null;
  expires_at: string;
}
export interface MediaDependencies {
  capacity(): void;
  prepare(owner: string, intent: string): Promise<VerificationClaim>;
  download(key: string, bytes: number): Promise<Uint8Array>;
  write(key: string, bytes: Uint8Array, expires: string): Promise<void>;
  commit(
    owner: string,
    intent: string,
    key: string,
    bytes: number,
    width: number,
    height: number,
    alt: string,
  ): Promise<{ media_id: string; published_key: string }>;
  remove(key: string): Promise<boolean>;
}
// All network fallibility propagates to the outer safe boundary. A commit's
// uncertain outcome MUST NOT cause deletion of a possibly published winner.
export async function completeMedia(
  owner: string,
  intent: string,
  alt: string,
  deps: MediaDependencies,
) {
  if (alt.length > 500) throw new ApiError(400, "invalid_alt_text");
  const claim = await deps.prepare(owner, intent);
  if (claim?.existing_media) {
    try {
      uuid(claim.existing_media);
    } catch {
      throw new ApiError(502, "invalid_verification_response");
    }
    return { media_id: claim.existing_media, status: "verified" };
  }
  if (
    !claim || claim.intent_id !== intent ||
    typeof claim.source_key !== "string" || !claim.source_key ||
    !Number.isInteger(claim.expected_bytes) || claim.expected_bytes < 1 ||
    claim.expected_bytes > 2_097_152 || !Number.isFinite(Date.parse(claim.expires_at))
  ) throw new ApiError(502, "invalid_verification_response");
  if (!claim.clean_key) throw new ApiError(409, "verification_unavailable");
  if (typeof claim.clean_key !== "string" || claim.clean_key === claim.source_key) {
    throw new ApiError(502, "invalid_verification_response");
  }
  const bytes = await deps.download(claim.source_key, claim.expected_bytes);
  if (bytes.length !== claim.expected_bytes) throw new ApiError(400, "invalid_image");
  deps.capacity();
  const clean = sanitizeJpeg(bytes);
  await deps.write(claim.clean_key, clean.bytes, claim.expires_at);
  const committed = await deps.commit(
    owner,
    intent,
    claim.clean_key,
    clean.bytes.length,
    clean.width,
    clean.height,
    alt,
  );
  // HTTP success alone is not proof of the winning key. A malformed result may
  // arrive after a committed transaction; never fence the possibly published key.
  try {
    uuid(committed?.media_id);
    if (typeof committed.published_key !== "string" || !committed.published_key) throw new Error();
  } catch {
    throw new ApiError(409, "verification_pending_retry");
  }
  if (committed.published_key !== claim.clean_key) {
    // A definite losing output can be removed; failed cleanup remains registered
    // for an authorized lifecycle run. Never remove the winner or quarantine early.
    try {
      if (!await deps.remove(claim.clean_key)) reportFailure("media_loser_cleanup_pending");
    } catch {
      reportFailure("media_loser_cleanup_pending");
    }
  }
  return { media_id: committed.media_id, status: "verified" };
}
