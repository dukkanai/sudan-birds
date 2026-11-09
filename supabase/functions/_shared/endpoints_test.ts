import { ApiError } from "./http.ts";
import { assert, jpeg } from "./test_fixtures.ts";
import { createMediaHandler } from "../media/handler.ts";
import {
  fixture,
  id,
  jobSecret,
  other,
  owner,
  privateMarker,
  publicKey,
  reply,
  serviceKey,
  session,
  token,
} from "./endpoint_fixtures.ts";

type Handler = (req: Request) => Promise<Response>;
async function response(handler: Handler, req: Request, status: number, code?: string) {
  const result = await handler(req);
  const data = await result.json();
  assert(result.status === status);
  assert(result.headers.get("cache-control") === "no-store");
  assert(result.headers.get("x-content-type-options") === "nosniff");
  assert(!JSON.stringify(data).includes(privateMarker));
  if (code) {
    assert(data.error === code);
    assert(typeof data.request_id === "string" && data.request_id.length === 36);
  }
  return data;
}
const validInputs = {
  contact: { listing_id: id, explicit_consent: true },
  accountDelete: { confirmation: "DELETE_MY_ACCOUNT" },
  media: { action: "reserve", listing_id: id, bytes: 100, mime: "image/jpeg" },
  mediaRead: { media_id: id },
  lifecycle: { action: "cleanup" },
};
const rpcCalls = (f: ReturnType<typeof fixture>) =>
  f.calls.filter((c) => c.path.startsWith("/rest/"));
const job = (extra = {}) => ({
  id,
  owner_id: owner,
  state: "pending",
  not_before: new Date(0).toISOString(),
  ...extra,
});

Deno.test("every application handler rejects methods before authentication or side effects", async () => {
  const f = fixture();
  for (const handler of Object.values(f.handlers())) {
    for (const method of ["GET", "DELETE", "OPTIONS"]) {
      await response(
        handler,
        new Request("https://edge.invalid", { method }),
        405,
        "method_not_allowed",
      );
    }
  }
  assert(f.calls.length === 0 && f.effects.length === 0);
});

Deno.test("protected endpoints reject missing malformed expired and service credentials", async () => {
  for (
    const header of [null, "Basic test", "Bearer x y", "Bearer expired", `Bearer ${serviceKey}`]
  ) {
    for (const name of ["contact", "media", "accountDelete", "lifecycle"] as const) {
      const f = fixture();
      const code = header === null || !/^Bearer \S+$/.test(header)
        ? "authentication_required"
        : "invalid_session";
      await response(f.handlers()[name], f.request(validInputs[name], header), 401, code);
      assert(rpcCalls(f).length === 0 && f.effects.length === 0);
    }
  }
});

Deno.test("every endpoint enforces JSON object encoding and streamed 8 KiB limit", async () => {
  for (const name of Object.keys(validInputs) as Array<keyof typeof validInputs>) {
    const f = fixture();
    f.rpc("is_cleanup_admin", true);
    for (
      const [raw, type, status, code] of [
        ["{}", "text/plain", 415, "json_required"],
        ["{}", "application/jsonp", 415, "json_required"],
        ["[]", "application/json", 400, "invalid_json"],
        ["null", "application/json", 400, "invalid_json"],
        ["{", "application/json", 400, "invalid_json"],
      ] as const
    ) {
      await response(
        f.handlers()[name],
        new Request("https://edge.invalid", {
          method: "POST",
          headers: { authorization: `Bearer ${f.valid}`, "content-type": type },
          body: raw,
        }),
        status,
        code,
      );
    }
    let cancelled = false;
    const stream = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(new Uint8Array(4096));
        controller.enqueue(new Uint8Array(4097));
      },
      cancel() {
        cancelled = true;
        throw new Error(privateMarker);
      },
    });
    await response(
      f.handlers()[name],
      new Request("https://edge.invalid", {
        method: "POST",
        headers: {
          authorization: `Bearer ${f.valid}`,
          "content-type": "application/json",
          "content-length": "1",
        },
        body: stream,
      }),
      413,
      "body_too_large",
    );
    assert(cancelled);
    assert(rpcCalls(f).every((c) => c.path.endsWith("is_cleanup_admin")));
    assert(f.effects.length === 0);
  }
});

