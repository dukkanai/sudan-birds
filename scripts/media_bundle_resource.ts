/**
 * Opt-in LOCAL ordinary-Deno experiment. Never deploy or expose as a server.
 * Actual media handler / AWS / Supabase / codec imports, synthetic SDK transport
 * and storage only. No hosted endpoints, credentials, sockets, or user images.
 */
export const MAX_REQUESTS = 64;
export const MAX_SAMPLES = 768;
export const EXPECTED_DENO = "2.5.6";
export const DEPENDENCY_PINS = {
  supabase: "2.57.4",
  s3: "3.1164.0",
  presigner: "3.1164.0",
  jpeg: "0.4.4",
} as const;

export type Scenario = "sequential" | "sequential-paced" | "burst" | "boundaries";
class ExperimentAssertion extends Error {}

export function requireOptIn(args: string[], version: string): Scenario {
  if (
    args.length !== 2 || args[0] !== "--run-local" ||
    !["sequential", "sequential-paced", "burst", "boundaries"].includes(args[1]) ||
    version !== EXPECTED_DENO
  ) {
    throw new ExperimentAssertion(
      "Use pinned Deno 2.5.6 and --run-local sequential|sequential-paced|burst|boundaries",
    );
  }
  return args[1] as Scenario;
}
let partial: Record<string, unknown> | undefined;

export function capacityBoundaryCases() {
  const mib = 1024 * 1024;
  return [
    { name: "heap_exact", heapUsed: 96 * mib, external: 0, allowed: true },
    { name: "heap_over", heapUsed: 96 * mib + 1, external: 0, allowed: false },
    { name: "external_exact", heapUsed: 0, external: 32 * mib, allowed: true },
    { name: "external_over", heapUsed: 0, external: 32 * mib + 1, allowed: false },
    { name: "combined_exact", heapUsed: 80 * mib, external: 32 * mib, allowed: true },
    { name: "combined_over", heapUsed: 80 * mib + 1, external: 32 * mib, allowed: false },
    { name: "nan_heap", heapUsed: NaN, external: 0, allowed: false },
    { name: "infinite_external", heapUsed: 0, external: Infinity, allowed: false },
  ];
}

function assert(value: unknown, message: string): asserts value {
  if (!value) throw new ExperimentAssertion(message);
}

