import { check, createSdkStorage, FixtureAssertion } from "./media_sdk_fixture.ts";
import { scenarioArgs, sdkAuthRuntime } from "./media_sdk_resource.ts";
import { createClient } from "npm:@supabase/supabase-js@2.57.4";
import { authenticated, serviceClient } from "../supabase/functions/_shared/auth.ts";
import { ApiError } from "../supabase/functions/_shared/http.ts";

async function rejects(operation: () => Promise<unknown>, code?: string) {
  let failure: unknown;
  try {
    await operation();
  } catch (error) {
    failure = error;
  }
  check(failure instanceof Error, "expected rejection");
  if (code) check(failure instanceof ApiError && failure.code === code, "expected safe error code");
  return failure;
}
const expiry = "2099-01-01T00:00:00Z";
const key = "synthetic/sample.jpg";
const image = new Uint8Array(100001).fill(71);

Deno.test("SDK harness requires explicit opt-in pinned runtime and closed scenario", () => {
  for (
    const name of [
      "sequential",
      "sequential-paced",
      "burst",
      "boundaries",
      "counterfactual-no-destroy",
    ]
  ) {
    check(scenarioArgs(["--run-local", name], "2.5.6") === name, "valid scenario");
  }
  for (
    const args of [[], ["--run-local"], ["--run-local", "https://example.com"], [
      "--run-local",
      "burst",
      "extra",
    ], ["--run-hosted", "burst"]]
  ) {
    let rejected = false;
    try {
      scenarioArgs(args, "2.5.6");
    } catch {
      rejected = true;
    }
    check(rejected, "invalid argument accepted");
  }
  let rejected = false;
  try {
    scenarioArgs(["--run-local", "burst"], "2.5.7");
  } catch {
    rejected = true;
  }
  check(rejected, "version drift accepted");
});

Deno.test("SDK harness runs with net file process sys and ffi permissions denied", async () => {
  for (const name of ["net", "read", "write", "run", "sys", "ffi"] as const) {
    check((await Deno.permissions.query({ name })).state === "denied", "permission enabled");
  }
});

Deno.test("actual SigV4 presign verifies independently and binds method key and conditional headers", async () => {
  const sdk = createSdkStorage(image, () => {});
  const signed = await sdk.deps.signUpload(key, image.length, "image/jpeg");
  const headers = {
    "content-type": "image/jpeg",
    "content-length": String(image.length),
    "if-none-match": "*",
  };
  await sdk.verifyPresigned(signed, "PUT", headers);
  for (const header of Object.keys(headers) as Array<keyof typeof headers>) {
    check(
      await rejects(() =>
        sdk.verifyPresigned(signed, "PUT", { ...headers, [header]: "tampered" })
      ) instanceof FixtureAssertion,
      "unsigned upload header",
    );
  }
  await rejects(() => sdk.verifyPresigned(signed, "GET", headers));
  const alteredPath = new URL(signed);
  alteredPath.pathname = "/synthetic/other.jpg";
  await rejects(() => sdk.verifyPresigned(alteredPath.href, "PUT", headers));
  const alteredExpiry = new URL(signed);
  alteredExpiry.searchParams.set("X-Amz-Expires", "121");
  await rejects(() => sdk.verifyPresigned(alteredExpiry.href, "PUT", headers));
  const foreign = new URL(signed);
  foreign.hostname = "outside.invalid";
  await rejects(() => sdk.verifyPresigned(foreign.href, "PUT", headers));
  await sdk.deps.signRead(key);
  check(
    sdk.effects.sdk_attempts === 0 && sdk.effects.destroys === 2,
    "presigning transport or cleanup mismatch",
  );
});

Deno.test("real GetObject serialization deserialization and SDK web stream preserve exact bytes", async () => {
  const sdk = createSdkStorage(image, () => {});
  const result = await sdk.deps.downloadImage(key, image.length);
  check(
    result.length === image.length && result.every((value) => value === 71),
    "stream bytes changed",
  );
  check(
    sdk.effects.get === 1 && sdk.effects.verified_signatures === 1 &&
      sdk.effects.stream_chunks === 2,
    "SDK or chunk path skipped",
  );
  check(
    sdk.effects.closed === 1 && sdk.effects.canceled === 0 && sdk.effects.destroys === 1,
    "stream lifecycle changed",
  );
});

