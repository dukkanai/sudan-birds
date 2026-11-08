import { ApiError } from "./http.ts";
export function requireCodecCapacity(
  memory: Pick<ReturnType<typeof Deno.memoryUsage>, "rss" | "heapUsed" | "external">,
) {
  // RSS is process-wide and may include unrelated Edge isolates. Do not use it
  // as an absolute per-isolate gate. Preserve measured heap/external headroom;
  // the feature remains default-off until actual Edge resource tests pass.
  if (
    !Number.isFinite(memory.heapUsed) || !Number.isFinite(memory.external) ||
    memory.heapUsed > 96 * 1024 * 1024 || memory.external > 32 * 1024 * 1024 ||
    memory.heapUsed + memory.external > 112 * 1024 * 1024
  ) {
    throw new ApiError(503, "image_verifier_busy");
  }
}
export function singleVerification() {
  let busy = false;
  return async <T>(operation: () => Promise<T>): Promise<T> => {
    if (busy) throw new ApiError(429, "verification_busy");
    busy = true;
    try {
      return await operation();
    } finally {
      busy = false;
    }
  };
}
