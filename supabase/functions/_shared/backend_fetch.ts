import { reportFailure } from "./diagnostics.ts";

// Shared by Auth and PostgREST, including privileged lifecycle requests. The
// abort signal stays attached while the SDK consumes the response body. Never
// retry mutations here: a lost/aborted response may follow a committed write.
export function backendFetch(fetcher: typeof fetch = globalThis.fetch): typeof fetch {
  return async (input, init) => {
    try {
      const supplied = init?.signal ?? (input instanceof Request ? input.signal : undefined);
      const timeout = AbortSignal.timeout(15_000);
      return await fetcher(input, {
        ...init,
        signal: supplied ? AbortSignal.any([supplied, timeout]) : timeout,
      });
    } catch {
      // Pinned Auth SDK logs raw fetch exceptions. Normalize before handing any
      // failure to that SDK, without retaining the original message or cause.
      reportFailure("upstream_transport_failed");
      return Response.json({ message: "upstream_unavailable" }, { status: 503 });
    }
  };
}