export async function runLocalExperiment() {
  const scenario = requireOptIn(Deno.args, Deno.version.deno);
  const started = performance.now();
  const deadline = started + 90_000;
  const pause = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));
  const transportTurn = () => scenario === "sequential-paced" ? pause(5) : Promise.resolve();
  const samples: Array<{ phase: string; rss: number; heapUsed: number; external: number }> = [];
  partial = { scenario, samples };
  const sample = (phase: string) => {
    assert(samples.length < MAX_SAMPLES, "sample bound exceeded");
    const { rss, heapUsed, external } = Deno.memoryUsage();
    const value = { phase, rss, heapUsed, external };
    samples.push(value);
    return value;
  };
  // Defense in depth: the launcher grants no network permission. Any accidental
  // global fetch also fails before it can reach DNS, HTTP, or a signed URL.
  globalThis.fetch = () => Promise.reject(new Error("local experiment forbids network"));
  sample("before_imports");
  const [{ createMediaHandler }, auth, r2, codec, { createClient }] = await Promise.all([
    import("../supabase/functions/media/handler.ts"),
    import("../supabase/functions/_shared/auth.ts"),
    import("../supabase/functions/_shared/r2.ts"),
    import("../supabase/functions/_shared/codec_capacity.ts"),
    import("npm:@supabase/supabase-js@2.57.4"),
  ]);
  assert(Object.values(auth).length === 7, "review changed Auth exports");
  assert(Object.values(r2).length === 6, "review changed R2 exports");
  assert(
    [...Object.values(auth), ...Object.values(r2)].every((v) => typeof v === "function"),
    "full helper namespaces must remain loaded",
  );
  sample("after_full_imports");
  const { fixtureBase64 } = await import("../supabase/functions/codec-diagnostic/fixture.ts");
  const bytes = Uint8Array.from(atob(fixtureBase64), (c) => c.charCodeAt(0));
  assert(bytes.length === 571_931, "review changed synthetic fixture");
  const fixtureSha256 = Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", bytes)))
    .map((b) => b.toString(16).padStart(2, "0")).join("");
  sample("after_fixture");
  const owner = "00000000-0000-4000-8000-000000000001";
  const intent = "00000000-0000-4000-8000-000000000003";
  const media = "00000000-0000-4000-8000-000000000004";
  const sourceKey = "synthetic/quarantine.jpg";
  const cleanKey = "synthetic/verified.jpg";
  const counters = { auth: 0, prepare: 0, download: 0, write: 0, commit: 0, remove: 0 };
  type Mode =
    | "normal"
    | "pre_capacity"
    | "post_capacity"
    | "prepare_failure"
    | "existing"
    | "short_image"
    | "invalid_image"
    | "download_failure"
    | "write_failure"
    | "commit_failure"
    | "loser_cleanup_failure";
  let mode: Mode = "normal";
  let enabled = true;
  let capacityCalls = 0;
  let outputBytes = 0;
  let downloadGate: Promise<void> | undefined;
  let reachedDownload: (() => void) | undefined;
  const fakeEnv: Record<string, string> = {
    SUPABASE_URL: "https://synthetic-project.invalid",
    SUPABASE_ANON_KEY: "synthetic-public-no-access",
    SUPABASE_SERVICE_ROLE_KEY: "synthetic-service-no-access",
  };
  const runtime: Parameters<typeof auth.authenticated>[1] = {
    getEnv: (name) => fakeEnv[name],
    createClient: ((url, key, options) =>
      createClient(url, key, {
        ...options,
        global: {
          ...options?.global,
          fetch: async (input, init) => {
            await transportTurn();
            const req = new Request(input, init);
            const url = new URL(req.url);
            assert(url.origin === fakeEnv.SUPABASE_URL, "unexpected synthetic origin");
            if (url.pathname === "/auth/v1/user") {
              counters.auth++;
              assert(req.headers.get("apikey") === fakeEnv.SUPABASE_ANON_KEY, "Auth key mismatch");
              if (req.headers.get("authorization") !== "Bearer synthetic-caller-no-access") {
                return Response.json({ message: "synthetic denial" }, { status: 401 });
              }
              return Response.json({
                id: owner,
                aud: "authenticated",
                role: "authenticated",
                created_at: "2026-01-01T00:00:00Z",
                app_metadata: {},
                user_metadata: {},
              });
            }
            assert(
              req.headers.get("apikey") === fakeEnv.SUPABASE_SERVICE_ROLE_KEY,
              "RPC did not use synthetic service adapter",
            );
            const body = await req.json();
            assert(body.p_owner === owner && body.p_intent === intent, "RPC ownership mismatch");
            if (url.pathname === "/rest/v1/rpc/prepare_media_verification") {
              counters.prepare++;
              sample("prepare");
              if (mode === "prepare_failure") return Response.json([], { status: 200 });
              return Response.json([{
                intent_id: intent,
                source_key: sourceKey,
                expected_bytes: bytes.length,
                clean_key: cleanKey,
                existing_media: mode === "existing" ? media : null,
                expires_at: "2099-01-01T00:00:00Z",
              }]);
            }
            if (url.pathname === "/rest/v1/rpc/commit_verified_media") {
              counters.commit++;
              assert(
                body.p_key === cleanKey && body.p_bytes === outputBytes &&
                  body.p_width === 640 && body.p_height === 640,
                "invalid canonical image output",
              );
              if (mode === "commit_failure") {
                return Response.json({ message: "synthetic uncertain commit" }, { status: 503 });
              }
              return Response.json([{
                media_id: media,
                published_key: mode === "loser_cleanup_failure" ? "synthetic/winner.jpg" : cleanKey,
              }]);
            }
            throw new Error("unexpected synthetic SDK call");
          },
        },
      })) as typeof createClient,
  };
  const handler = createMediaHandler({
    authenticated: (req) => auth.authenticated(req, runtime),
    serviceClient: () => auth.serviceClient(runtime),
    pipelineEnabled: () => enabled,
    storageConfiguration: () => ({
      account: "a".repeat(32),
      bucket: "synthetic",
      accessKeyId: "synthetic-no-access",
      secretAccessKey: "synthetic-no-access",
    }),
    signRead: () => Promise.reject(new Error("unexpected signing")),
    signUpload: () => Promise.reject(new Error("unexpected signing")),
    capacity: () => {
      capacityCalls++;
      const memory = sample(`capacity_${capacityCalls}`);
      codec.requireCodecCapacity(
        (mode === "pre_capacity" && capacityCalls === 1) ||
          (mode === "post_capacity" && capacityCalls === 2)
          ? { rss: 0, heapUsed: 96 * 1024 * 1024 + 1, external: 0 }
          : scenario === "boundaries"
          ? { rss: 0, heapUsed: 20 * 1024 * 1024, external: 0 }
          : memory,
      );
    },
    downloadImage: async (key, size) => {
      await transportTurn();
      counters.download++;
      assert(key === sourceKey && size === bytes.length, "invalid download request");
      reachedDownload?.();
      if (downloadGate) await downloadGate;
      if (mode === "download_failure") throw new Error("synthetic download failure");
      if (mode === "short_image") return bytes.slice(0, -1);
      if (mode === "invalid_image") return new Uint8Array(bytes.length);
      // Retain an independent copy like a real download, without opening a socket.
      return bytes.slice();
    },
    writeVerified: async (key, clean, _expires) => {
      await transportTurn();
      counters.write++;
      assert(key === cleanKey && clean.length === 571_691, "unexpected synthetic output");
      outputBytes = clean.length;
      sample("after_codec_before_write");
      if (mode === "write_failure") return Promise.reject(new Error("synthetic write failure"));
      return Promise.resolve();
    },
    removePayloadAndFence: (key) => {
      counters.remove++;
      assert(key === cleanKey, "must not remove winner or quarantine");
      return Promise.reject(new Error("synthetic cleanup failure"));
    },
  });
  let requests = 0;
  const results: Array<
    { name: string; status: number; code?: string; elapsed_ms: number; effects: typeof counters }
  > = [];
  partial.results = results;
  const request = async (
    name: string,
    authorization: string | null = "synthetic-caller-no-access",
  ) => {
    assert(++requests <= MAX_REQUESTS && performance.now() < deadline, "experiment bound exceeded");
    const start = performance.now();
    const before = { ...counters };
    const headers = new Headers({ "content-type": "application/json" });
    if (authorization !== null) headers.set("authorization", `Bearer ${authorization}`);
    const response = await handler(
      new Request("https://synthetic-handler.invalid", {
        method: "POST",
        headers,
        body: JSON.stringify({ action: "complete", intent_id: intent }),
      }),
    );
    const data = await response.json();
    assert(response.headers.get("cache-control") === "no-store", "response caching changed");
    if (response.status === 200) assert(data.media_id === media, "invalid media response");
    sample(`response_${name}`);
    const effects = { ...counters };
    for (const key of Object.keys(counters) as Array<keyof typeof counters>) {
      effects[key] -= before[key];
    }
    const result = {
      name,
      status: response.status,
      code: data.error,
      elapsed_ms: Math.round((performance.now() - start) * 100) / 100,
      effects,
    };
    results.push(result);
    return result;
  };
  const expect = (r: Awaited<ReturnType<typeof request>>, status: number, code?: string) => {
    assert(
      r.status === status && r.code === code,
      `${r.name}: expected ${status}/${code}, got ${r.status}/${r.code}`,
    );
  };
  const boundaryCases = capacityBoundaryCases().map(({ name, heapUsed, external, allowed }) => {
    let accepted = true;
    try {
      codec.requireCodecCapacity({ rss: 999 * 1024 * 1024, heapUsed, external });
    } catch {
      accepted = false;
    }
    assert(accepted === allowed, `capacity threshold mismatch: ${name}`);
    return { name, allowed };
  });
  // Same handler object and process for every request. No forced GC or retry.
  if (scenario === "sequential" || scenario === "sequential-paced") {
    for (let i = 0; i < 20; i++) {
      if (i && scenario === "sequential-paced") {
        await new Promise((resolve) => setTimeout(resolve, 100));
      }
      capacityCalls = 0;
      const r = await request(`sequential_${i + 1}`);
      assert(
        r.status === 200 || (r.status === 503 && r.code === "image_verifier_busy"),
        "unexpected sequential failure",
      );
      if (r.status === 503) {
        assert(r.effects.write === 0 && r.effects.commit === 0, "busy request wrote or committed");
      }
    }
  }
  const sequentialSummary = {
    completed: results.filter((r) => r.status === 200).length,
    capacity_rejected: results.filter((r) => r.status === 503).length,
  };
  let idleRecovery: { idle_ms: number; status: number; code?: string } | undefined;
  if (scenario === "sequential" || scenario === "sequential-paced") {
    sample("before_idle");
    await pause(2000);
    sample("after_idle");
    capacityCalls = 0;
    const r = await request("after_two_second_idle");
    assert(
      r.status === 200 || (r.status === 503 && r.code === "image_verifier_busy"),
      "unexpected idle recovery failure",
    );
    if (r.status === 503) {
      assert(r.effects.write === 0 && r.effects.commit === 0, "busy recovery wrote or committed");
    }
    idleRecovery = { idle_ms: 2000, status: r.status, code: r.code };
  }
  // Deterministic overlap at the in-memory download. Losers must not prepare,
  // download, write or commit. Auth/JSON happen before the isolate-local lease.
  if (scenario === "burst") {
    capacityCalls = 0;
    let release: () => void = () => {};
    downloadGate = new Promise<void>((resolve) => {
      release = resolve;
    });
    const entered = new Promise<void>((resolve) => {
      reachedDownload = resolve;
    });
    const first = request("burst_admitted");
    const enteredOrResult = await Promise.race([
      entered.then(() => "entered"),
      first.then(() => "finished"),
    ]);
    assert(enteredOrResult === "entered", "burst setup rejected before download");
    const beforeBurst = { ...counters };
    const burst = await Promise.all(
      Array.from({ length: 7 }, (_, i) => request(`burst_rejected_${i + 1}`)),
    );
    for (const r of burst) expect(r, 429, "verification_busy");
    assert(
      counters.prepare === beforeBurst.prepare && counters.download === beforeBurst.download &&
        counters.write === beforeBurst.write && counters.commit === beforeBurst.commit,
      "burst rejection had protected effects",
    );
    release();
    expect(await first, 200);
    downloadGate = undefined;
    reachedDownload = undefined;
    capacityCalls = 0;
    expect(await request("after_burst_recovery"), 200);
  }
  if (scenario === "boundaries") {
    const failures: Array<[Mode, number, string | undefined]> = [
      ["pre_capacity", 503, "image_verifier_busy"],
      ["post_capacity", 503, "image_verifier_busy"],
      ["prepare_failure", 409, "verification_denied"],
      ["existing", 200, undefined],
      ["short_image", 400, "invalid_image"],
      ["invalid_image", 400, "invalid_image"],
      ["download_failure", 500, "internal_error"],
      ["write_failure", 500, "internal_error"],
      ["commit_failure", 409, "verification_pending_retry"],
      ["loser_cleanup_failure", 200, undefined],
    ];
    for (const [failureMode, status, code] of failures) {
      mode = failureMode;
      capacityCalls = 0;
      const r = await request(failureMode);
      expect(r, status, code);
      if (
        [
          "pre_capacity",
          "post_capacity",
          "prepare_failure",
          "existing",
          "short_image",
          "invalid_image",
          "download_failure",
        ].includes(mode)
      ) {
        assert(r.effects.write === 0 && r.effects.commit === 0, "failed preflight wrote an image");
      }
      if (mode === "pre_capacity") assert(r.effects.prepare === 0, "capacity preflight prepared");
      if (mode === "post_capacity") {
        assert(r.effects.download === 1, "second capacity gate missing");
      }
      if (mode === "write_failure") assert(r.effects.commit === 0, "failed write committed");
      if (mode === "commit_failure") {
        assert(r.effects.remove === 0, "uncertain commit removed object");
      }
    }
    mode = "normal";
    enabled = false;
    expect(await request("disabled_pipeline"), 503, "media_pipeline_unavailable");
    enabled = true;
    expect(await request("no_auth", null), 401, "authentication_required");
    expect(await request("denied_auth", "synthetic-denied-no-access"), 401, "invalid_session");
    capacityCalls = 0;
    expect(await request("after_failures_recovery"), 200);
  }
  return {
    scenario,
    experiment: "local_full_media_handler_bundle",
    runtime: Deno.version,
    proof_scope: "ordinary Deno process, NOT Supabase Edge isolate or hosted R2 proof",
    limits: { max_requests: MAX_REQUESTS, max_samples: MAX_SAMPLES, deadline_ms: 90_000 },
    dependency_pins: DEPENDENCY_PINS,
    fixture: {
      width: 640,
      height: 640,
      bytes: bytes.length,
      output_bytes: outputBytes,
      sha256: fixtureSha256,
    },
    synthetic_transport: true,
    network_calls: 0,
    forced_gc: false,
    capacity_metrics: scenario === "boundaries"
      ? "injected to isolate failure boundaries"
      : "actual Deno.memoryUsage",
    inter_request_pause_ms: scenario === "sequential-paced" ? 100 : 0,
    transport_delay_ms: scenario === "sequential-paced" ? 5 : 0,
    idle_recovery: idleRecovery,
    duration_ms: Math.round(performance.now() - started),
    requests,
    sequential: sequentialSummary,
    capacity_boundary_cases: boundaryCases,
    max_sample_heap_external_bytes: Math.max(...samples.map((s) => s.heapUsed + s.external)),
    max_sample_rss_bytes: Math.max(...samples.map((s) => s.rss)),
    counters,
    results,
    samples,
  };
}

if (import.meta.main) {
  try {
    console.log(JSON.stringify(await runLocalExperiment()));
  } catch (error) {
    // Only local assertion text is emitted; no requests, tokens, SDK exceptions,
    // environment values, object URLs or arbitrary external errors are printed.
    console.log(
      JSON.stringify({
        partial,
        error: "LOCAL_MEDIA_BUNDLE_EXPERIMENT_FAILED",
        assertion: error instanceof ExperimentAssertion
          ? error.message
          : "unexpected runtime failure",
      }),
    );
    Deno.exit(1);
  }
}
