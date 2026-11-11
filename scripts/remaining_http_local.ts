/** LOCAL ONLY. Real handlers/Auth/RPC; simulated fences are NOT R2 evidence. */
import { createClient } from "npm:@supabase/supabase-js@2.57.4";
import { authenticated, serviceClient } from "../supabase/functions/_shared/auth.ts";
import { lifecycleDependencies } from "../supabase/functions/_shared/lifecycle.ts";
import { createContactHandler } from "../supabase/functions/contact/handler.ts";
import { createAccountDeleteHandler } from "../supabase/functions/account-delete/handler.ts";
import { createLifecycleHandler } from "../supabase/functions/lifecycle/handler.ts";
const phases = [
  "setup",
  "contact",
  "deletion",
  "lifecycle_authorization",
  "lifecycle_batching",
  "lifecycle_reconciliation",
  "unrelated_fixture",
  "shutdown",
] as const;
type Phase = typeof phases[number];
export class Diagnostics {
  phase: Phase = "setup";
  checks = 0;
  requests = 0;
  private primary: string | null = null;
  capture() {
    if (this.primary !== null) return;
    const phase = phases.includes(this.phase) ? this.phase : "setup";
    const count = (value: number) =>
      Number.isSafeInteger(value) && value >= 0 && value <= 99999 ? value : 0;
    this.primary = `FAIL local HTTP phase=${phase} checks=${count(this.checks)} requests=${
      count(this.requests)
    }`;
  }
  failureLine() {
    this.capture();
    return this.primary!;
  }
}
const diagnostics = new Diagnostics();
export async function withShutdown(
  work: () => Promise<void>,
  shutdown: () => Promise<void>,
  report = diagnostics,
) {
  let failed = false;
  let primary: unknown;
  try {
    await work();
  } catch (error) {
    failed = true;
    primary = error;
    report.capture();
  }
  report.phase = "shutdown";
  try {
    await shutdown();
  } catch (error) {
    if (!failed) {
      failed = true;
      primary = error;
      report.capture();
    }
  }
  if (failed) throw primary;
}