Deno.test("endpoint field allowlists reject supplied owner storage paths and removed targets", async () => {
  for (const name of Object.keys(validInputs) as Array<keyof typeof validInputs>) {
    for (const field of ["owner_id", "object_key", "post_id"]) {
      const f = fixture();
      f.env.MEDIA_PIPELINE_ENABLED = "true";
      f.rpc("is_cleanup_admin", true);
      await response(
        f.handlers()[name],
        f.request({ ...validInputs[name], [field]: other }),
        400,
        name === "media" ? "invalid_upload" : "unknown_field",
      );
      assert(rpcCalls(f).every((c) => c.path.endsWith("is_cleanup_admin")));
      assert(f.effects.length === 0);
    }
  }
});

Deno.test("missing public configuration fails closed before any external operation", async () => {
  for (const name of Object.keys(validInputs) as Array<keyof typeof validInputs>) {
    for (const missing of ["SUPABASE_URL", "SUPABASE_PUBLISHABLE_KEYS"]) {
      const f = fixture();
      delete f.env[missing];
      await response(
        f.handlers()[name],
        f.request(validInputs[name]),
        503,
        "service_not_configured",
      );
      assert(f.calls.length === 0 && f.effects.length === 0);
    }
  }
});

Deno.test("contact validates explicit consent and listing before caller-scoped RPC", async () => {
  const f = fixture();
  const handler = f.handlers().contact;
  for (const consent of [false, "true", undefined]) {
    await response(
      handler,
      f.request({ listing_id: id, explicit_consent: consent }),
      403,
      "consent_required",
    );
  }
  await response(
    handler,
    f.request({ listing_id: "../key", explicit_consent: true }),
    400,
    "invalid_id",
  );
  assert(rpcCalls(f).length === 0);
  f.rpc("reveal_listing_contact", [{ phone: "synthetic-contact" }]);
  const data = await response(handler, f.request(validInputs.contact), 200);
  assert(data.contact.phone === "synthetic-contact");
  const call = rpcCalls(f)[0];
  assert(call.authorization === `Bearer ${f.valid}` && call.apikey === publicKey);
  assert(call.body.p_listing === id && call.body.p_explicit_consent === true);
  assert(f.effects.length === 0);
});

Deno.test("contact RPC denials empty results and transport failures never leak details", async () => {
  const f = fixture();
  const handler = f.handlers().contact;
  f.rpc("reveal_listing_contact", { message: privateMarker, code: "42501" }, 403);
  await response(handler, f.request(validInputs.contact), 403, "contact_denied");
  f.rpc("reveal_listing_contact", []);
  await response(handler, f.request(validInputs.contact), 404, "contact_unavailable");
  f.routes.set("/rest/v1/rpc/reveal_listing_contact", () => {
    throw new Error(privateMarker);
  });
  await response(handler, f.request(validInputs.contact), 403, "contact_denied");
});

Deno.test("public media read keeps anonymous and verified caller contexts separate", async () => {
  for (const header of [null, `Bearer ${publicKey}`, "Bearer synthetic-old-public", "verified"]) {
    const f = fixture();
    f.env.SUPABASE_ANON_KEY = "synthetic-old-public";
    f.routes.set("/rest/v1/media", () => reply([{ object_key: "verified/allowed.jpg" }]));
    await response(
      f.handlers().mediaRead,
      f.request(validInputs.mediaRead, header === "verified" ? `Bearer ${f.valid}` : header),
      200,
    );
    const read = rpcCalls(f)[0];
    assert(read.apikey === publicKey);
    assert(read.authorization === `Bearer ${header === "verified" ? f.valid : publicKey}`);
    assert(read.search.includes(`id=eq.${id}`) && read.search.includes("select=object_key"));
    assert(
      f.calls.filter((c) => c.path === "/auth/v1/user").length === (header === "verified" ? 1 : 0),
    );
    assert(f.effects.join(",") === "read:verified/allowed.jpg");
  }
});

Deno.test("public media read never falls back after rejected or malformed tokens", async () => {
  for (
    const header of [
      "Basic token",
      "Bearer expired",
      `Bearer ${serviceKey}`,
      "Bearer wrong-project",
    ]
  ) {
    const f = fixture();
    await response(
      f.handlers().mediaRead,
      f.request(validInputs.mediaRead, header),
      401,
      "invalid_session",
    );
    assert(rpcCalls(f).length === 0 && f.effects.length === 0);
  }
});

