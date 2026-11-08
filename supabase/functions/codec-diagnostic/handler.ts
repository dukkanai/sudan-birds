// Temporary fixed-data diagnostic ONLY. No auth helper, secrets, R2 or database.
import { sanitizeJpeg } from "../_shared/images.ts";
import { requireCodecCapacity, singleVerification } from "../_shared/codec_capacity.ts";
import { json } from "../_shared/http.ts";
import { allowedProbeToken } from "./authorization.ts";
import { fixtureBase64 } from "./fixture.ts";
export function createCodecDiagnostic(fixedUtcDeadline: string, expectedToken?: string) {
  const expires = Date.parse(fixedUtcDeadline);
  const started = Date.now();
  // A deployment MUST embed a literal fresh UTC deadline, not Date.now()+...,
  // otherwise a newly started isolate would extend the diagnostic lifetime.
  const valid = Number.isFinite(expires) && expires > started &&
    expires - started <= 20 * 60 * 1000;
  let bytes: Uint8Array | undefined;
  const lease = singleVerification();
  let calls = 0;
  return async (req: Request): Promise<Response> => {
    try {
      if (!valid || Date.now() >= expires) return json({ error: "diagnostic_expired" }, 410);
      if (!await allowedProbeToken(req.headers.get("x-codec-diagnostic-token"), expectedToken)) {
        return json({ error: "diagnostic_unauthorized" }, 403);
      }
      if (req.method !== "POST" || new URL(req.url).search !== "" || req.body !== null) {
        await req.body?.cancel();
        return json({ error: "empty_post_required" }, 400);
      }
      if (calls >= 20) return json({ error: "diagnostic_limit" }, 429);
      return await lease(async () => {
        if (Date.now() >= expires) return json({ error: "diagnostic_expired" }, 410);
        calls++;
        bytes ??= Uint8Array.from(atob(fixtureBase64), (c) => c.charCodeAt(0));
        const before = Deno.memoryUsage();
        requireCodecCapacity(before);
        const time = performance.now();
        const clean = sanitizeJpeg(bytes);
        const elapsed = performance.now() - time;
        // Let the event loop turn once after encoding; no forced GC or request loops.
        await Promise.resolve();
        return json({
          calls,
          expires_at: new Date(expires).toISOString(),
          elapsed_ms: Math.round(elapsed),
          before,
          after: Deno.memoryUsage(),
          width: clean.width,
          height: clean.height,
          output_bytes: clean.bytes.length,
        });
      });
    } catch {
      // No exception text, environment, request body, image bytes or URLs returned.
      return json({ error: "diagnostic_unavailable", calls, memory: Deno.memoryUsage() }, 503);
    }
  };
}
