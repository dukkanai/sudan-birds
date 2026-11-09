import { S3Client } from "npm:@aws-sdk/client-s3@3.1164.0";
import { presignCreateOnly } from "../_shared/presign.ts";
import { createMediaHandler } from "./handler.ts";
import {
  fixture,
  id,
  other,
  owner,
  privateMarker,
  reply,
  token,
} from "../_shared/endpoint_fixtures.ts";
import { assert, jpeg } from "../_shared/test_fixtures.ts";

const reserve = { action: "reserve", listing_id: id, bytes: 100, mime: "image/jpeg" };
const complete = { action: "complete", intent_id: id };
const start = Date.parse("2026-01-01T00:00:00.000Z");
const end = start + 20 * 60 * 1000;
const rest = (f: ReturnType<typeof fixture>) => f.calls.filter((c) => c.path.startsWith("/rest/"));
function active() {
  const f = fixture();
  f.env.MEDIA_PIPELINE_ENABLED = "true";
  f.rpc("reserve_upload", {
    id,
    object_key: "quarantine/synthetic.jpg",
    expected_bytes: 100,
    expected_mime: "image/jpeg",
  });
  const claim = {
    intent_id: id,
    source_key: "quarantine/synthetic.jpg",
    expected_bytes: jpeg().length,
    clean_key: "verified/synthetic.jpg",
    existing_media: null,
    expires_at: new Date(end + 60000).toISOString(),
  };
  f.rpc("prepare_media_verification", [claim]);
  f.rpc("commit_verified_media", [{ media_id: id, published_key: claim.clean_key }]);
  return { ...f, claim };
}
async function denied(response: Response) {
  assert(response.status === 503);
  assert(response.headers.get("cache-control") === "no-store");
  const data = await response.json();
  assert(data.error === "media_pipeline_unavailable");
  assert(typeof data.request_id === "string");
  assert(Object.keys(data).sort().join(",") === "error,request_id");
  assert(!JSON.stringify(data).includes(privateMarker));
}

Deno.test("handler denies missing malformed future expired or excluded trials before any privileged effect", async () => {
  const changes: Array<(f: ReturnType<typeof active>) => void> = [
    (f) => {
      delete f.env.MEDIA_TRIAL_ACCOUNT_IDS;
    },
    (f) => {
      delete f.env.MEDIA_TRIAL_STARTS_AT;
    },
    (f) => {
      delete f.env.MEDIA_TRIAL_EXPIRES_AT;
    },
    (f) => {
      f.env.MEDIA_TRIAL_ACCOUNT_IDS = privateMarker;
    },
    (f) => {
      f.env.MEDIA_TRIAL_ACCOUNT_IDS = JSON.stringify([owner]);
    },
    (f) => {
      f.env.MEDIA_TRIAL_ACCOUNT_IDS = JSON.stringify([owner, other, id]);
    },
    (f) => {
      f.env.MEDIA_TRIAL_ACCOUNT_IDS = JSON.stringify([owner, owner]);
    },
    (f) => {
      f.env.MEDIA_TRIAL_ACCOUNT_IDS = JSON.stringify([owner, "*"]);
    },
    (f) => {
      f.env.MEDIA_TRIAL_ACCOUNT_IDS = JSON.stringify([other, id]);
    },
    (f) => {
      f.env.MEDIA_TRIAL_STARTS_AT = "2026-01-01T00:00:00.000+00:00";
    },
    (f) => {
      f.env.MEDIA_TRIAL_EXPIRES_AT = "2026-02-30T00:00:00.000Z";
    },
    (f) => {
      f.env.MEDIA_TRIAL_EXPIRES_AT = new Date(start).toISOString();
    },
    (f) => {
      f.env.MEDIA_TRIAL_EXPIRES_AT = new Date(end + 1).toISOString();
    },
    (f) => {
      f.clock.now = start - 1;
    },
    (f) => {
      f.clock.now = end;
    },
  ];
  for (const change of changes) {
    const f = active();
    change(f);
    const handler = createMediaHandler({
      ...f.auth,
      ...f.storage,
      storageConfiguration: () => {
        throw new Error("Gate reached storage configuration");
      },
      capacity: () => {
        throw new Error("Gate reached codec capacity");
      },
    });
    for (const input of [reserve, complete]) await denied(await handler(f.request(input)));
    assert(f.calls.length === 2 && f.calls.every((c) => c.path === "/auth/v1/user"));
    assert(f.effects.length === 0);
  }
});