Deno.test("media reads sign only RLS-visible object keys and conceal missing or failed reads", async () => {
  for (const name of ["media", "mediaRead"] as const) {
    const f = fixture();
    const input = name === "media" ? { action: "read", media_id: id } : validInputs.mediaRead;
    f.routes.set("/rest/v1/media", () => reply([]));
    await response(f.handlers()[name], f.request(input), 404, "media_not_found");
    f.routes.set("/rest/v1/media", () => reply({ message: privateMarker }, 503));
    await response(f.handlers()[name], f.request(input), 404, "media_not_found");
    assert(f.effects.length === 0);
    f.routes.set("/rest/v1/media", () => reply([{ object_key: "verified/rls-winner.jpg" }]));
    await response(f.handlers()[name], f.request(input), 200);
    assert(f.effects.join(",") === "read:verified/rls-winner.jpg");
  }
});

Deno.test("media mutations remain off for absent false and non-exact flags", async () => {
  for (const enabled of [undefined, "false", "TRUE", "1", " true "]) {
    const f = fixture();
    if (enabled === undefined) delete f.env.MEDIA_PIPELINE_ENABLED;
    else f.env.MEDIA_PIPELINE_ENABLED = enabled;
    for (const input of [validInputs.media, { action: "complete", intent_id: id }]) {
      await response(f.handlers().media, f.request(input), 503, "media_pipeline_unavailable");
    }
    assert(rpcCalls(f).length === 0 && f.effects.length === 0);
  }
});

Deno.test("invalid media and lifecycle actions never construct a privileged client", async () => {
  for (const action of [undefined, null, 1, {}, ["cleanup"], ["read"], "erase", "__proto__"]) {
    const f = fixture();
    f.rpc("is_cleanup_admin", true);
    delete f.env.SUPABASE_SECRET_KEYS;
    await response(f.handlers().media, f.request({ action }), 400, "invalid_action");
    await response(f.handlers().lifecycle, f.request({ action }), 400, "invalid_action");
    assert(f.effects.length === 0);
  }
});

Deno.test("media reservation checks every R2 setting before consuming quota", async () => {
  for (
    const missing of ["R2_ACCOUNT_ID", "R2_BUCKET", "R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY"]
  ) {
    const f = fixture();
    f.env.MEDIA_PIPELINE_ENABLED = "true";
    delete f.env[missing];
    await response(f.handlers().media, f.request(validInputs.media), 503, "service_not_configured");
    await response(
      f.handlers().media,
      f.request({ action: "complete", intent_id: id }),
      503,
      "service_not_configured",
    );
    assert(rpcCalls(f).length === 0 && f.effects.length === 0);
  }
  const f = fixture();
  f.env.MEDIA_PIPELINE_ENABLED = "true";
  f.env.R2_ACCOUNT_ID = "attacker.invalid/path";
  await response(f.handlers().media, f.request(validInputs.media), 503, "service_not_configured");
  assert(rpcCalls(f).length === 0);
});

Deno.test("reserve uses caller identity and database-issued immutable key and size", async () => {
  const f = fixture();
  f.env.MEDIA_PIPELINE_ENABLED = "true";
  f.rpc("reserve_upload", {
    id,
    object_key: "quarantine/assigned.jpg",
    expected_bytes: 100,
    expected_mime: "image/jpeg",
  });
  const data = await response(f.handlers().media, f.request(validInputs.media), 200);
  assert(data.intent_id === id && data.expires_in === 120);
  assert(
    data.required_headers["If-None-Match"] === "*" &&
      data.required_headers["Content-Length"] === "100",
  );
  const call = rpcCalls(f)[0];
  assert(call.authorization === `Bearer ${f.valid}` && call.apikey === publicKey);
  assert(
    JSON.stringify(call.body) ===
      JSON.stringify({ p_listing: id, p_bytes: 100, p_mime: "image/jpeg" }),
  );
  assert(f.effects.join(",") === "sign:quarantine/assigned.jpg");
});