Deno.test("download size type and overflow failures cancel actual SDK response streams", async () => {
  for (const mode of ["wrong_length", "wrong_type", "long_stream", "short_stream"] as const) {
    const sdk = createSdkStorage(image, () => {});
    sdk.setMode(mode);
    await rejects(() => sdk.deps.downloadImage(key, image.length), "invalid_image");
    if (mode === "short_stream") check(sdk.effects.closed === 1, "short stream not exhausted");
    else check(sdk.effects.canceled === 1, "bad stream not canceled");
  }
});

Deno.test("SDK rejects malformed missing-body response before adapter guard and retries only retryable errors", async () => {
  const sdk = createSdkStorage(image, () => {});
  sdk.setMode("missing_body");
  const missing = await rejects(() => sdk.deps.downloadImage(key, image.length));
  check(
    !(missing instanceof ApiError) && sdk.effects.get === 1,
    "missing-body SDK behavior changed",
  );
  sdk.setMode("get_retry_once");
  await sdk.deps.downloadImage(key, image.length);
  check(
    Number(sdk.effects.get) === 3 && sdk.effects.closed === 1,
    "retry count exceeded two attempts",
  );
  sdk.setMode("get_denied");
  const denied = await rejects(() => sdk.deps.downloadImage(key, image.length));
  check(denied.name === "AccessDenied" && Number(sdk.effects.get) === 4, "access denial retried");
});

Deno.test("presigned writes preserve create-only rejection and tombstone Put Head metadata checks", async () => {
  const sdk = createSdkStorage(image, () => {});
  await sdk.deps.writeVerified(key, image, expiry);
  await rejects(() => sdk.deps.writeVerified(key, image, expiry), "upload_conflict");
  await sdk.deps.removePayloadAndFence("synthetic/orphan.jpg");
  check(sdk.effects.put === 1 && sdk.effects.head === 1, "fence command sequence changed");
  sdk.setMode("bad_fence");
  await rejects(
    () => sdk.deps.removePayloadAndFence("synthetic/bad-fence.jpg"),
    "storage_cleanup_failed",
  );
});

Deno.test("current default destroys each owned client after its complete operation", async () => {
  const sdk = createSdkStorage(image, () => {});
  await sdk.deps.downloadImage(key, image.length);
  check(sdk.effects.closed === 1 && sdk.effects.destroys === 1, "download cleanup ordering");
  await sdk.deps.signRead(key);
  await sdk.deps.writeVerified(key, image, expiry);
  await sdk.deps.removePayloadAndFence("synthetic/orphan.jpg");
  check(sdk.effects.clients === 4 && Number(sdk.effects.destroys) === 4, "cleanup count");
});

function latch() {
  let release!: () => void;
  const promise = new Promise<void>((resolve) => {
    release = resolve;
  });
  return { promise, release: () => release() };
}

Deno.test("metadata cancellation settles before owning client destruction", async () => {
  const waiting = latch(), entered = latch();
  const events: string[] = [];
  const sdk = createSdkStorage(image, () => {}, { onEvent: ({ name }) => events.push(name) });
  sdk.setMode("wrong_length");
  sdk.setCancellation(() => {
    entered.release();
    return waiting.promise;
  });
  const operation = rejects(() => sdk.deps.downloadImage(key, image.length), "invalid_image");
  await entered.promise;
  check(sdk.effects.destroys === 0, "destroyed before delayed cancellation settled");
  waiting.release();
  await operation;
  check(
    Number(sdk.effects.destroys) === 1 && sdk.effects.cancellation_settled === 1,
    "delayed cancellation ownership",
  );
  check(events.indexOf("cancel-settled") < events.indexOf("destroy"), "cancellation ordering");
});

Deno.test("rejected cancellation preserves original error and destroys the owning client", async () => {
  const sdk = createSdkStorage(image, () => {});
  sdk.setMode("wrong_type");
  sdk.setCancellation(() => Promise.reject(new Error("synthetic cancellation rejection")));
  await rejects(() => sdk.deps.downloadImage(key, image.length), "invalid_image");
  check(
    sdk.effects.destroys === 1 && sdk.effects.cancellation_settled === 1,
    "rejected cancellation cleanup",
  );
});