Deno.test("handler allowlist uses real Auth.getUser identity, never caller JWT sub or JSON owner", async () => {
  for (const returnedId of [owner, other, id, `${owner}\n`]) {
    const f = active();
    const caller = token({ sub: returnedId === id ? owner : id });
    f.accepted.add(caller);
    f.routes.set("/auth/v1/user", () => reply({ id: returnedId }));
    const result = await f.handlers().media(f.request(reserve, `Bearer ${caller}`));
    if (returnedId !== owner && returnedId !== other) {
      if (returnedId.endsWith("\n")) {
        assert(result.status === 401 && (await result.json()).error === "invalid_session");
      } else await denied(result);
      assert(rest(f).length === 0 && f.effects.length === 0);
    } else {
      assert(result.status === 200);
      const invalid = await f.handlers().media(f.request({ ...complete, owner_id: id }));
      assert(invalid.status === 400 && (await invalid.json()).error === "unknown_field");
    }
  }
});

Deno.test("handler checks deadline anew on every request in the same isolate", async () => {
  const f = active();
  const handler = f.handlers().media;
  assert((await handler(f.request(reserve))).status === 200);
  f.clock.now = end;
  const before = rest(f).length;
  for (const input of [reserve, complete]) await denied(await handler(f.request(input)));
  assert(rest(f).length === before && f.effects.length === 1);
});

Deno.test("reserve rechecks after async reservation and before signing without returning an expired URL", async () => {
  const f = active();
  f.routes.set("/rest/v1/rpc/reserve_upload", () => {
    f.clock.now = end;
    return reply({
      id,
      object_key: "quarantine/synthetic.jpg",
      expected_bytes: 100,
      expected_mime: "image/jpeg",
    });
  });
  await denied(await f.handlers().media(f.request(reserve)));
  assert(rest(f).length === 1 && f.effects.length === 0);
});

Deno.test("reserve advertises its actual clamped TTL and keeps signed create-only headers", async () => {
  for (const remaining of [120000, 119999, 34999, 1000]) {
    const f = active();
    f.clock.now = end - remaining;
    let ttl = 0;
    const handler = createMediaHandler({
      ...f.auth,
      ...f.storage,
      signUpload: (key, bytes, mime, expiresIn) => {
        assert(key === "quarantine/synthetic.jpg" && bytes === 100 && mime === "image/jpeg");
        ttl = expiresIn!;
        return Promise.resolve("https://synthetic.invalid/upload");
      },
    });
    const result = await handler(f.request(reserve));
    const data = await result.json();
    assert(result.status === 200 && ttl === Math.floor(remaining / 1000));
    assert(data.expires_in === ttl && data.required_headers["If-None-Match"] === "*");
    assert(
      data.required_headers["Content-Length"] === "100" &&
        data.required_headers["Content-Type"] === "image/jpeg",
    );
  }
});

Deno.test("reserve with less than one second remaining neither consumes quota nor signs", async () => {
  const f = active();
  f.clock.now = end - 999;
  await denied(await f.handlers().media(f.request(reserve)));
  assert(f.effects.length === 0 && rest(f).length === 0);
});