Deno.test("reservation failure never signs an upload", async () => {
  for (const data of [null, { code: "42501", message: privateMarker }]) {
    const f = fixture();
    f.env.MEDIA_PIPELINE_ENABLED = "true";
    f.rpc("reserve_upload", data, data ? 403 : 200);
    await response(f.handlers().media, f.request(validInputs.media), 403, "upload_denied");
    assert(f.effects.length === 0);
  }
});

function prepareMedia(f: ReturnType<typeof fixture>) {
  f.env.MEDIA_PIPELINE_ENABLED = "true";
  f.rpc("prepare_media_verification", [{
    intent_id: id,
    source_key: "quarantine/source.jpg",
    expected_bytes: jpeg().length,
    clean_key: "verified/unique.jpg",
    existing_media: null,
    expires_at: new Date(Date.now() + 120000).toISOString(),
  }]);
  f.rpc("commit_verified_media", [{ media_id: id, published_key: "verified/unique.jpg" }]);
}

Deno.test("complete validates metadata before privileged state changes", async () => {
  const f = fixture();
  f.env.MEDIA_PIPELINE_ENABLED = "true";
  for (
    const [input, code] of [
      [{ action: "complete", intent_id: id, owner_id: other }, "unknown_field"],
      [{ action: "complete", intent_id: "path" }, "invalid_id"],
      [{ action: "complete", intent_id: id, alt_text: 42 }, "invalid_alt_text"],
      [{ action: "complete", intent_id: id, alt_text: "x".repeat(501) }, "invalid_alt_text"],
    ] as const
  ) {
    await response(f.handlers().media, f.request(input), 400, code);
  }
  assert(rpcCalls(f).length === 0 && f.effects.length === 0);
});

Deno.test("complete separates service RPCs from caller token and derives authenticated owner", async () => {
  const f = fixture();
  prepareMedia(f);
  const data = await response(
    f.handlers().media,
    f.request({ action: "complete", intent_id: id, alt_text: "synthetic alt" }),
    200,
  );
  assert(data.media_id === id && data.status === "verified");
  const calls = rpcCalls(f);
  assert(calls.length === 2);
  assert(
    calls.every((c) =>
      c.authorization === `Bearer ${serviceKey}` && c.apikey === serviceKey &&
      c.body.p_owner === owner && c.body.p_intent === id
    ),
  );
  assert(calls[1].body.p_alt === "synthetic alt");
  assert(f.effects.join(",") === "service-client,download,write");
});

Deno.test("failed prepare stops storage and failed commit never deletes possibly published winner", async () => {
  const f = fixture();
  prepareMedia(f);
  f.rpc("prepare_media_verification", { code: "42501", message: privateMarker }, 403);
  await response(
    f.handlers().media,
    f.request({ action: "complete", intent_id: id }),
    409,
    "verification_denied",
  );
  assert(f.effects.join(",") === "service-client");
  prepareMedia(f);
  f.rpc("commit_verified_media", { message: privateMarker }, 503);
  await response(
    f.handlers().media,
    f.request({ action: "complete", intent_id: id }),
    409,
    "verification_pending_retry",
  );
  assert(f.effects.every((effect) => !effect.startsWith("remove:")));
});

Deno.test("concurrent complete requests are bounded and failure releases isolate guard", async () => {
  const f = fixture();
  prepareMedia(f);
  let unblock!: () => void;
  let downloading!: () => void;
  const entered = new Promise<void>((resolve) => downloading = resolve);
  const blocked = new Promise<void>((resolve) => unblock = resolve);
  const handler = createMediaHandler({
    ...f.auth,
    ...f.storage,
    downloadImage: async () => {
      downloading();
      await blocked;
      throw new Error(privateMarker);
    },
  });
  const first = response(
    handler,
    f.request({ action: "complete", intent_id: id }),
    500,
    "internal_error",
  );
  await entered;
  await response(
    handler,
    f.request({ action: "complete", intent_id: id }),
    429,
    "verification_busy",
  );
  unblock();
  await first;
  await response(handler, f.request({ action: "complete", intent_id: id }), 500, "internal_error");
  assert(rpcCalls(f).filter((c) => c.path.endsWith("prepare_media_verification")).length === 2);
});

