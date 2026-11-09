// Synthetic SDK transport for local handler wiring tests. Never reaches fetch,
// reads deployment credentials, opens a socket or creates a real account.
import { createClient } from "npm:@supabase/supabase-js@2.57.4";
import { authenticated, type AuthRuntime, publicReadClient, serviceClient } from "./auth.ts";
import { lifecycleDependencies } from "./lifecycle.ts";
import { storageConfiguration } from "./r2.ts";
import { jpeg } from "./test_fixtures.ts";
import { createContactHandler } from "../contact/handler.ts";
import { createAccountDeleteHandler } from "../account-delete/handler.ts";
import { createMediaHandler } from "../media/handler.ts";
import { createMediaReadHandler } from "../media-read/handler.ts";
import { createLifecycleHandler } from "../lifecycle/handler.ts";

export const owner = "00000000-0000-4000-8000-000000000001";
export const other = "00000000-0000-4000-8000-000000000002";
export const id = "00000000-0000-4000-8000-000000000003";
export const session = "00000000-0000-4000-8000-000000000004";
export const publicKey = "synthetic-public-api-key";
export const serviceKey = "synthetic-service-api-key";
export const jobSecret = "synthetic-local-test-only-job-secret-no-access-000";
export const privateMarker = "SYNTHETIC_PRIVATE_EXCEPTION_DO_NOT_EXPOSE";
export function token(overrides: Record<string, unknown> = {}): string {
  return "synthetic." + btoa(JSON.stringify({
    sub: owner,
    session_id: session,
    amr: [{ method: "oauth", timestamp: Math.floor(Date.now() / 1000) - 10 }],
    ...overrides,
  })).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_") + ".synthetic-signature";
}
export interface Call {
  method: string;
  path: string;
  search: string;
  authorization: string | null;
  apikey: string | null;
  body: Record<string, unknown>;
}
export type Route = (call: Call) => Response | Promise<Response>;
export function reply(data: unknown, status = 200): Response {
  return Response.json(data, { status });
}
export function fixture() {
  const calls: Call[] = [];
  const effects: string[] = [];
  const routes = new Map<string, Route>();
  const accepted = new Set<string>();
  const valid = token();
  accepted.add(valid);
  const clock = { now: Date.parse("2026-01-01T00:00:00.000Z") };
  const env: Record<string, string> = {
    SUPABASE_URL: "https://synthetic-project.invalid",
    SUPABASE_PUBLISHABLE_KEYS: JSON.stringify({ default: publicKey }),
    SUPABASE_SECRET_KEYS: JSON.stringify({ default: serviceKey }),
    R2_ACCOUNT_ID: "a".repeat(32),
    R2_BUCKET: "synthetic-bucket",
    R2_ACCESS_KEY_ID: "synthetic-access",
    R2_SECRET_ACCESS_KEY: "synthetic-secret",
    MEDIA_PIPELINE_ENABLED: "false",
    MEDIA_TRIAL_ACCOUNT_IDS: JSON.stringify([owner, other]),
    MEDIA_TRIAL_STARTS_AT: "2026-01-01T00:00:00.000Z",
    MEDIA_TRIAL_EXPIRES_AT: "2026-01-01T00:20:00.000Z",
    LIFECYCLE_JOB_SECRET: jobSecret,
  };
  const runtime: AuthRuntime = {
    getEnv: (name) => env[name],
    createClient: ((url, key, options) =>
      createClient(url, key, {
        ...options,
        global: {
          ...options?.global,
          fetch: async (input, init) => {
            const req = new Request(input, init);
            const url = new URL(req.url);
            const text = await req.text();
            const call: Call = {
              path: url.pathname,
              search: url.search,
              method: req.method,
              authorization: req.headers.get("authorization"),
              apikey: req.headers.get("apikey"),
              body: text ? JSON.parse(text) : {},
            };
            calls.push(call);
            const route = routes.get(`${call.method} ${call.path}`) ?? routes.get(call.path);
            if (route) return await route(call);
            if (call.path === "/auth/v1/user") {
              return accepted.has((call.authorization ?? "").slice(7))
                ? reply({
                  id: owner,
                  aud: "authenticated",
                  role: "authenticated",
                  created_at: "2026-01-01T00:00:00Z",
                  app_metadata: {},
                  user_metadata: {},
                })
                : reply({ code: "bad_jwt", message: privateMarker }, 401);
            }
            throw new Error(`Unexpected synthetic transport call: ${call.method} ${call.path}`);
          },
        },
      })) as typeof createClient,
  };
  const auth = {
    authenticated: (req: Request) => authenticated(req, runtime),
    serviceClient: () => {
      effects.push("service-client");
      return serviceClient(runtime);
    },
  };
  const storage = {
    signRead: (key: string) => {
      effects.push(`read:${key}`);
      return Promise.resolve("https://synthetic-storage.invalid/read");
    },
    signUpload: (key: string) => {
      effects.push(`sign:${key}`);
      return Promise.resolve("https://synthetic-storage.invalid/upload");
    },
    storageConfiguration: () => storageConfiguration(runtime.getEnv),
    downloadImage: (_key: string, _bytes: number) => {
      effects.push("download");
      return Promise.resolve(jpeg());
    },
    writeVerified: (_key: string, _bytes: Uint8Array, _expires: string) => {
      effects.push("write");
      return Promise.resolve();
    },
    removePayloadAndFence: (key: string) => {
      effects.push(`remove:${key}`);
      return Promise.resolve(true);
    },
    getEnv: runtime.getEnv,
    now: () => clock.now,
    capacity: () => {},
  };
  const lifecycle = {
    ...auth,
    lifecycleDependencies: (service: ReturnType<typeof serviceClient>) =>
      lifecycleDependencies(service, (key) => storage.removePayloadAndFence(key)),
    jobSecret: () => env.LIFECYCLE_JOB_SECRET,
  };
  const request = (input: unknown, authorization: string | null = `Bearer ${valid}`) => {
    const headers: Record<string, string> = { "content-type": "application/json" };
    if (authorization !== null) headers.authorization = authorization;
    return new Request("https://edge.invalid", {
      method: "POST",
      headers,
      body: JSON.stringify(input),
    });
  };
  const rpc = (name: string, data: unknown, status = 200) =>
    routes.set(`/rest/v1/rpc/${name}`, () => reply(data, status));
  const handlers = () => ({
    contact: createContactHandler(auth),
    accountDelete: createAccountDeleteHandler(lifecycle),
    media: createMediaHandler({ ...auth, ...storage }),
    mediaRead: createMediaReadHandler({
      publicReadClient: (req) => publicReadClient(req, runtime),
      signRead: (key) => storage.signRead(key),
    }),
    lifecycle: createLifecycleHandler(lifecycle),
  });
  return {
    calls,
    effects,
    routes,
    accepted,
    valid,
    env,
    clock,
    auth,
    storage,
    lifecycle,
    request,
    rpc,
    handlers,
  };
}