Deno.test("reserve discards presign if signing consumes its remaining TTL or configuration changes", async () => {
  for (const change of ["expired", "ttl", "disabled", "extended"]) {
    const f = active();
    f.clock.now = end - 10000;
    const handler = createMediaHandler({
      ...f.auth,
      ...f.storage,
      signUpload: async () => {
        await Promise.resolve();
        if (change === "expired") f.clock.now = end;
        if (change === "ttl") f.clock.now += 1;
        if (change === "disabled") f.env.MEDIA_PIPELINE_ENABLED = "false";
        if (change === "extended") {
          f.env.MEDIA_TRIAL_STARTS_AT = new Date(start + 10000).toISOString();
          f.env.MEDIA_TRIAL_EXPIRES_AT = new Date(end + 10000).toISOString();
        }
        return `https://synthetic.invalid/${privateMarker}`;
      },
    });
    await denied(await handler(f.request(reserve)));
  }
});

Deno.test("delayed actual SDK presigning returns only URLs whose signed expiry fits the trial", async () => {
  const RealDate = Date;
  try {
    for (const remaining of [200000, 10000]) {
      const f = active();
      f.clock.now = end - remaining;
      // The pinned SDK uses new Date() for signingDate, not the injected gate
      // clock. Drive both clocks deterministically without changing the SDK.
      globalThis.Date = class extends RealDate {
        constructor(value?: string | number) {
          super(value === undefined ? f.clock.now : value);
        }
        static override now() {
          return f.clock.now;
        }
      } as unknown as DateConstructor;
      const client = new S3Client({
        region: "auto",
        endpoint: "https://synthetic-delayed.invalid",
        credentials: {
          accessKeyId: "SYNTHETIC_TEST_ONLY",
          secretAccessKey: "SYNTHETIC_NOT_A_REAL_CREDENTIAL",
        },
        requestChecksumCalculation: "WHEN_REQUIRED",
        responseChecksumValidation: "WHEN_REQUIRED",
        retryMode: "standard",
        defaultsMode: "standard",
        maxAttempts: 1,
        useFipsEndpoint: false,
        useDualstackEndpoint: false,
        defaultUserAgentProvider: () => Promise.resolve([["synthetic-delayed", "0.1"]]),
        requestHandler: { handle: () => Promise.reject(new Error("No transport permitted")) },
      });
      let internallySigned = "";
      try {
        const handler = createMediaHandler({
          ...f.auth,
          ...f.storage,
          signUpload: async (key, bytes, mime, expiresIn) => {
            await Promise.resolve();
            f.clock.now += 3000;
            internallySigned = await presignCreateOnly(
              client,
              "synthetic",
              key,
              bytes,
              mime,
              expiresIn!,
            );
            return internallySigned;
          },
        });
        const result = await handler(f.request(reserve));
        const signed = new URL(internallySigned);
        const date = signed.searchParams.get("X-Amz-Date")!;
        const signedAt = RealDate.parse(
          date.replace(/^(\d{4})(\d\d)(\d\d)T(\d\d)(\d\d)(\d\d)Z$/, "$1-$2-$3T$4:$5:$6.000Z"),
        );
        const signedExpiry = signedAt + Number(signed.searchParams.get("X-Amz-Expires")) * 1000;
        assert(signedAt === f.clock.now);
        if (remaining === 200000) {
          const data = await result.json();
          assert(result.status === 200 && data.put_url === internallySigned);
          assert(data.expires_in === 120 && signedExpiry <= end);
        } else {
          // The expiresIn-only signer CAN construct an internal URL beyond the
          // deadline after a delay. The handler must never disclose that URL.
          assert(signedExpiry > end);
          await denied(result);
        }
      } finally {
        client.destroy();
      }
    }
  } finally {
    globalThis.Date = RealDate;
  }
});

Deno.test("complete checks expiry after preparation and releases its single-verification guard", async () => {
  const f = active();
  f.routes.set("/rest/v1/rpc/prepare_media_verification", () => {
    f.clock.now = end;
    return reply([f.claim]);
  });
  const handler = f.handlers().media;
  await denied(await handler(f.request(complete)));
  assert(f.effects.join(",") === "service-client");
  // A later, separately authorized fixed window is valid for a new request.
  f.env.MEDIA_TRIAL_STARTS_AT = new Date(end).toISOString();
  f.env.MEDIA_TRIAL_EXPIRES_AT = new Date(end + 120000).toISOString();
  assert((await handler(f.request(complete))).status === 200);
});