Deno.test("account deletion rejects missing confirmation stale refresh and different-session claims", async () => {
  const f = fixture();
  await response(
    f.handlers().accountDelete,
    f.request({ confirmation: "delete" }),
    400,
    "deletion_confirmation_required",
  );
  for (
    const overrides of [
      { sub: other },
      { session_id: undefined },
      { session_id: "../id" },
      { amr: [{ method: "token_refresh", timestamp: Math.floor(Date.now() / 1000) }] },
      {
        amr: [{ method: "oauth", timestamp: Math.floor(Date.now() / 1000) - 601 }],
        iat: Math.floor(Date.now() / 1000),
      },
    ]
  ) {
    const stale = token(overrides);
    f.accepted.add(stale); // Auth accepts the session; recent-login gate must still reject it.
    await response(
      f.handlers().accountDelete,
      f.request(validInputs.accountDelete, `Bearer ${stale}`),
      403,
      "recent_sign_in_required",
    );
  }
  assert(rpcCalls(f).length === 0 && f.effects.length === 0);
});

Deno.test("account deletion uses verified session owner with separate service credentials", async () => {
  const f = fixture();
  f.rpc("begin_account_deletion", job({ not_before: new Date(Date.now() + 60000).toISOString() }));
  const data = await response(
    f.handlers().accountDelete,
    f.request(validInputs.accountDelete),
    202,
  );
  assert(data.status === "pending" && data.retry_after_seconds > 0);
  const call = rpcCalls(f)[0];
  assert(call.authorization === `Bearer ${serviceKey}` && call.apikey === serviceKey);
  assert(
    call.body.p_owner === owner && call.body.p_session === session &&
      typeof call.body.p_auth_at === "number",
  );
  assert(rpcCalls(f).length === 1);
});

Deno.test("account deletion rejects changed auth state and mismatched returned owner", async () => {
  const f = fixture();
  f.rpc("begin_account_deletion", { code: "42501", message: privateMarker }, 403);
  await response(
    f.handlers().accountDelete,
    f.request(validInputs.accountDelete),
    403,
    "recent_sign_in_required",
  );
  f.rpc("begin_account_deletion", null);
  await response(
    f.handlers().accountDelete,
    f.request(validInputs.accountDelete),
    503,
    "deletion_unavailable",
  );
  f.rpc("begin_account_deletion", job({ owner_id: other }));
  await response(
    f.handlers().accountDelete,
    f.request(validInputs.accountDelete),
    500,
    "invalid_deletion_job",
  );
  assert(rpcCalls(f).every((c) => c.path.endsWith("begin_account_deletion")));
});

function prepareDeletion(f: ReturnType<typeof fixture>) {
  f.rpc("begin_account_deletion", job());
  f.rpc("list_cleanup_objects", [{ object_key: "registered/object.jpg" }]);
  f.rpc("mark_object_deleted", null);
  f.rpc("deletion_ready_for_auth", owner);
  f.routes.set(`DELETE /auth/v1/admin/users/${owner}`, () => reply({ user: { id: owner } }));
  f.rpc("finish_account_deletion", null);
  f.rpc("record_deletion_failure", null);
}

Deno.test("account deletion cleanup fence and database readiness precede Auth deletion", async () => {
  const f = fixture();
  prepareDeletion(f);
  const data = await response(
    f.handlers().accountDelete,
    f.request(validInputs.accountDelete),
    200,
  );
  assert(data.status === "completed");
  assert(
    f.calls.map((c) => c.path.split("/").at(-1)).join(",") ===
      `user,begin_account_deletion,list_cleanup_objects,mark_object_deleted,deletion_ready_for_auth,${owner},finish_account_deletion`,
  );
  assert(rpcCalls(f).find((c) => c.path.endsWith("mark_object_deleted"))?.body.p_fenced === true);
  assert(
    f.calls.filter((c) => c.path !== "/auth/v1/user").every((c) =>
      c.authorization === `Bearer ${serviceKey}`
    ),
  );
});

