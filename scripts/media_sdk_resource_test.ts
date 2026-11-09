import { check, createSdkStorage, FixtureAssertion } from "./media_sdk_fixture.ts";
import { scenarioArgs } from "./media_sdk_resource.ts";
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