Deno.test("complete cannot decode write or commit after download crosses deadline or disables gate", async () => {
  for (const change of ["expiry", "disabled"]) {
    const f = active();
    let capacities = 0;
    const handler = createMediaHandler({
      ...f.auth,
      ...f.storage,
      capacity: () => {
        capacities++;
      },
      downloadImage: async () => {
        await Promise.resolve();
        if (change === "expiry") f.clock.now = end;
        else f.env.MEDIA_PIPELINE_ENABLED = "false";
        return jpeg();
      },
    });
    await denied(await handler(f.request(complete)));
    assert(capacities === 1);
    assert(rest(f).every((c) => c.path.endsWith("prepare_media_verification")));
    assert(f.effects.join(",") === "service-client");
  }
});

Deno.test("complete rechecks after synchronous codec work before writing", async () => {
  const f = active();
  let capacities = 0;
  const handler = createMediaHandler({
    ...f.auth,
    ...f.storage,
    capacity: () => {
      if (++capacities === 2) f.clock.now = end;
    },
  });
  await denied(await handler(f.request(complete)));
  assert(f.effects.join(",") === "service-client,download");
  assert(rest(f).length === 1);
});

Deno.test("complete bounds canonical write deadline to earlier trial or intent expiry", async () => {
  for (const intentExpiry of [end + 60000, end - 60000]) {
    const f = active();
    f.claim.expires_at = new Date(intentExpiry).toISOString();
    f.rpc("prepare_media_verification", [f.claim]);
    let received = "";
    const handler = createMediaHandler({
      ...f.auth,
      ...f.storage,
      writeVerified: (_key, _bytes, expires) => {
        received = expires;
        return Promise.resolve();
      },
    });
    assert((await handler(f.request(complete))).status === 200);
    assert(received === new Date(Math.min(intentExpiry, end)).toISOString());
  }
});

Deno.test("complete does not commit or delete an output if an in-flight write finishes after expiry", async () => {
  const f = active();
  let writes = 0;
  const handler = createMediaHandler({
    ...f.auth,
    ...f.storage,
    writeVerified: async () => {
      writes++;
      await Promise.resolve();
      f.clock.now = end;
    },
  });
  await denied(await handler(f.request(complete)));
  assert(writes === 1 && rest(f).length === 1);
  assert(!f.effects.some((e) => e.startsWith("remove:")));
});

Deno.test("already-dispatched commit reports its result after expiry and loser cleanup still runs", async () => {
  for (const loser of [false, true]) {
    const f = active();
    f.routes.set("/rest/v1/rpc/commit_verified_media", () => {
      f.clock.now = end;
      return reply([{
        media_id: id,
        published_key: loser ? "verified/winner.jpg" : f.claim.clean_key,
      }]);
    });
    const result = await f.handlers().media(f.request(complete));
    assert(result.status === 200 && (await result.json()).media_id === id);
    assert(f.effects.includes(`remove:${f.claim.clean_key}`) === loser);
    assert(!f.effects.includes("remove:verified/winner.jpg"));
  }
});

Deno.test("reads and lifecycle cleanup remain available with missing or expired trial", async () => {
  const f = active();
  delete f.env.MEDIA_TRIAL_ACCOUNT_IDS;
  f.clock.now = end;
  f.routes.set("/rest/v1/media", () => reply([{ object_key: "verified/existing.jpg" }]));
  f.rpc("is_cleanup_admin", true);
  f.rpc("list_cleanup_objects", []);
  const handlers = f.handlers();
  assert((await handlers.media(f.request({ action: "read", media_id: id }))).status === 200);
  assert((await handlers.mediaRead(f.request({ media_id: id }, null))).status === 200);
  assert((await handlers.lifecycle(f.request({ action: "cleanup" }))).status === 200);
});