Deno.test("deletion retry preserves pending state after new objects storage failure or unproven fence", async () => {
  for (const stage of ["new-object", "storage-failed", "unproven", "mark-failed"] as const) {
    const f = fixture();
    prepareDeletion(f);
    if (stage === "new-object") {
      f.rpc("deletion_ready_for_auth", { message: "Cleanup pending" }, 409);
    }
    if (stage === "storage-failed") {
      f.storage.removePayloadAndFence = () => Promise.reject(new Error(privateMarker));
    }
    if (stage === "unproven") f.storage.removePayloadAndFence = () => Promise.resolve(false);
    if (stage === "mark-failed") {
      f.rpc("mark_object_deleted", { code: "42501", message: privateMarker }, 403);
    }
    const data = await response(
      f.handlers().accountDelete,
      f.request(validInputs.accountDelete),
      202,
    );
    assert(data.status === "pending");
    assert(!f.calls.some((c) => c.path.includes("/admin/users/")));
    if (stage === "new-object") assert(data.blocker_code === null);
    if (stage === "mark-failed") {
      assert(data.requires_operator && data.blocker_code === "database_configuration_required");
    }
    if (stage === "unproven") {
      assert(!rpcCalls(f).some((c) => c.path.endsWith("mark_object_deleted")));
    }
  }
});

Deno.test("Auth deletion race succeeds only when independent lookup proves user is absent", async () => {
  for (const absent of [true, false]) {
    const f = fixture();
    prepareDeletion(f);
    f.routes.set(
      `DELETE /auth/v1/admin/users/${owner}`,
      () => reply({ message: privateMarker }, 500),
    );
    f.routes.set(
      `GET /auth/v1/admin/users/${owner}`,
      () =>
        absent
          ? reply({ code: "user_not_found", message: privateMarker }, 404)
          : reply({ user: { id: owner } }),
    );
    const data = await response(
      f.handlers().accountDelete,
      f.request(validInputs.accountDelete),
      absent ? 200 : 202,
    );
    assert(data.status === (absent ? "completed" : "pending"));
    assert(rpcCalls(f).some((c) => c.path.endsWith("finish_account_deletion")) === absent);
    if (!absent) assert(data.blocker_code === "auth_retry_required");
  }
});

Deno.test("Auth permission and bookkeeping failures remain pending with sanitized classifications", async () => {
  for (const stage of ["auth", "finish", "record-failure"] as const) {
    const f = fixture();
    prepareDeletion(f);
    if (stage === "auth") {
      f.routes.set(
        `DELETE /auth/v1/admin/users/${owner}`,
        () => reply({ message: privateMarker }, 403),
      );
    } else f.rpc("finish_account_deletion", { message: privateMarker }, 503);
    if (stage === "record-failure") {
      f.rpc("record_deletion_failure", { message: privateMarker }, 503);
    }
    const data = await response(
      f.handlers().accountDelete,
      f.request(validInputs.accountDelete),
      202,
    );
    assert(
      data.blocker_code ===
        (stage === "auth" ? "auth_configuration_required" : "completion_retry_required"),
    );
    assert(data.requires_operator === (stage === "auth"));
  }
});

Deno.test("lifecycle authenticates admin role on caller RLS before creating service client", async () => {
  for (const allowed of [false, null, "true", { message: privateMarker }]) {
    const f = fixture();
    f.rpc("is_cleanup_admin", allowed, typeof allowed === "object" && allowed !== null ? 403 : 200);
    await response(f.handlers().lifecycle, f.request(validInputs.lifecycle), 403, "admin_required");
    const call = rpcCalls(f)[0];
    assert(call.authorization === `Bearer ${f.valid}` && call.apikey === publicKey);
    assert(f.effects.length === 0);
  }
});

Deno.test("lifecycle scheduler credential scope and admin-only scope are checked before service setup", async () => {
  const f = fixture();
  delete f.env.SUPABASE_SECRET_KEYS;
  f.rpc("is_cleanup_admin", true);
  for (const action of ["cleanup", "deletion_job", "invalid"]) {
    const req = f.request({ action }, null);
    req.headers.set("x-lifecycle-job-secret", jobSecret);
    await response(f.handlers().lifecycle, req, 403, "job_scope_denied");
  }
  await response(
    f.handlers().lifecycle,
    f.request({ action: "scheduled" }),
    403,
    "job_authorization_required",
  );
  await response(
    f.handlers().lifecycle,
    f.request({ action: "deletion_job", job_id: "../private" }),
    400,
    "invalid_id",
  );
  for (const configured of [undefined, "short", jobSecret]) {
    if (configured === undefined) delete f.env.LIFECYCLE_JOB_SECRET;
    else f.env.LIFECYCLE_JOB_SECRET = configured;
    const req = f.request({ action: "scheduled" });
    req.headers.set("x-lifecycle-job-secret", "wrong");
    await response(f.handlers().lifecycle, req, 403, "job_authorization_denied");
  }
  assert(f.effects.length === 0);
});