Deno.test("never-settling metadata and overflow cancellation reaches bounded owner cleanup", async () => {
  for (const mode of ["wrong_length", "long_stream"] as const) {
    const sdk = createSdkStorage(image, () => {});
    sdk.setMode(mode);
    sdk.setCancellation(() => new Promise<void>(() => {}));
    const start = performance.now();
    await rejects(() => sdk.deps.downloadImage(key, image.length), "invalid_image");
    const elapsed = performance.now() - start;
    check(elapsed >= 900 && elapsed < 5000, "cancellation grace exceeded bounded allowance");
    check(
      sdk.effects.destroys === 1 && sdk.effects.cancellation_settled === 0 &&
        sdk.effects.destroyed_with_pending_cancellation === 1,
      "pending cancellation not bounded",
    );
  }
});

Deno.test("fence owner stays alive through final HEAD verification", async () => {
  const waiting = latch(), entered = latch();
  const sdk = createSdkStorage(image, () => {});
  sdk.holdHead(waiting.promise, entered.release);
  const operation = sdk.deps.removePayloadAndFence("synthetic/held-head.jpg");
  await entered.promise;
  check(
    sdk.effects.put === 1 && sdk.effects.head === 1 && sdk.effects.destroys === 0,
    "client destroyed before HEAD completed",
  );
  waiting.release();
  await operation;
  check(Number(sdk.effects.destroys) === 1 && sdk.effects.clients === 1, "fence ownership");
});

Deno.test("concurrent downloads own separate client lifetimes", async () => {
  const waiting = latch(), entered = latch();
  const destroyed: number[] = [];
  const sdk = createSdkStorage(image, () => {}, {
    onEvent: ({ client, name }) => {
      if (name === "destroy") destroyed.push(client);
    },
  });
  sdk.holdDownload(waiting.promise, entered.release);
  const first = sdk.deps.downloadImage(key, image.length);
  await entered.promise;
  sdk.holdDownload();
  await sdk.deps.downloadImage(key, image.length);
  check(destroyed.length === 1 && destroyed[0] === 2, "one operation destroyed another owner");
  waiting.release();
  await first;
  check(destroyed.join(",") === "2,1", "concurrent ownership ordering");
});

Deno.test("canonical write rejects invalid or elapsed full TTL after signing and destroys signer", async () => {
  let clock = Date.now();
  let advance = 0;
  const sdk = createSdkStorage(image, () => {}, {
    now: () => clock,
    afterSign() {
      clock += advance;
    },
  });
  await rejects(() => sdk.deps.writeVerified(key, image, "invalid"), "upload_expired");
  await rejects(
    () => sdk.deps.writeVerified(key, image, new Date(clock + 2999).toISOString()),
    "upload_expired",
  );
  check(
    sdk.effects.clients === 0 && sdk.effects.signed_put === 0,
    "invalid deadline constructed client",
  );
  advance = 600;
  await rejects(
    () => sdk.deps.writeVerified(key, image, new Date(clock + 4500).toISOString()),
    "upload_expired",
  );
  check(
    Number(sdk.effects.clients) === 1 && sdk.effects.destroys === 1 && sdk.effects.signed_put === 0,
    "full TTL mismatch dispatched or leaked signer",
  );
  advance = 100;
  await sdk.deps.writeVerified(key, image, new Date(clock + 4500).toISOString());
  check(
    Number(sdk.effects.destroys) === 2 && Number(sdk.effects.signed_put) === 1,
    "valid TTL rejected",
  );
});

Deno.test("no-destroy exists only as an explicit counterfactual option", async () => {
  const sdk = createSdkStorage(image, () => {}, { counterfactualNoDestroy: true });
  await sdk.deps.downloadImage(key, image.length);
  check(
    sdk.effects.clients === 1 && sdk.effects.closed === 1 && sdk.effects.destroys === 0,
    "counterfactual lifecycle mislabeled",
  );
});

