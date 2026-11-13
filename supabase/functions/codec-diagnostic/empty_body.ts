// Gateway POST requests may expose a zero-byte stream instead of a null body.
// Inspect at most eight chunks and wait at most 250ms. Never buffer user input.
export async function hasEmptyBody(req: Request): Promise<boolean> {
  if (req.body === null) return true;
  const reader = req.body.getReader();
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<false>((resolve) => {
    timer = setTimeout(() => resolve(false), 250);
  });
  try {
    const read = async (): Promise<boolean> => {
      for (let chunks = 0; chunks < 8; chunks++) {
        const next = await reader.read();
        if (next.value && next.value.byteLength !== 0) return false;
        if (next.done) return true;
      }
      return false;
    };
    return await Promise.race([read(), timeout]);
  } catch {
    return false;
  } finally {
    clearTimeout(timer);
    // A hostile stream's cancellation hook can hang. Do not await it.
    void reader.cancel().catch(() => {});
    try {
      reader.releaseLock();
    } catch {
      // A pending timed-out read is being cancelled; no error text is exposed.
    }
  }
}