Deno.test("scheduled lifecycle uses only service credentials and cleans one small orphan batch", async () => {
  const f = fixture();
  f.rpc("claim_due_deletion_job", []);
  f.rpc("list_cleanup_objects", [1, 2, 3].map((n) => ({ object_key: `orphan/${n}` })));
  f.rpc("mark_object_deleted", null);
  const req = f.request({ action: "scheduled" }, null);
  req.headers.set("x-lifecycle-job-secret", jobSecret);
  const data = await response(f.handlers().lifecycle, req, 200);
  assert(data.deleted === 3 && data.more_may_remain);
  assert(!f.calls.some((c) => c.path === "/auth/v1/user"));
  assert(f.calls.every((c) => c.authorization === `Bearer ${serviceKey}`));
  assert(rpcCalls(f).find((c) => c.path.endsWith("list_cleanup_objects"))?.body.p_limit === 3);
  assert(f.effects.join(",") === "service-client,remove:orphan/1,remove:orphan/2,remove:orphan/3");
});

Deno.test("lifecycle claim failure stops cleanup and a claimed future job returns 202", async () => {
  const f = fixture();
  const scheduled = () => {
    const req = f.request({ action: "scheduled" }, null);
    req.headers.set("x-lifecycle-job-secret", jobSecret);
    return req;
  };
  f.rpc("claim_due_deletion_job", { message: privateMarker }, 503);
  await response(f.handlers().lifecycle, scheduled(), 503, "cleanup_unavailable");
  f.rpc("claim_due_deletion_job", [
    job({ not_before: new Date(Date.now() + 30000).toISOString() }),
  ]);
  const data = await response(f.handlers().lifecycle, scheduled(), 202);
  assert(data.status === "pending");
  assert(rpcCalls(f).every((c) => c.path.endsWith("claim_due_deletion_job")));
});

Deno.test("lifecycle cleanup failures do not mark unfenced objects or report false success", async () => {
  for (const stage of ["list", "remove", "mark"] as const) {
    const f = fixture();
    f.rpc("is_cleanup_admin", true);
    f.rpc("list_cleanup_objects", [{ object_key: "orphan/one" }]);
    if (stage === "list") f.rpc("list_cleanup_objects", { message: privateMarker }, 503);
    if (stage === "remove") f.storage.removePayloadAndFence = () => Promise.resolve(false);
    if (stage === "mark") {
      f.rpc("mark_object_deleted", { code: "42501", message: privateMarker }, 403);
    }
    await response(
      f.handlers().lifecycle,
      f.request(validInputs.lifecycle),
      stage === "remove" ? 502 : 503,
      stage === "list"
        ? "cleanup_unavailable"
        : stage === "remove"
        ? "cleanup_fencing_unproven"
        : "database_configuration_required",
    );
    if (stage !== "mark") assert(!rpcCalls(f).some((c) => c.path.endsWith("mark_object_deleted")));
  }
});

Deno.test("missing service configuration and capacity exceptions fail closed without privileged requests", async () => {
  const f = fixture();
  f.env.MEDIA_PIPELINE_ENABLED = "true";
  f.rpc("is_cleanup_admin", true);
  delete f.env.SUPABASE_SECRET_KEYS;
  for (
    const [name, input] of [
      ["accountDelete", validInputs.accountDelete],
      ["lifecycle", validInputs.lifecycle],
      ["media", { action: "complete", intent_id: id }],
    ] as const
  ) {
    await response(f.handlers()[name], f.request(input), 503, "service_not_configured");
  }
  assert(rpcCalls(f).every((c) => c.path.endsWith("is_cleanup_admin")));
  const handler = createMediaHandler({
    ...f.auth,
    ...f.storage,
    capacity: () => {
      throw new ApiError(503, "image_verifier_busy");
    },
  });
  await response(
    handler,
    f.request({ action: "complete", intent_id: id }),
    503,
    "image_verifier_busy",
  );
});

