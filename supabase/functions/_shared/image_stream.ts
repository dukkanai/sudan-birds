import { ApiError } from "./http.ts";
import { cancelStream as cancelImageStream, releaseStreamLock } from "./stream_cleanup.ts";
export { cancelImageStream };
export async function readExactImageStream(
  stream: ReadableStream<Uint8Array>,
  expected: number,
  signal: AbortSignal,
): Promise<Uint8Array> {
  if (!Number.isInteger(expected) || expected < 1 || expected > 2_097_152) {
    await cancelImageStream(stream);
    throw new ApiError(400, "invalid_image");
  }
  const reader = stream.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  let cancellation: Promise<void> | undefined;
  const abort = () => {
    cancellation ??= cancelImageStream(reader);
  };
  signal.addEventListener("abort", abort, { once: true });
  try {
    if (signal.aborted) {
      abort();
      throw new ApiError(502, "image_download_timeout");
    }
    while (true) {
      const next = await reader.read();
      if (signal.aborted) throw new ApiError(502, "image_download_timeout");
      if (next.done) break;
      size += next.value.byteLength;
      if (size > expected || size > 2_097_152) {
        await cancelImageStream(reader);
        throw new ApiError(400, "invalid_image");
      }
      chunks.push(next.value);
    }
  } finally {
    signal.removeEventListener("abort", abort);
    await cancellation;
    releaseStreamLock(reader);
  }
  if (size !== expected) throw new ApiError(400, "invalid_image");
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.length;
  }
  return bytes;
}
