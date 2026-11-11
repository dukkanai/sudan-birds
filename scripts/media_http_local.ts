/** LOCAL TEST ONLY: real HTTP/Auth/RPC; storage is an in-memory simulation, NOT R2. */
import { createClient } from "npm:@supabase/supabase-js@2.57.4";
import { encode } from "npm:jpeg-js@0.4.4";
import {
  authenticated,
  publicReadClient,
  serviceClient,
} from "../supabase/functions/_shared/auth.ts";
import { createMediaHandler } from "../supabase/functions/media/handler.ts";
import { createMediaReadHandler } from "../supabase/functions/media-read/handler.ts";
import { requireCodecCapacity } from "../supabase/functions/_shared/codec_capacity.ts";
import { sanitizeJpeg } from "../supabase/functions/_shared/images.ts";
import { ApiError } from "../supabase/functions/_shared/http.ts";

function check(value: unknown): asserts value {
  if (!value) throw new Error("Local media assertion failed");
}
const origin = "http://127.0.0.1:54321";
const edge = "http://127.0.0.1:54329";
let budget = 100;
const deadline = Date.now() + 120_000;
export function validateDestination(input: string) {
  const url = new URL(input);
  check(url.origin === origin && !url.username && !url.password && !url.hash);
  check(
    /^\/(auth\/v1\/(admin\/users|token|user)|rest\/v1\/(profiles|listings|media|user_blocks|rpc\/(reserve_upload|prepare_media_verification|commit_verified_media)))$/
      .test(url.pathname),
  );
  return url;
}
const boundedFetch: typeof fetch = async (input, init) => {
  validateDestination(input instanceof Request ? input.url : String(input));
  check(--budget >= 0 && Date.now() < deadline);
  return await fetch(input, { ...init, redirect: "error", signal: AbortSignal.timeout(5000) });
};
export function syntheticJpeg() {
  const encoded = new Uint8Array(
    encode({ width: 16, height: 16, data: new Uint8Array(16 * 16 * 4).fill(128) }, 80).data,
  );
  const metadata = new TextEncoder().encode("SYNTHETIC_PRIVATE_METADATA");
  const input = new Uint8Array(encoded.length + metadata.length + 4);
  input.set(encoded.subarray(0, 2));
  input.set([255, 254, 0, metadata.length + 2], 2);
  input.set(metadata, 6);
  input.set(encoded.subarray(2), 6 + metadata.length);
  return input;
}
async function main() {
  const chunks: Uint8Array[] = [];
  let size = 0;
  for await (const chunk of Deno.stdin.readable) {
    size += chunk.length;
    check(size <= 65536);
    chunks.push(chunk);
  }
  const raw = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    raw.set(chunk, offset);
    offset += chunk.length;
  }
  const status = JSON.parse(new TextDecoder().decode(raw));
  check(
    status.API_URL === origin && typeof status.ANON_KEY === "string" &&
      typeof status.SERVICE_ROLE_KEY === "string",
  );
  const env = new Map<string, string>([
    ["SUPABASE_URL", origin],
    ["SUPABASE_ANON_KEY", status.ANON_KEY],
    ["SUPABASE_SERVICE_ROLE_KEY", status.SERVICE_ROLE_KEY],
  ]);
  const runtime = { getEnv: (key: string) => env.get(key), createClient, fetch: boundedFetch };
  async function api(path: string, token: string, value?: unknown) {
    const response = await boundedFetch(origin + path, {
      method: value === undefined ? "GET" : "POST",
      headers: {
        apikey: status.ANON_KEY,
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json",
        Prefer: "return=representation",
      },
      body: value === undefined ? undefined : JSON.stringify(value),
    });
    check(response.ok);
    return await response.json();
  }
  // Never delete users through an API. CI destroys this disposable stack on all exits.
  const users: { id: string; token: string }[] = [];
  for (let i = 0; i < 2; i++) {
    const email = `media-${crypto.randomUUID()}@sudan-birds.invalid`;
    const password = `Local-Aa1!${crypto.randomUUID()}`;
    const user = await api("/auth/v1/admin/users", status.SERVICE_ROLE_KEY, {
      email,
      password,
      email_confirm: true,
    });
    const session = await api("/auth/v1/token?grant_type=password", status.ANON_KEY, {
      email,
      password,
    });
    check(session.user.id === user.id && typeof session.access_token === "string");
    users.push({ id: user.id, token: session.access_token });
    await api("/rest/v1/profiles", session.access_token, {
      id: user.id,
      display_name: "Local media fixture",
      accepted_terms_at: new Date().toISOString(),
    });
  }
  const [owner, other] = users;
  env.set("MEDIA_PIPELINE_ENABLED", "true");
  env.set("MEDIA_TRIAL_ACCOUNT_IDS", JSON.stringify(users.map((u) => u.id)));
  env.set("MEDIA_TRIAL_STARTS_AT", new Date().toISOString());
  env.set("MEDIA_TRIAL_EXPIRES_AT", new Date(Date.now() + 180_000).toISOString());
  const [listing] = await api("/rest/v1/listings", owner.token, {
    kind: "request",
    title: "Local media fixture",
    description: "Synthetic",
    quantity: 1,
  });
  const objects = new Map<string, Uint8Array>();
  const uploads = new Map<string, string>();
  const signRead = (key: string) =>
    Promise.resolve(`https://simulated.invalid/${encodeURIComponent(key)}`);
  let downloads = 0;
  const media = createMediaHandler({
    authenticated: (req) => authenticated(req, runtime),
    serviceClient: () => serviceClient(runtime),
    getEnv: runtime.getEnv,
    now: Date.now,
    capacity: () => requireCodecCapacity(Deno.memoryUsage()),
    storageConfiguration: () => ({
      account: "simulated",
      bucket: "simulated",
      accessKeyId: "simulated",
      secretAccessKey: "simulated",
    }),
    signRead,
    signUpload: (key) => {
      const url = `https://simulated.invalid/${crypto.randomUUID()}`;
      uploads.set(url, key);
      return Promise.resolve(url);
    },
    downloadImage: (key, count) => {
      downloads++;
      const bytes = objects.get(key);
      if (!bytes || bytes.length !== count) throw new ApiError(400, "invalid_image");
      return Promise.resolve(bytes.slice());
    },
    writeVerified: (key, bytes) => {
      check(!objects.has(key));
      objects.set(key, bytes.slice());
      return Promise.resolve();
    },
    removePayloadAndFence: (key) => {
      objects.set(key, new Uint8Array());
      return Promise.resolve(true);
    },
  });
  const read = createMediaReadHandler({
    publicReadClient: (req) => publicReadClient(req, runtime),
    signRead,
  });
  const server = Deno.serve({ hostname: "127.0.0.1", port: 54329, onListen() {} }, (req) => {
    const path = new URL(req.url).pathname;
    return path === "/media"
      ? media(req)
      : path === "/media-read"
      ? read(req)
      : new Response(null, { status: 404 });
  });
  let assertions = 0;
  async function request(path: string, body: unknown, expected: number, token?: string) {
    check(++assertions <= 30 && Date.now() < deadline);
    const response = await fetch(edge + path, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
      body: JSON.stringify(body),
      redirect: "error",
      signal: AbortSignal.timeout(10000),
    });
    check(response.status === expected);
    return await response.json();
  }
  try {
    const input = syntheticJpeg();
    const reserve = {
      action: "reserve",
      listing_id: listing.id,
      bytes: input.length,
      mime: "image/jpeg",
    };
    await request("/media", reserve, 401);
    await request("/media", reserve, 401, "invalid.local.token");
    await request("/media", reserve, 403, other.token);
    check(uploads.size === 0);
    const intent = await request("/media", reserve, 200, owner.token);
    check(uploads.has(intent.put_url));
    objects.set(uploads.get(intent.put_url)!, input);
    const complete = {
      action: "complete",
      intent_id: intent.intent_id,
      alt_text: "Synthetic image",
    };
    await request("/media", complete, 409, other.token);
    check(downloads === 0);
    const result = await request("/media", complete, 200, owner.token);
    check(result.status === "verified");
    const [row] = await api(`/rest/v1/media?id=eq.${result.media_id}`, owner.token);
    const clean = objects.get(row.object_key);
    const canonical = sanitizeJpeg(input);
    check(
      clean && clean.length === canonical.bytes.length &&
        clean.every((v, i) => v === canonical.bytes[i]),
    );
    check(!new TextDecoder().decode(clean).includes("SYNTHETIC_PRIVATE_METADATA"));
    check(
      row.owner_id === owner.id && row.listing_id === listing.id && row.width === 16 &&
        row.height === 16 && row.byte_size === clean.length && row.mime_type === "image/jpeg" &&
        row.alt_text === "Synthetic image" && row.verified_at,
    );
    const repeat = await request("/media", complete, 200, owner.token);
    check(repeat.media_id === result.media_id && Number(downloads) === 1);
    const readInput = { media_id: result.media_id };
    for (const token of [undefined, status.ANON_KEY, owner.token, other.token]) {
      const output = await request("/media-read", readInput, 200, token);
      check(output.url === await signRead(row.object_key) && output.expires_in === 60);
    }
    await request("/media-read", readInput, 401, "invalid.local.token");
    await request("/media", { action: "read", ...readInput }, 401);
    await request("/media", { action: "read", ...readInput }, 200, owner.token);
    await api("/rest/v1/user_blocks", other.token, { blocker_id: other.id, blocked_id: owner.id });
    await request("/media-read", readInput, 404, other.token);
    await request("/media-read", readInput, 200);
    const bad = await request("/media", reserve, 200, owner.token);
    objects.set(uploads.get(bad.put_url)!, new Uint8Array(input.length));
    await request("/media", { action: "complete", intent_id: bad.intent_id }, 400, owner.token);
    const rows = await api(`/rest/v1/media?listing_id=eq.${listing.id}`, owner.token);
    check(rows.length === 1);
    console.log(`PASS ${assertions} local HTTP checks; real Auth/RPC; simulated storage only`);
  } finally {
    await server.shutdown();
    objects.clear();
    uploads.clear();
  }
}
if (import.meta.main) {
  try {
    await main();
  } catch {
    console.error("FAIL local media HTTP integration; sensitive details suppressed");
    Deno.exitCode = 1;
  }
}
