/** Explicit local-only, synthetic SDK/handler experiment. No service integration. */
import type { AuthRuntime } from "../supabase/functions/_shared/auth.ts";

// Inject only the transport. Auth/runtime construction must retain the real
// backendFetch deadline and error-normalization wrapper around that transport.
export function sdkAuthRuntime(
  getEnv: AuthRuntime["getEnv"],
  fetcher: typeof fetch,
  createClient: AuthRuntime["createClient"],
): AuthRuntime {
  return { getEnv, fetch: fetcher, createClient };
}
const SCENARIOS = [
  "sequential",
  "sequential-paced",
  "burst",
  "boundaries",
  "counterfactual-no-destroy",
];
class DriverAssertion extends Error {}
function assert(value: unknown, message: string): asserts value {
  if (!value) throw new DriverAssertion(message);
}
let partial: Record<string, unknown> | undefined;
export function scenarioArgs(args: string[], version: string) {
  assert(
    version === "2.5.6" && args.length === 2 && args[0] === "--run-local" &&
      SCENARIOS.includes(args[1]),
    "Require Deno 2.5.6, --run-local, and a closed scenario",
  );
  return args[1];
}
export async function runSdkResource() {
  const scenario = scenarioArgs(Deno.args, Deno.version.deno);
  const started = performance.now();
  for (const name of ["net", "read", "write", "run", "sys", "ffi"] as const) {
    assert(
      (await Deno.permissions.query({ name })).state === "denied",
      "runtime permission must be denied",
    );
  }
  globalThis.fetch = () => Promise.reject(new DriverAssertion("network fetch forbidden"));
  const samples: Array<{ phase: string; rss: number; heapUsed: number; external: number }> = [];
  const sample = (phase: string) => {
    assert(samples.length < 768 && performance.now() - started < 90000, "sample/time bound");
    const { rss, heapUsed, external } = Deno.memoryUsage();
    const value = { phase, rss, heapUsed, external };
    samples.push(value);
    return value;
  };
  partial = { scenario, samples };
  sample("before_imports");
  const [
    { createMediaHandler },
    auth,
    { createClient },
    { requireCodecCapacity },
    { createSdkStorage },
  ] = await Promise.all([
    import("../supabase/functions/media/handler.ts"),
    import("../supabase/functions/_shared/auth.ts"),
    import("npm:@supabase/supabase-js@2.57.4"),
    import("../supabase/functions/_shared/codec_capacity.ts"),
    import("./media_sdk_fixture.ts"),
  ]);
  sample("after_full_imports");
  const { fixtureBase64 } = await import("../supabase/functions/codec-diagnostic/fixture.ts");
  const bytes = Uint8Array.from(atob(fixtureBase64), (c) => c.charCodeAt(0));
  assert(bytes.length === 571931, "fixed JPEG size changed");
  sample("after_fixture");
  const delayMs = scenario === "sequential-paced" ? 5 : 0;
  let clockOverride: number | undefined;
  let advanceAfterSign = 0;
  const now = () => clockOverride ?? Date.now();
  const sdk = createSdkStorage(bytes, sample, {
    delayMs,
    now,
    afterSign() {
      if (advanceAfterSign) clockOverride = now() + advanceAfterSign;
    },
    counterfactualNoDestroy: scenario === "counterfactual-no-destroy",
  });
  const effects = { auth: 0, prepare: 0, commit: 0 };
  const owner = "00000000-0000-4000-8000-000000000001";
  const intent = "00000000-0000-4000-8000-000000000003";
  const media = "00000000-0000-4000-8000-000000000004";
  let cleanKey = "";
  let prepared = 0;
  let capacityCalls = 0;
  let injectCapacity: "none" | "before" | "after" = "none";
  const pause = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));
  const trialStart = Date.now();
  const env: Record<string, string> = {
    MEDIA_PIPELINE_ENABLED: "true",
    MEDIA_TRIAL_ACCOUNT_IDS: JSON.stringify([owner, "00000000-0000-4000-8000-000000000002"]),
    MEDIA_TRIAL_STARTS_AT: new Date(trialStart).toISOString(),
    MEDIA_TRIAL_EXPIRES_AT: new Date(trialStart + 20 * 60 * 1000).toISOString(),
    SUPABASE_URL: "https://synthetic-project.invalid",
    SUPABASE_ANON_KEY: "synthetic-public-no-access",
    SUPABASE_SERVICE_ROLE_KEY: "synthetic-service-no-access",
  };
  const runtime = sdkAuthRuntime(
    (name) => env[name],
    async (input, init) => {
      if (delayMs) await pause(delayMs);
      const req = new Request(input, init);
      const url = new URL(req.url);
      assert(url.origin === env.SUPABASE_URL, "Auth/RPC origin");
      if (url.pathname === "/auth/v1/user") {
        effects.auth++;
        assert(
          req.headers.get("authorization") === "Bearer synthetic-caller-no-access",
          "Auth fixture credential",
        );
        return Response.json({
          id: owner,
          aud: "authenticated",
          role: "authenticated",
          created_at: "2026-01-01T00:00:00Z",
          app_metadata: {},
          user_metadata: {},
        });
      }
      const inputBody = await req.json();
      assert(
        req.headers.get("apikey") === env.SUPABASE_SERVICE_ROLE_KEY &&
          inputBody.p_owner === owner && inputBody.p_intent === intent,
        "RPC ownership",
      );
      if (url.pathname === "/rest/v1/rpc/prepare_media_verification") {
        effects.prepare++;
        cleanKey = `synthetic/clean-${++prepared}.jpg`;
        return Response.json([{
          intent_id: intent,
          source_key: "synthetic/source.jpg",
          clean_key: cleanKey,
          expected_bytes: bytes.length,
          existing_media: null,
          expires_at: "2099-01-01T00:00:00Z",
        }]);
      }
      if (url.pathname === "/rest/v1/rpc/commit_verified_media") {
        effects.commit++;
        assert(
          inputBody.p_key === cleanKey && inputBody.p_bytes === 571691 &&
            inputBody.p_width === 640 && inputBody.p_height === 640,
          "canonical output",
        );
        return Response.json([{ media_id: media, published_key: cleanKey }]);
      }
      throw new DriverAssertion("unexpected Auth/RPC route");
    },
    createClient,
  );
  const handler = createMediaHandler({
    ...sdk.deps,
    authenticated: (req) => auth.authenticated(req, runtime),
    serviceClient: () => auth.serviceClient(runtime),
    getEnv: (name) => env[name],
    now,
    capacity: () => {
      const memory = sample("capacity");
      capacityCalls++;
      requireCodecCapacity(
        (injectCapacity === "before" && capacityCalls === 1) ||
          (injectCapacity === "after" && capacityCalls === 2)
          ? { rss: 0, heapUsed: 97 * 1024 * 1024, external: 0 }
          : memory,
      );
    },
  });
  const results: Array<
    {
      name: string;
      status: number;
      code?: string;
      elapsed_ms: number;
      effects: Record<string, number>;
    }
  > = [];
  partial.results = results;
  let requests = 0;
  const snapshot = () => ({ ...effects, ...sdk.effects });
  const request = async (name: string) => {
    assert(++requests <= 64, "request bound");
    partial!.phase = name;
    const before = snapshot();
    const start = performance.now();
    const response = await handler(
      new Request("https://synthetic-handler.invalid", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          authorization: "Bearer synthetic-caller-no-access",
        },
        body: JSON.stringify({ action: "complete", intent_id: intent }),
      }),
    );
    const body = await response.json();
    assert(response.headers.get("cache-control") === "no-store", "cache boundary");
    if (response.status === 200) assert(body.media_id === media, "verified media result");
    const after = snapshot();
    const delta: Record<string, number> = {};
    for (const key of Object.keys(before) as Array<keyof typeof before>) {
      delta[key] = after[key] - before[key];
    }
    const result = {
      name,
      status: response.status,
      code: body.error,
      elapsed_ms: Math.round((performance.now() - start) * 100) / 100,
      effects: delta,
    };
    results.push(result);
    sample(`response_${name}`);
    return result;
  };
  const expect = (r: Awaited<ReturnType<typeof request>>, status: number, code?: string) =>
    assert(
      r.status === status && r.code === code,
      `${r.name}: expected ${status}/${code}, got ${r.status}/${r.code}`,
    );
  const supplement = async () => {
    // Separate read-signing and orphan cleanup workloads, not removal of a
    // published winner. Objects retain metadata only, never image payloads.
    await sdk.deps.signRead(cleanKey);
    await sdk.deps.removePayloadAndFence(`synthetic/orphan-${prepared}.jpg`);
    sample("after_read_and_orphan_fence");
  };
  let idle: { status: number; code?: string } | undefined;
  if (["sequential", "sequential-paced", "counterfactual-no-destroy"].includes(scenario)) {
    for (let i = 0; i < 20; i++) {
      if (i && delayMs) await pause(100);
      capacityCalls = 0;
      const r = await request(`sequential_${i + 1}`);
      assert(
        r.status === 200 || (r.status === 503 && r.code === "image_verifier_busy"),
        "unexpected sequential outcome",
      );
      if (r.status === 200) await supplement();
      else assert(r.effects.signed_put === 0 && r.effects.commit === 0, "busy write/commit");
    }
    sample("before_idle");
    await pause(2000);
    sample("after_idle");
    capacityCalls = 0;
    const r = await request("after_two_second_idle");
    assert(
      r.status === 200 || (r.status === 503 && r.code === "image_verifier_busy"),
      "unexpected recovery outcome",
    );
    if (r.status === 200) await supplement();
    idle = { status: r.status, code: r.code };
  }
  if (scenario === "burst") {
    let release: () => void = () => {};
    const waiting = new Promise<void>((resolve) => {
      release = resolve;
    });
    let entered: () => void = () => {};
    const startedDownload = new Promise<void>((resolve) => {
      entered = resolve;
    });
    sdk.holdDownload(waiting, entered);
    const first = request("burst_admitted");
    assert(
      await Promise.race([startedDownload.then(() => true), first.then(() => false)]),
      "burst setup failed",
    );
    const before = snapshot();
    const burst = await Promise.all(
      Array.from({ length: 7 }, (_, i) => request(`burst_rejected_${i + 1}`)),
    );
    for (const r of burst) expect(r, 429, "verification_busy");
    const after = snapshot();
    for (const key of ["prepare", "commit", "clients", "get", "signed_put"] as const) {
      assert(before[key] === after[key], "burst side effect");
    }
    release();
    expect(await first, 200);
    sdk.holdDownload();
    capacityCalls = 0;
    expect(await request("after_burst"), 200);
    await supplement();
  }
  if (scenario === "boundaries") {
    for (
      const [mode, status, code] of [
        ["wrong_length", 400, "invalid_image"],
        ["wrong_type", 400, "invalid_image"],
        ["short_stream", 400, "invalid_image"],
        ["long_stream", 400, "invalid_image"],
        ["missing_body", 500, "internal_error"],
        ["get_denied", 500, "internal_error"],
        ["put_conflict", 409, "upload_conflict"],
        ["put_failed", 502, "image_storage_failed"],
        ["get_retry_once", 200, undefined],
        ["stall_stream", 502, "image_download_timeout"],
      ] as const
    ) {
      sdk.setMode(mode);
      capacityCalls = 0;
      const r = await request(mode);
      expect(r, status, code);
      assert(r.effects.clients === r.effects.destroys, "failure-path client ownership");
      if (status !== 200) assert(r.effects.commit === 0, "failure committed");
      if (["wrong_length", "wrong_type", "long_stream", "stall_stream"].includes(mode)) {
        assert(r.effects.canceled === 1, "stream was not canceled");
      }
      if (mode === "get_retry_once") assert(r.effects.get === 2, "bounded SDK retry missing");
    }
    sdk.setMode("normal");
    for (const point of ["before", "after"] as const) {
      injectCapacity = point;
      capacityCalls = 0;
      const r = await request(`capacity_${point}`);
      expect(r, 503, "image_verifier_busy");
      assert(r.effects.signed_put === 0 && r.effects.commit === 0, "capacity denial wrote");
      if (point === "before") {
        assert(r.effects.clients === 0 && r.effects.prepare === 0, "early admission side effects");
      } else {assert(
          r.effects.get === 1 && r.effects.closed === 1,
          "late admission stream completion",
        );}
    }
    injectCapacity = "none";
    sdk.setMode("bad_fence");
    let fenceRejected = false;
    try {
      await sdk.deps.removePayloadAndFence("synthetic/bad-fence.jpg");
    } catch (error) {
      fenceRejected = error instanceof Error && "code" in error &&
        error.code === "storage_cleanup_failed";
    }
    assert(fenceRejected, "mismatched fence accepted");
    sdk.setMode("wrong_length");
    sdk.setCancellation(() => new Promise<void>(() => {}));
    capacityCalls = 0;
    const boundedCancel = await request("metadata_cancel_grace");
    expect(boundedCancel, 400, "invalid_image");
    assert(
      boundedCancel.effects.destroyed_with_pending_cancellation === 1 &&
        boundedCancel.effects.clients === boundedCancel.effects.destroys,
      "bounded cancellation did not destroy its owner",
    );
    sdk.setCancellation();
    sdk.setMode("normal");
    clockOverride = Date.parse(env.MEDIA_TRIAL_EXPIRES_AT);
    const expired = await request("trial_expired");
    expect(expired, 503, "media_pipeline_unavailable");
    assert(
      expired.effects.prepare === 0 && expired.effects.clients === 0,
      "expired trial side effects",
    );
    clockOverride = undefined;
    const allowed = env.MEDIA_TRIAL_ACCOUNT_IDS;
    env.MEDIA_TRIAL_ACCOUNT_IDS = JSON.stringify([intent, media]);
    const unlisted = await request("trial_unlisted");
    expect(unlisted, 503, "media_pipeline_unavailable");
    assert(
      unlisted.effects.prepare === 0 && unlisted.effects.clients === 0,
      "unlisted trial side effects",
    );
    env.MEDIA_TRIAL_ACCOUNT_IDS = allowed;
    sdk.holdDownload(undefined, () => {
      env.MEDIA_PIPELINE_ENABLED = "false";
    });
    capacityCalls = 0;
    const revoked = await request("trial_revoked_after_download");
    expect(revoked, 503, "media_pipeline_unavailable");
    assert(
      revoked.effects.closed === 1 && revoked.effects.destroys === 1 &&
        revoked.effects.signed_put === 0 && revoked.effects.commit === 0,
      "revoked trial side effects",
    );
    sdk.holdDownload();
    env.MEDIA_PIPELINE_ENABLED = "true";
    advanceAfterSign = 20 * 60 * 1000;
    capacityCalls = 0;
    const delayedSign = await request("deadline_crossed_during_signing");
    expect(delayedSign, 409, "upload_expired");
    assert(
      delayedSign.effects.presign_put === 1 && delayedSign.effects.signed_put === 0 &&
        delayedSign.effects.commit === 0 &&
        delayedSign.effects.clients === delayedSign.effects.destroys,
      "expired canonical signature dispatched",
    );
    advanceAfterSign = 0;
    clockOverride = undefined;
    capacityCalls = 0;
    expect(await request("after_boundary_failures"), 200);
  }
  sample("before_default_handler_inspection");
  const defaultHandler = sdk.inspectDefaultClient();
  assert(
    sdk.effects.destroys === (scenario === "counterfactual-no-destroy" ? 0 : sdk.effects.clients),
    "client lifecycle drift",
  );
  return {
    experiment: "local_media_sdk_timed_gate_owned_lifetime_supplement",
    scenario,
    runtime: Deno.version,
    proof_scope:
      "ordinary Deno; real SDK with synthetic transport, NOT hosted R2 or production adapter wiring",
    source_pin_checked_by: "scripts/media_sdk_resource.sh",
    fixture_bytes: bytes.length,
    max_requests: 64,
    max_samples: 768,
    max_clients: 128,
    max_sdk_attempts: 128,
    max_stream_chunks: 1024,
    deadline_ms: 90000,
    process_timeout_seconds: 120,
    network_permissions: "denied",
    file_process_sys_ffi_permissions: "denied",
    network_calls: 0,
    forced_gc: false,
    capacity_metrics: "actual Deno memory, except two injected denial cases",
    lifecycle: scenario === "counterfactual-no-destroy"
      ? "counterfactual only: no destroy with current shared helpers, NOT a production baseline"
      : "current production lifetime: destroy operation-owned clients after completion or bounded cancellation",
    default_handler_inspection: defaultHandler,
    inter_request_pause_ms: delayMs ? 100 : 0,
    transport_delay_ms: delayMs,
    requests,
    duration_ms: Math.round(performance.now() - started),
    idle_recovery: idle,
    max_sample_heap_external_bytes: Math.max(...samples.map((s) => s.heapUsed + s.external)),
    max_sample_rss_bytes: Math.max(...samples.map((s) => s.rss)),
    effects: snapshot(),
    results,
    samples,
  };
}
if (import.meta.main) {
  try {
    console.log(JSON.stringify(await runSdkResource()));
  } catch (error) {
    console.log(
      JSON.stringify({
        error: "LOCAL_MEDIA_SDK_EXPERIMENT_FAILED",
        partial,
        assertion: error instanceof DriverAssertion
          ? error.message
          : "unexpected local runtime failure",
      }),
    );
    Deno.exit(1);
  }
}