function check(value: unknown): asserts value {
  diagnostics.checks++;
  if (!value) throw new Error("Local handler assertion failed");
}
const origin = "http://127.0.0.1:54321";
const edge = "http://127.0.0.1:54329";
const owners = new Set<string>();
export function validateDestination(input: string, method: string, owned: ReadonlySet<string>) {
  const url = new URL(input);
  check(url.origin === origin && !url.username && !url.password && !url.hash);
  const match = /^\/auth\/v1\/admin\/users\/([a-f0-9-]{36})$/.exec(url.pathname);
  if (match) {
    check(owned.has(match[1]) && ["GET", "DELETE"].includes(method) && !url.search);
  } else {
    check(method !== "DELETE");
    check(
      /^\/(auth\/v1\/(admin\/users|token|user)|rest\/v1\/(profiles|profile_contacts|listings|user_blocks|rpc\/(reveal_listing_contact|begin_account_deletion|is_cleanup_admin|claim_due_deletion_job|get_deletion_job|list_cleanup_objects|mark_object_deleted|deletion_ready_for_auth|finish_account_deletion|record_deletion_failure|local_http_fixture)))$/
        .test(url.pathname),
    );
  }
  return url;
}
async function main() {
  let source = "";
  for await (const bytes of Deno.stdin.readable) {
    source += new TextDecoder().decode(bytes);
    check(source.length <= 65536);
  }
  const status = JSON.parse(source);
  check(
    status.API_URL === origin && typeof status.ANON_KEY === "string" &&
      typeof status.SERVICE_ROLE_KEY === "string",
  );
  let budget = 180;
  const deadline = Date.now() + 120000;
  let dropDeleteReply = false;
  let denyAuth = false;
  let denyContactRpc = false;
  let authDeletes = 0;
  const boundedFetch: typeof fetch = async (input, init) => {
    const method = init?.method ?? (input instanceof Request ? input.method : "GET");
    const url = validateDestination(
      input instanceof Request ? input.url : String(input),
      method,
      owners,
    );
    check(--budget >= 0 && Date.now() < deadline);
    if (denyAuth && url.pathname === "/auth/v1/user") return new Response("{}", { status: 503 });
    if (denyContactRpc && url.pathname === "/rest/v1/rpc/reveal_listing_contact") {
      return new Response("{}", { status: 503 });
    }
    if (method === "DELETE") authDeletes++;
    diagnostics.requests++;
    const response = await fetch(input, {
      ...init,
      redirect: "error",
      signal: AbortSignal.timeout(5000),
    });
    // Commit the genuine local Auth deletion, then lose its response. The actual
    // lifecycle dependency must reconcile via GET 404, without a second DELETE.
    if (method === "DELETE" && dropDeleteReply) {
      dropDeleteReply = false;
      await response.arrayBuffer();
      throw new TypeError("Synthetic lost response");
    }
    return response;
  };
  const env = new Map([["SUPABASE_URL", origin], ["SUPABASE_ANON_KEY", status.ANON_KEY], [
    "SUPABASE_SERVICE_ROLE_KEY",
    status.SERVICE_ROLE_KEY,
  ]]);
  const runtime = { createClient, getEnv: (key: string) => env.get(key), fetch: boundedFetch };
  async function api(
    path: string,
    token: string,
    value?: unknown,
    method = value === undefined ? "GET" : "POST",
  ) {
    const response = await boundedFetch(origin + path, {
      method,
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
  const users: { id: string; token: string }[] = [];
  for (let i = 0; i < 3; i++) {
    const email = `remaining-${crypto.randomUUID()}@sudan-birds.invalid`,
      password = `Local-Aa1!${crypto.randomUUID()}`;
    const user = await api("/auth/v1/admin/users", status.SERVICE_ROLE_KEY, {
      email,
      password,
      email_confirm: true,
    });
    check(typeof user.id === "string");
    owners.add(user.id);
    const session = await api("/auth/v1/token?grant_type=password", status.ANON_KEY, {
      email,
      password,
    });
    check(session.user.id === user.id && typeof session.access_token === "string");
    users.push({ id: user.id, token: session.access_token });
    await api("/rest/v1/profiles", session.access_token, {
      id: user.id,
      display_name: "Synthetic handler fixture",
      accepted_terms_at: new Date().toISOString(),
    });
  }
  const [owner, viewer, unrelated] = users;
  const listings: { id: string }[] = [];
  for (const user of users) {
    const [row] = await api("/rest/v1/listings", user.token, {
      kind: "request",
      title: "Synthetic fixture",
      description: "Synthetic",
      quantity: 1,
    });
    listings.push(row);
  }
  const fixture = (user: typeof owner, mode: string) =>
    api("/rest/v1/rpc/local_http_fixture", status.SERVICE_ROLE_KEY, {
      p_owner: user.id,
      p_mode: mode,
    });
  await fixture(owner, "seed");
  const before = JSON.stringify(
    await api(`/rest/v1/listings?id=eq.${listings[2].id}`, unrelated.token),
  );
  const fences = new Set<string>();
  let fenceMode: "deny" | "allow" = "deny";
  let removes = 0;
  const deps = {
    authenticated: (req: Request) => authenticated(req, runtime),
    serviceClient: () => serviceClient(runtime),
    lifecycleDependencies: (service: ReturnType<typeof serviceClient>) =>
      lifecycleDependencies(service, (key) => {
        check(key.startsWith(`verified/${owner.id}/synthetic-`));
        removes++;
        if (fenceMode === "deny") return Promise.resolve(false);
        fences.add(key);
        return Promise.resolve(true);
      }),
  };
  const secret = "synthetic_local_job_" + "x".repeat(43);
  const handlers: Record<string, (req: Request) => Promise<Response>> = {
    "/contact": createContactHandler(deps),
    "/account-delete": createAccountDeleteHandler(deps),
    "/lifecycle": createLifecycleHandler({ ...deps, jobSecret: () => secret }),
  };
  const server = Deno.serve(
    { hostname: "127.0.0.1", port: 54329, onListen() {} },
    (req) => handlers[new URL(req.url).pathname]?.(req) ?? new Response(null, { status: 404 }),
  );
  let assertions = 0;
  async function request(
    path: string,
    body: unknown,
    expected: number,
    token?: string,
    job?: string,
  ) {
    check(++assertions <= 60 && Date.now() < deadline);
    diagnostics.requests++;
    const response = await fetch(edge + path, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
        ...(job ? { "x-lifecycle-job-secret": job } : {}),
      },
      body: JSON.stringify(body),
      redirect: "error",
      signal: AbortSignal.timeout(10000),
    });
    check(response.status === expected);
    return await response.json();
  }
  await withShutdown(async () => {
    diagnostics.phase = "contact";
    const contact = { listing_id: listings[0].id, explicit_consent: true };
    for (const token of [undefined, "invalid.local.token", status.ANON_KEY]) {
      await request("/contact", contact, 401, token);
    }
    await request("/contact", { ...contact, explicit_consent: false }, 403, viewer.token);
    await request("/contact", contact, 404, viewer.token);
    await api("/rest/v1/profile_contacts", owner.token, {
      owner_id: owner.id,
      contact_kind: "email",
      contact_value: "synthetic@sudan-birds.invalid",
      reveal_consent: false,
    });
    await request("/contact", contact, 404, viewer.token);
    await api(`/rest/v1/profile_contacts?owner_id=eq.${owner.id}`, owner.token, {
      reveal_consent: true,
      consent_at: new Date().toISOString(),
    }, "PATCH");
    const revealed = await request("/contact", contact, 200, viewer.token);
    check(
      JSON.stringify(revealed) ===
        JSON.stringify({
          contact: { contact_kind: "email", contact_value: "synthetic@sudan-birds.invalid" },
        }),
    );
    await api(`/rest/v1/listings?id=eq.${listings[0].id}`, status.SERVICE_ROLE_KEY, {
      moderation_state: "hidden",
    }, "PATCH");
    await request("/contact", contact, 403, viewer.token);
    await api(`/rest/v1/listings?id=eq.${listings[0].id}`, status.SERVICE_ROLE_KEY, {
      moderation_state: "visible",
    }, "PATCH");
    await api("/rest/v1/user_blocks", owner.token, { blocker_id: owner.id, blocked_id: viewer.id });
    await request("/contact", contact, 403, viewer.token);
    await api("/rest/v1/user_blocks", unrelated.token, {
      blocker_id: unrelated.id,
      blocked_id: owner.id,
    });
    await request("/contact", contact, 403, unrelated.token);
    await request("/contact", { ...contact, listing_id: crypto.randomUUID() }, 403, viewer.token);
    denyAuth = true;
    await request("/contact", contact, 503, viewer.token);
    denyAuth = false;
    denyContactRpc = true;
    await request("/contact", contact, 503, viewer.token);
    denyContactRpc = false;
    diagnostics.phase = "deletion";
    const deletion = { confirmation: "DELETE_MY_ACCOUNT" };
    await request("/account-delete", deletion, 401);
    await request("/account-delete", deletion, 401, "invalid.local.token");
    await request("/account-delete", { confirmation: "wrong" }, 400, owner.token);
    await request("/account-delete", { ...deletion, owner_id: unrelated.id }, 400, owner.token);
    diagnostics.phase = "lifecycle_authorization";
    const scheduled = { action: "scheduled" };
    await request("/lifecycle", scheduled, 401);
    await request("/lifecycle", scheduled, 403, viewer.token);
    await request("/lifecycle", scheduled, 403, undefined, "wrong");
    await request("/lifecycle", { action: "cleanup" }, 403, undefined, secret);
    check(authDeletes === 0 && removes === 0);
    diagnostics.phase = "deletion";
    const pending = await request("/account-delete", deletion, 202, owner.token);
    check(
      pending.status === "pending" && pending.blocker_code === "cleanup_retry_required" &&
        authDeletes === 0,
    );
    check((await fixture(owner, "inspect")).remaining === 4);
    const [failedJob] = await api("/rest/v1/rpc/get_deletion_job", status.SERVICE_ROLE_KEY, {
      p_job: pending.job_id,
    });
    check(
      failedJob.owner_id === owner.id && failedJob.state === "pending" &&
        failedJob.failure_count === 1 && failedJob.last_error_code === "cleanup_retry_required",
    );
    check((await api(`/auth/v1/admin/users/${owner.id}`, status.SERVICE_ROLE_KEY)).id === owner.id);
    // Retry with proven simulated fences: one invocation is limited to three.
    diagnostics.phase = "lifecycle_batching";
    fenceMode = "allow";
    await fixture(owner, "retry");
    const start = removes;
    const batch = await request("/lifecycle", scheduled, 202, undefined, secret);
    check(
      batch.status === "pending" && batch.blocker_code === null &&
        removes - start === 3 && authDeletes === 0,
    );
    const remaining = await fixture(owner, "inspect");
    check(remaining.remaining === 1 && remaining.fenced === 3);
    await fixture(owner, "retry");
    diagnostics.phase = "lifecycle_reconciliation";
    dropDeleteReply = true;
    const done = await request("/lifecycle", scheduled, 200, undefined, secret);
    check(done.status === "completed" && Number(authDeletes) === 1 && fences.size === 4);
    const [finishedJob] = await api("/rest/v1/rpc/get_deletion_job", status.SERVICE_ROLE_KEY, {
      p_job: pending.job_id,
    });
    check(
      finishedJob.state === "completed" && finishedJob.completed_at &&
        finishedJob.last_error_code === null,
    );
    const absent = await boundedFetch(`${origin}/auth/v1/admin/users/${owner.id}`, {
      headers: { apikey: status.ANON_KEY, Authorization: `Bearer ${status.SERVICE_ROLE_KEY}` },
    });
    check(absent.status === 404);
    await absent.arrayBuffer();
    await request("/contact", contact, 403, viewer.token);
    const empty = await request("/lifecycle", scheduled, 200, undefined, secret);
    check(empty.deleted === 0 && empty.more_may_remain === false && Number(authDeletes) === 1);
    diagnostics.phase = "unrelated_fixture";
    check(
      JSON.stringify(await api(`/rest/v1/listings?id=eq.${listings[2].id}`, unrelated.token)) ===
        before,
    );
    check(
      (await api(`/auth/v1/admin/users/${unrelated.id}`, status.SERVICE_ROLE_KEY)).id ===
        unrelated.id,
    );
  }, async () => {
    await server.shutdown();
  });
  console.log(`PASS ${assertions} local HTTP checks; real Auth/RPC; simulated storage only`);
}
if (import.meta.main) {
  try {
    await main();
  } catch {
    console.error(diagnostics.failureLine());
    Deno.exitCode = 1;
  }
}
