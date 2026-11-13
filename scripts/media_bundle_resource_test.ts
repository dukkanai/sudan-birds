import {
  capacityBoundaryCases,
  DEPENDENCY_PINS,
  EXPECTED_DENO,
  MAX_REQUESTS,
  MAX_SAMPLES,
  requireOptIn,
} from "./media_bundle_resource.ts";
import { requireCodecCapacity } from "../supabase/functions/_shared/codec_capacity.ts";
import { ApiError } from "../supabase/functions/_shared/http.ts";

function assert(value: unknown): asserts value {
  if (!value) throw new Error("Assertion failed");
}

Deno.test("media experiment requires explicit local flag and a closed scenario allowlist", () => {
  for (const scenario of ["sequential", "sequential-paced", "burst", "boundaries"]) {
    assert(requireOptIn(["--run-local", scenario], EXPECTED_DENO) === scenario);
  }
  for (
    const args of [[], ["--run-local"], ["sequential"], ["--run-local", "https://example.com"], [
      "--run-local",
      "sequential",
      "extra",
    ], ["--run-hosted", "sequential"]]
  ) {
    let failed = false;
    try {
      requireOptIn(args, EXPECTED_DENO);
    } catch {
      failed = true;
    }
    assert(failed);
  }
});

Deno.test("media experiment fails closed on runtime version drift", () => {
  for (const version of ["2.5.5", "2.5.7", "2.6.0", "", "2.5.6-rc1"]) {
    let failed = false;
    try {
      requireOptIn(["--run-local", "sequential"], version);
    } catch {
      failed = true;
    }
    assert(failed);
  }
});

Deno.test("media experiment retains reviewed package pins and finite workload bounds", () => {
  assert(EXPECTED_DENO === "2.5.6");
  assert(DEPENDENCY_PINS.supabase === "2.57.4");
  assert(DEPENDENCY_PINS.s3 === "3.1164.0" && DEPENDENCY_PINS.presigner === "3.1164.0");
  assert(DEPENDENCY_PINS.jpeg === "0.4.4");
  assert(MAX_REQUESTS === 64 && MAX_SAMPLES === 768);
});

Deno.test("media experiment checks exact memory thresholds and specific safe denial", () => {
  const cases = capacityBoundaryCases();
  assert(cases.length === 8);
  for (const { heapUsed, external, allowed } of cases) {
    let error: unknown;
    try {
      // Process RSS deliberately does not substitute for an isolate counter.
      requireCodecCapacity({ rss: 999 * 1024 * 1024, heapUsed, external });
    } catch (caught) {
      error = caught;
    }
    if (allowed) assert(error === undefined);
    else {assert(
        error instanceof ApiError && error.status === 503 && error.code === "image_verifier_busy",
      );}
  }
});