Deno.test("media signing and write exceptions are caught without publishing or exposing signed URLs", async () => {
  for (const stage of ["read", "reserve", "write"] as const) {
    const f = fixture();
    prepareMedia(f);
    f.routes.set("/rest/v1/media", () => reply([{ object_key: "verified/private.jpg" }]));
    f.rpc("reserve_upload", {
      id,
      object_key: "quarantine/private.jpg",
      expected_bytes: 100,
      expected_mime: "image/jpeg",
    });
    const fail = () => Promise.reject(new Error(privateMarker));
    const handler = createMediaHandler({
      ...f.auth,
      ...f.storage,
      ...(stage === "read"
        ? { signRead: fail }
        : stage === "reserve"
        ? { signUpload: fail }
        : { writeVerified: fail }),
    });
    const input = stage === "read"
      ? { action: "read", media_id: id }
      : stage === "reserve"
      ? validInputs.media
      : { action: "complete", intent_id: id };
    await response(handler, f.request(input), 500, "internal_error");
    assert(!rpcCalls(f).some((c) => c.path.endsWith("commit_verified_media")));
    assert(!f.effects.some((e) => e.startsWith("remove:")));
  }
});

Deno.test("media completion replays avoid storage and definite racing loser cannot delete winner", async () => {
  for (const stage of ["replay", "race"] as const) {
    const f = fixture();
    prepareMedia(f);
    if (stage === "replay") f.rpc("prepare_media_verification", [{ existing_media: id }]);
    else f.rpc("commit_verified_media", [{ media_id: id, published_key: "verified/winner.jpg" }]);
    const data = await response(
      f.handlers().media,
      f.request({ action: "complete", intent_id: id }),
      200,
    );
    assert(data.media_id === id);
    assert(
      f.effects.join(",") ===
        (stage === "replay"
          ? "service-client"
          : "service-client,download,write,remove:verified/unique.jpg"),
    );
    assert(!f.effects.includes("remove:verified/winner.jpg"));
  }
});

Deno.test("lifecycle explicit job lookup validates result and preserves pending or completed status", async () => {
  const f = fixture();
  f.rpc("is_cleanup_admin", true);
  for (
    const [rows, status, code] of [
      [[], 404, "deletion_job_not_found"],
      [[job({ state: "completed" })], 200, undefined],
      [[job({ not_before: new Date(Date.now() + 60000).toISOString() })], 202, undefined],
    ] as const
  ) {
    f.rpc("get_deletion_job", rows);
    await response(
      f.handlers().lifecycle,
      f.request({ action: "deletion_job", job_id: id }),
      status,
      code,
    );
  }
  const lookup = rpcCalls(f).filter((c) => c.path.endsWith("get_deletion_job"));
  assert(
    lookup.length === 3 &&
      lookup.every((c) => c.body.p_job === id && c.authorization === `Bearer ${serviceKey}`),
  );
  assert(f.effects.every((e) => e === "service-client"));
});

Deno.test("deletion storage permission and missing configuration errors become operator blockers", async () => {
  for (
    const [failure, code] of [
      [new ApiError(503, "service_not_configured"), "storage_configuration_required"],
      [
        { $metadata: { httpStatusCode: 403 }, message: privateMarker },
        "storage_permission_required",
      ],
    ] as const
  ) {
    const f = fixture();
    prepareDeletion(f);
    f.storage.removePayloadAndFence = () => Promise.reject(failure);
    const data = await response(
      f.handlers().accountDelete,
      f.request(validInputs.accountDelete),
      202,
    );
    assert(
      data.blocker_code === code && data.requires_operator && data.retry_after_seconds === 3600,
    );
    assert(!f.calls.some((c) => c.path.includes("/admin/users/")));
    const recorded = rpcCalls(f).find((c) => c.path.endsWith("record_deletion_failure"));
    assert(recorded?.body.p_job === id && recorded?.body.p_code === code);
  }
});

Deno.test("deletion readiness owner mismatch cannot delete either Auth account", async () => {
  const f = fixture();
  prepareDeletion(f);
  f.rpc("deletion_ready_for_auth", other);
  const data = await response(
    f.handlers().accountDelete,
    f.request(validInputs.accountDelete),
    202,
  );
  assert(data.status === "pending");
  assert(!f.calls.some((c) => c.path.includes("/admin/users/")));
});
