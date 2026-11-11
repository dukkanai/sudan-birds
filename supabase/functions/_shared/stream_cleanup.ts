import { reportFailure } from "./diagnostics.ts";

// Resolution means cancellation settled OR its grace elapsed, not proof that
// transport cleanup finished. The operation owner may then destroy its client.
export async function cancelStream(source: { cancel(): Promise<void> }): Promise<void> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    await Promise.race([
      // Promise callback also captures synchronous cancellation throws.
      Promise.resolve().then(() => source.cancel()).catch(() => {
        reportFailure("stream_cleanup_failed");
      }),
      new Promise<void>((resolve) => {
        timer = setTimeout(() => {
          reportFailure("stream_cleanup_timeout");
          resolve();
        }, 1_000);
      }),
    ]);
  } catch {
    reportFailure("stream_cleanup_failed");
  } finally {
    try {
      clearTimeout(timer);
    } catch {
      reportFailure("stream_cleanup_failed");
    }
  }
}

export function releaseStreamLock(reader: { releaseLock(): void }): void {
  try {
    reader.releaseLock();
  } catch {
    reportFailure("stream_cleanup_failed");
  }
}