Deno.test("production default handler wiring enforces trial with real Auth SDK and real create-only presign", async () => {
  // No handler dependency override: intercept only runtime env/transport. No
  // actual environment read, socket, deployment credential or real account.
  const savedEnv = Deno.env.get;
  const savedFetch = globalThis.fetch;
  const now = Date.now();
  const env: Record<string, string> = {
    HOME: "/nonexistent-synthetic-home",
    AWS_CONFIG_FILE: "/dev/null",
    AWS_SHARED_CREDENTIALS_FILE: "/dev/null",
    AWS_PROFILE: "default",
    SUPABASE_URL: "https://synthetic-default.invalid",
    SUPABASE_ANON_KEY: "synthetic-public-key",
    R2_ACCOUNT_ID: "a".repeat(32),
    R2_BUCKET: "synthetic-bucket",
    R2_ACCESS_KEY_ID: "synthetic-access",
    R2_SECRET_ACCESS_KEY: "synthetic-secret",
    MEDIA_PIPELINE_ENABLED: "true",
  };
  const paths: string[] = [];
  let returnedId = owner;
  try {
    Deno.env.get = (key) => env[key];
    globalThis.fetch = (input, init) => {
      const req = new Request(input, init);
      const url = new URL(req.url);
      assert(url.origin === env.SUPABASE_URL);
      paths.push(url.pathname);
      if (url.pathname === "/auth/v1/user") return Promise.resolve(reply({ id: returnedId }));
      if (url.pathname === "/rest/v1/rpc/reserve_upload") {
        assert(req.headers.get("authorization") === "Bearer synthetic-default-caller");
        return Promise.resolve(reply({
          id,
          object_key: "quarantine/synthetic.jpg",
          expected_bytes: 100,
          expected_mime: "image/jpeg",
        }));
      }
      throw new Error("Unexpected default-handler transport");
    };
    const handler = createMediaHandler();
    const request = (input: unknown) =>
      new Request("https://edge.invalid", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          authorization: "Bearer synthetic-default-caller",
        },
        body: JSON.stringify(input),
      });
    for (const input of [reserve, complete]) await denied(await handler(request(input)));
    assert(paths.length === 2 && paths.every((p) => p === "/auth/v1/user"));
    env.MEDIA_TRIAL_ACCOUNT_IDS = JSON.stringify([owner, other]);
    env.MEDIA_TRIAL_STARTS_AT = new Date(now - 1000).toISOString();
    env.MEDIA_TRIAL_EXPIRES_AT = new Date(now + 20 * 60 * 1000 - 1000).toISOString();
    returnedId = id;
    for (const input of [reserve, complete]) await denied(await handler(request(input)));
    assert(Number(paths.length) === 4 && paths.every((p) => p === "/auth/v1/user"));
    returnedId = owner;
    const result = await handler(request(reserve));
    const data = await result.json();
    assert(result.status === 200 && data.expires_in === 120);
    const url = new URL(data.put_url);
    assert(url.searchParams.get("X-Amz-Expires") === String(data.expires_in));
    const signed = url.searchParams.get("X-Amz-SignedHeaders")?.split(";") ?? [];
    for (const header of ["if-none-match", "content-type", "content-length"]) {
      assert(signed.includes(header));
    }
    const date = url.searchParams.get("X-Amz-Date")!;
    const signedAt = Date.parse(
      date.replace(/^(\d{4})(\d\d)(\d\d)T(\d\d)(\d\d)(\d\d)Z$/, "$1-$2-$3T$4:$5:$6.000Z"),
    );
    assert(signedAt + data.expires_in * 1000 <= Date.parse(env.MEDIA_TRIAL_EXPIRES_AT));
    env.MEDIA_TRIAL_EXPIRES_AT = new Date(now - 1).toISOString();
    for (const input of [reserve, complete]) await denied(await handler(request(input)));
    assert(paths.filter((p) => p.startsWith("/rest/")).length === 1);
  } finally {
    Deno.env.get = savedEnv;
    globalThis.fetch = savedFetch;
  }
});
