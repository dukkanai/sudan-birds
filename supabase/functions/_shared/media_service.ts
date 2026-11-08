import { ApiError } from "./http.ts";
import { sanitizeJpeg } from "./images.ts";
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
  remove(key: string): Promise<unknown>;
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
  if (claim.existing_media) return { media_id: claim.existing_media, status: "verified" };
  if (!claim.clean_key) throw new ApiError(409, "verification_unavailable");
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
  if (committed.published_key !== claim.clean_key) {
    // A definite losing output can be removed; failed cleanup remains registered
    // for an authorized lifecycle run. Never remove the winner or quarantine early.
    try {
      await deps.remove(claim.clean_key);
    } catch { /* Durable registry retains retry work. */ }
  }
  return { media_id: committed.media_id, status: "verified" };
}
