// Local test only; does not establish actual Supabase Edge CPU/memory behavior.
// Generate a noisy synthetic640x640 JPEG in a SEPARATE process, then:
// deno run --allow-read=/tmp/test.jpg --node-modules-dir=manual _shared/image_benchmark.ts /tmp/test.jpg
import { sanitizeJpeg } from "./images.ts";
import { requireCodecCapacity, singleVerification } from "./codec_capacity.ts";
if (!Deno.args[0]) throw new Error("Pass a synthetic640x640 JPEG path");
const sample = await Deno.readFile(Deno.args[0]);
const initial = Deno.memoryUsage();
const timings: number[] = [];
const snapshots = [];
let declined = 0;
for (let i = 0; i < 20; i++) {
  try {
    requireCodecCapacity(Deno.memoryUsage());
    const start = performance.now();
    const result = sanitizeJpeg(sample);
    timings.push(Math.round(performance.now() - start));
    if (result.width > 640 || result.height > 640) throw new Error("Invalid output");
  } catch {
    declined++;
  }
  snapshots.push(Deno.memoryUsage());
  await new Promise((resolve) => setTimeout(resolve, 5));
}
const lease = singleVerification();
let release: () => void = () => {};
const waiting = new Promise<void>((r) => {
  release = r;
});
const first = lease(() => waiting);
const burst = await Promise.allSettled(
  Array.from({ length: 19 }, () => lease(() => Promise.resolve())),
);
release();
await first;
console.log(JSON.stringify({
  runtime: Deno.version.deno,
  pixels: 409600,
  input_bytes: sample.length,
  initial,
  elapsed_ms: timings,
  declined,
  memory_samples: snapshots,
  burst_admitted: 1 + burst.filter((r) => r.status === "fulfilled").length,
  warning: "Local process only; real Edge admission/CPU/memory and availability remain unverified",
}));
