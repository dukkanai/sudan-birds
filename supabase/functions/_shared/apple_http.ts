import { AppleError, type AppleErrorCode, record } from "./apple_errors.ts";

const urls = Object.freeze({
  validate: "https://appleid.apple.com/auth/token",
  revoke: "https://appleid.apple.com/auth/revoke",
  keys: "https://appleid.apple.com/auth/keys",
});
type Operation = keyof typeof urls;
export interface AppleDeadline {
  signal: AbortSignal;
  dispose(): void;
}
export interface AppleHttpDependencies {
  fetch: typeof fetch;
  deadline: () => AppleDeadline;
}

export function appleDeadline(): AppleDeadline {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 15_000);
  return { signal: controller.signal, dispose: () => clearTimeout(timer) };
}

function waitFor<T>(
  promise: Promise<T>,
  signal: AbortSignal,
  late?: (value: T) => void,
): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    let settled = false;
    const abort = () => {
      if (settled) return;
      settled = true;
      signal.removeEventListener("abort", abort);
      reject(new AppleError("apple_timeout"));
    };
    signal.addEventListener("abort", abort, { once: true });
    promise.then((value) => {
      if (settled) {
        try {
          late?.(value);
        } catch { /* A late response cannot replace the timeout. */ }
        return;
      }
      settled = true;
      signal.removeEventListener("abort", abort);
      resolve(value);
    }, (error) => {
      if (settled) return;
      settled = true;
      signal.removeEventListener("abort", abort);
      reject(error);
    });
    if (signal.aborted) abort();
  });
}

// Cleanup is best effort, bounded by not awaiting a potentially broken stream.
// A failed cancel/release/dispose never replaces the primary error or receipt.
function cancel(body: ReadableStream<Uint8Array> | null) {
  try {
    void body?.cancel().catch(() => {});
  } catch { /* Keep the original failure. */ }
}

export class AppleHttp {
  constructor(
    private readonly deps: AppleHttpDependencies = {
      fetch: globalThis.fetch,
      deadline: appleDeadline,
    },
  ) {}

  async request(operation: Operation, form?: URLSearchParams): Promise<Uint8Array> {
    const uncertain = operation === "revoke";
    let deadline: AppleDeadline | undefined;
    let response: Response | undefined;
    let reader: ReadableStreamDefaultReader<Uint8Array> | undefined;
    const chunks: Uint8Array[] = [];
    let began = false;
    try {
      if (!Object.hasOwn(urls, operation) || (operation === "keys" ? form !== undefined : !form)) {
        throw new AppleError("apple_input_invalid");
      }
      deadline = this.deps.deadline();
      if (deadline.signal.aborted) throw new AppleError("apple_timeout");
      began = true;
      response = await waitFor(
        this.deps.fetch(urls[operation], {
          method: operation === "keys" ? "GET" : "POST",
          headers: operation === "keys" ? { accept: "application/json" } : {
            "content-type": "application/x-www-form-urlencoded",
            accept: "application/json",
          },
          body: form?.toString(),
          redirect: "error",
          credentials: "omit",
          cache: "no-store",
          referrerPolicy: "no-referrer",
          signal: deadline.signal,
        }),
        deadline.signal,
        (late) => cancel(late.body),
      );
      if (
        response.redirected || (response.url !== "" && response.url !== urls[operation]) ||
        (response.status >= 300 && response.status < 400)
      ) throw new AppleError("apple_redirect_rejected", uncertain);
      if (response.status !== 200) {
        const code: AppleErrorCode = response.status >= 200 && response.status < 300
          ? "apple_response_invalid"
          : response.status === 429
          ? "apple_rate_limited"
          : response.status >= 500
          ? "apple_unavailable"
          : [401, 403].includes(response.status)
          ? "apple_configuration_required"
          : "apple_request_rejected";
        // An error response is not evidence of a successful revocation. A 5xx
        // can follow a server-side commit; callers must preserve the same grant.
        throw new AppleError(code, uncertain && (response.status >= 500 || response.status < 300));
      }
      const limit = operation === "revoke" ? 0 : 32_768;
      const length = response.headers.get("content-length");
      if (length !== null && (!/^\d+$/.test(length) || Number(length) > limit)) {
        throw new AppleError("apple_response_invalid", uncertain);
      }
      if (operation !== "revoke") {
        const mime = response.headers.get("content-type")?.split(";")[0].trim().toLowerCase();
        if (mime !== "application/json") throw new AppleError("apple_response_invalid");
      }
      let total = 0;
      let reads = 0;
      if (response.body) {
        reader = response.body.getReader();
        while (true) {
          // Empty/tiny microtask-only chunks could otherwise starve the timer.
          if (++reads > 1024) throw new AppleError("apple_response_invalid", uncertain);
          const next = await waitFor(reader.read(), deadline.signal);
          if (next.done) break;
          if (!(next.value instanceof Uint8Array) || total + next.value.length > limit) {
            throw new AppleError("apple_response_invalid", uncertain);
          }
          total += next.value.length;
          chunks.push(next.value);
        }
      }
      const result = new Uint8Array(total);
      let offset = 0;
      for (const chunk of chunks) {
        result.set(chunk, offset);
        offset += chunk.length;
      }
      return result;
    } catch (error) {
      if (error instanceof AppleError) {
        throw new AppleError(
          error.code,
          error.outcomeUnknown ||
            (uncertain && began && error.code === "apple_timeout"),
        );
      }
      throw new AppleError(
        deadline?.signal.aborted ? "apple_timeout" : "apple_transport_failed",
        uncertain && began,
      );
    } finally {
      for (const chunk of chunks) {
        try {
          chunk.fill(0);
        } catch { /* Preserve the primary result. */ }
      }
      if (reader) {
        try {
          void reader.cancel().catch(() => {});
        } catch { /* Keep the primary result. */ }
        try {
          reader.releaseLock();
        } catch { /* Keep the primary result. */ }
      } else if (response) cancel(response.body);
      try {
        deadline?.dispose();
      } catch { /* Keep the primary result. */ }
    }
  }

  async json(operation: "validate" | "keys", form?: URLSearchParams) {
    const bytes = await this.request(operation, form);
    try {
      const value: unknown = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
      if (!record(value)) throw new Error();
      return value;
    } catch {
      throw new AppleError("apple_response_invalid");
    } finally {
      try {
        bytes.fill(0);
      } catch { /* Preserve the primary result. */ }
    }
  }
}
