import { cancelStream, releaseStreamLock } from "./stream_cleanup.ts";
import { reportFailure } from "./diagnostics.ts";

export class ApiError extends Error {
  constructor(readonly status: number, readonly code: string) {
    super(code);
  }
}
export function json(body: unknown, status = 200): Response {
  return Response.json(body, {
    status,
    headers: {
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
    },
  });
}
// Only known error codes reach the caller. Never log headers, JWTs, contact data,
// signed URLs, SQL errors, arbitrary exception messages or environment secrets.
export function boundary(handler: (r: Request) => Promise<Response> | Response) {
  return async (req: Request): Promise<Response> => {
    const requestId = crypto.randomUUID();
    try {
      if (req.method !== "POST") throw new ApiError(405, "method_not_allowed");
      return await handler(req);
    } catch (error) {
      const status = error instanceof ApiError ? error.status : 500;
      const code = error instanceof ApiError ? error.code : "internal_error";
      if (status >= 500) reportFailure("request_failed", requestId);
      return json({ error: code, request_id: requestId }, status);
    }
  };
}
export async function body(req: Request): Promise<Record<string, unknown>> {
  if (
    req.headers.get("content-type")?.split(";", 1)[0].trim().toLowerCase() !== "application/json"
  ) {
    throw new ApiError(415, "json_required");
  }
  // Stream limit, not just a caller-supplied Content-Length.
  const reader = req.body?.getReader();
  if (!reader) throw new ApiError(400, "invalid_json");
  const chunks: Uint8Array[] = [];
  let size = 0;
  let timer: ReturnType<typeof setTimeout> | undefined;
  let cancellation: Promise<void> | undefined;
  // One total deadline, not a fresh allowance for each attacker-controlled chunk.
  const timeout = new Promise<never>((_resolve, reject) => {
    timer = setTimeout(() => {
      reject(new ApiError(408, "body_timeout"));
      cancellation ??= cancelStream(reader);
    }, 10_000);
  });
  try {
    while (true) {
      const next = await Promise.race([reader.read(), timeout]);
      if (next.done) break;
      size += next.value.byteLength;
      if (size > 8192) {
        cancellation ??= cancelStream(reader);
        await cancellation;
        throw new ApiError(413, "body_too_large");
      }
      chunks.push(next.value);
    }
    const bytes = new Uint8Array(size);
    let offset = 0;
    for (const chunk of chunks) {
      bytes.set(chunk, offset);
      offset += chunk.byteLength;
    }
    const value: unknown = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
    if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error();
    return value as Record<string, unknown>;
  } catch (error) {
    if (error instanceof ApiError) throw error;
    throw new ApiError(400, "invalid_json");
  } finally {
    clearTimeout(timer);
    await cancellation;
    releaseStreamLock(reader);
  }
}
export function uuid(value: unknown): string {
  if (
    typeof value !== "string" ||
    !/^[a-f\d]{8}-[a-f\d]{4}-[1-8][a-f\d]{3}-[89ab][a-f\d]{3}-[a-f\d]{12}$/i.test(value)
  ) {
    throw new ApiError(400, "invalid_id");
  }
  return value;
}

export function fields(input: Record<string, unknown>, allowed: readonly string[]): void {
  if (Object.keys(input).some((key) => !allowed.includes(key))) {
    throw new ApiError(400, "unknown_field");
  }
}
