// Fixed event names only: never accept exceptions, payloads, keys, identities,
// contacts, credentials or URLs. Logging itself must not change an operation's result.
type FailureEvent =
  | "request_failed"
  | "upstream_transport_failed"
  | "stream_cleanup_failed"
  | "stream_cleanup_timeout"
  | "storage_client_cleanup_failed"
  | "media_loser_cleanup_pending"
  | "deletion_failure_record_pending";

export function reportFailure(event: FailureEvent, requestId?: string): void {
  try {
    console.error(JSON.stringify({ event, ...(requestId ? { request_id: requestId } : {}) }));
  } catch { /* A failed log sink cannot replace the original result. */ }
}