Deno.test("resource Auth transport injection preserves production timeout normalization and identities", async () => {
  const originalTimeout = AbortSignal.timeout;
  const originalLog = console.error;
  const logs: unknown[] = [];
  const signals: AbortSignal[] = [];
  const owner = "00000000-0000-4000-8000-000000000001";
  let failing = false;
  AbortSignal.timeout = (ms) => {
    check(ms === 15_000, "backend request deadline changed");
    const signal = new AbortController().signal;
    signals.push(signal);
    return signal;
  };
  console.error = (value) => logs.push(value);
  const env: Record<string, string> = {
    SUPABASE_URL: "https://synthetic-project.invalid",
    SUPABASE_ANON_KEY: "synthetic-public",
    SUPABASE_SERVICE_ROLE_KEY: "synthetic-service",
  };
  const runtime = sdkAuthRuntime((name) => env[name], (input, init) => {
    check(init?.signal instanceof AbortSignal, "production backend wrapper was bypassed");
    const req = new Request(input, init);
    const isAuth = new URL(req.url).pathname === "/auth/v1/user";
    check(
      req.headers.get("authorization") ===
        `Bearer ${isAuth ? "synthetic-caller" : "synthetic-service"}`,
      "request identity changed",
    );
    if (failing) throw new Error("PRIVATE_SYNTHETIC_TRANSPORT_DETAIL");
    return Promise.resolve(Response.json(isAuth ? { id: owner } : { ok: true }));
  }, createClient);
  try {
    const req = () =>
      new Request("https://synthetic.invalid", {
        headers: { authorization: "Bearer synthetic-caller" },
      });
    check((await authenticated(req(), runtime)).user.id === owner, "verified identity changed");
    check(!(await serviceClient(runtime).rpc("synthetic_rpc")).error, "service RPC failed");
    failing = true;
    await rejects(() => authenticated(req(), runtime), "authentication_unavailable");
    check(
      (await serviceClient(runtime).rpc("synthetic_rpc")).error,
      "transport failure became success",
    );
    check(signals.length === 4, "not every Auth/RPC request used backend deadline");
    check(
      logs.length === 2 && logs.every((log) => log === '{"event":"upstream_transport_failed"}'),
      "raw SDK exception escaped",
    );
  } finally {
    AbortSignal.timeout = originalTimeout;
    console.error = originalLog;
  }
});

Deno.test("SDK fixture destroy failures preserve confirmed outcomes and primary errors", async () => {
  const original = console.error;
  const logs: unknown[] = [];
  console.error = (value) => logs.push(value);
  try {
    const sdk = createSdkStorage(image, () => {}, {
      onDestroy() {
        throw new Error("PRIVATE_SYNTHETIC_DESTROY_DETAIL");
      },
    });
    await sdk.deps.signRead(key);
    sdk.setMode("wrong_length");
    await rejects(() => sdk.deps.downloadImage(key, image.length), "invalid_image");
    sdk.setMode("normal");
    check(
      await sdk.deps.removePayloadAndFence("synthetic/orphan.jpg"),
      "confirmed fence result lost",
    );
    check(sdk.effects.clients === 3 && sdk.effects.destroys === 3, "destroy ownership lost");
    check(
      logs.length === 3 && logs.every((log) => log === '{"event":"storage_client_cleanup_failed"}'),
      "raw destroy exception escaped",
    );
  } finally {
    console.error = original;
  }
});

Deno.test("SDK fixture signed PUT response cleanup preserves success conflict and failure within bounded grace", async () => {
  const originalTimer = globalThis.setTimeout;
  const originalLog = console.error;
  const delays: number[] = [];
  const logs: unknown[] = [];
  globalThis.setTimeout = ((callback: (...args: unknown[]) => void, delay?: number) => {
    delays.push(delay ?? 0);
    return originalTimer(callback, delay === 1_000 ? 5 : delay);
  }) as typeof setTimeout;
  console.error = (value) => logs.push(value);
  try {
    for (const mode of ["normal", "put_conflict", "put_failed"] as const) {
      for (const cancel of ["reject", "hang"] as const) {
        const sdk = createSdkStorage(image, () => {}, {
          putCancellation: () =>
            cancel === "reject"
              ? Promise.reject(new Error("PRIVATE_SYNTHETIC_RESPONSE_DETAIL"))
              : new Promise<void>(() => {}),
        });
        sdk.setMode(mode);
        if (mode === "normal") await sdk.deps.writeVerified(key, image, expiry);
        else {await rejects(
            () => sdk.deps.writeVerified(key, image, expiry),
            mode === "put_conflict" ? "upload_conflict" : "image_storage_failed",
          );}
        check(
          sdk.effects.put_response_canceled === 1 && sdk.effects.destroys === 1,
          "PUT cleanup skipped",
        );
      }
    }
    check(
      delays.filter((delay) => delay === 1_000).length === 6,
      "bounded cancellation grace skipped",
    );
    check(
      logs.length === 6 &&
        logs.every((log) =>
          log === '{"event":"stream_cleanup_failed"}' ||
          log === '{"event":"stream_cleanup_timeout"}'
        ),
      "raw cleanup failure escaped",
    );
  } finally {
    globalThis.setTimeout = originalTimer;
    console.error = originalLog;
  }
});
