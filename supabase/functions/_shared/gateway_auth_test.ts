// Direct handler calls intentionally bypass the legacy JWT gateway. The actual
// Supabase SDK uses an in-memory Auth/PostgREST transport, not a crypto verifier.
// ES256-shaped tokens below have no valid signature and confer no real access.
// Fixture acceptance proves handler wiring only, never hosted ES256 verification.
import { assert, jpeg } from "./test_fixtures.ts";
import {
  fixture,
  id,
  other,
  owner,
  privateMarker,
  publicKey,
  reply,
  serviceKey,
  session,
} from "./endpoint_fixtures.ts";

function encode(value: unknown): string {
  return btoa(JSON.stringify(value)).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}
function modernToken(overrides: Record<string, unknown> = {}): string {
  const now = Math.floor(Date.now() / 1000);
  return [
    encode({ alg: "ES256", typ: "JWT", kid: "synthetic-only-no-signing-key" }),
    encode({
      iss: "https://synthetic-project.invalid/auth/v1",
      aud: "authenticated",
      sub: owner,
      role: "authenticated",
      iat: now - 10,
      exp: now + 3600,
      session_id: session,
      amr: [{ method: "oauth", timestamp: now - 10 }],
      ...overrides,
    }),
    // 64 zero bytes have ES256 signature length, but are deliberately not signed.
    btoa("\0".repeat(64)).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_"),
  ].join(".");
}
function rejectedTokens() {
  const forged = modernToken({ sub: other, role: "service_role", app_metadata: { role: "admin" } });
  const [header] = forged.split(".");
  return [
    ["forged current claims", forged],
    ["expired claims", modernToken({ exp: 1, iat: 0 })],
    ["wrong issuer", modernToken({ iss: "https://wrong-project.invalid/auth/v1" })],
    ["invalid claims encoding", `${header}.not_valid_json.synthetic`],
    ["truncated signature", `${header}.${encode({ sub: owner })}.`],
    ["extra segment", `${forged}.extra`],
    ["public API key", publicKey],
    ["secret API key", serviceKey],
    ["legacy anon JWT", `${encode({ alg: "HS256" })}.${encode({ role: "anon" })}.synthetic`],
    [
      "legacy service JWT",
      `${encode({ alg: "HS256" })}.${encode({ role: "service_role" })}.synthetic`,
    ],
  ] as const;
}
const protectedInputs = [
  ["contact", { listing_id: id, explicit_consent: true }],
  ["media", { action: "read", media_id: id }],
  ["media", { action: "reserve", listing_id: id, bytes: 100, mime: "image/jpeg" }],
  ["media", { action: "complete", intent_id: id }],
  ["accountDelete", { confirmation: "DELETE_MY_ACCOUNT" }],
  ["lifecycle", { action: "cleanup" }],
  ["lifecycle", { action: "deletion_job", job_id: id }],
  ["lifecycle", { action: "scheduled" }],
] as const;
const userInputs = [...protectedInputs, ["mediaRead", { media_id: id }]] as const;
type Fixture = ReturnType<typeof fixture>;
async function result(response: Response, status: number, code?: string) {
  const data = await response.json();
  assert(response.status === status);
  assert(response.headers.get("cache-control") === "no-store");
  assert(!JSON.stringify(data).includes(privateMarker));
  if (code) assert(data.error === code);
  return data;
}
function authOnly(f: Fixture, bearer: string) {
  // No DB, service-client construction, storage signing, download or mutation.
  assert(f.calls.length === 1);
  assert(f.calls[0].method === "GET" && f.calls[0].path === "/auth/v1/user");
  assert(f.calls[0].authorization === bearer && f.calls[0].apikey === publicKey);
  assert(f.effects.length === 0);
}
function accept(f: Fixture, value = modernToken()): string {
  f.accepted.add(value); // Synthetic transport acceptance, not signature verification.
  return `Bearer ${value}`;
}

Deno.test("gateway bypass cannot promote ES256-shaped claims or API credentials to protected callers", async () => {
  for (const [_case, value] of rejectedTokens()) {
    for (const [name, input] of protectedInputs) {
      const f = fixture();
      // Prove auth, not the disabled-media flag, is stopping every action.
      f.env.MEDIA_PIPELINE_ENABLED = "true";
      const bearer = `Bearer ${value}`;
      const req = f.request(input, bearer);
      req.headers.set("apikey", publicKey);
      await result(await f.handlers()[name](req), 401, "invalid_session");
      authOnly(f, bearer);
    }
  }
});

Deno.test("gateway bypass does not treat an apikey header as a protected user session", async () => {
  for (const key of [publicKey, serviceKey]) {
    for (const [name, input] of protectedInputs) {
      const f = fixture();
      const req = f.request(input, null);
      req.headers.set("apikey", key);
      await result(await f.handlers()[name](req), 401, "authentication_required");
      assert(f.calls.length === 0 && f.effects.length === 0);
    }
  }
});

Deno.test("Auth denial or missing user stops all handlers even with convincing modern claims", async () => {
  for (const denial of ["revoked", "missing-user", "unavailable"] as const) {
    for (const [name, input] of userInputs) {
      const f = fixture();
      const bearer = accept(f, modernToken({ app_metadata: { role: "admin" } }));
      f.env.MEDIA_PIPELINE_ENABLED = "true";
      // Auth's missing-user error normalizes to data.user=null in the real SDK.
      // HTTP 200 {user:null} would instead normalize to that whole response object.
      f.routes.set(
        "/auth/v1/user",
        () =>
          reply(
            {
              code: denial === "missing-user" ? "user_not_found" : "bad_jwt",
              message: privateMarker,
            },
            denial === "missing-user" ? 404 : denial === "revoked" ? 401 : 503,
          ),
      );
      await result(await f.handlers()[name](f.request(input, bearer)), 401, "invalid_session");
      authOnly(f, bearer);
    }
  }
});

Deno.test("malformed Auth success identities fail closed through actual SDK normalization", async () => {
  for (
    const authResponse of [
      { user: null },
      {},
      null,
      [],
      "not-a-user",
      123,
      true,
      { id: null },
      { id: 123 },
      { id: [] },
      { id: "" },
      { id: "not-a-uuid" },
      { id: "00000000-0000-0000-0000-000000000000" },
      { id: "00000000-0000-4000-0000-000000000001" },
      { id: `${owner}/extra` },
      { user: "not-a-user" },
      { user: [] },
      { user: {} },
      { user: { id: "not-a-uuid" } },
    ]
  ) {
    for (const [name, input] of userInputs) {
      const f = fixture();
      const bearer = accept(f);
      f.env.MEDIA_PIPELINE_ENABLED = "true";
      f.routes.set("/auth/v1/user", () => reply(authResponse));
      await result(await f.handlers()[name](f.request(input, bearer)), 401, "invalid_session");
      authOnly(f, bearer);
    }
  }
});

Deno.test("valid flat and wrapped Auth identities remain authoritative after SDK normalization", async () => {
  for (const verifiedId of [owner, other]) {
    for (const wrapped of [false, true]) {
      const f = fixture();
      const bearer = accept(f, modernToken({ sub: verifiedId === owner ? other : owner }));
      const user = {
        id: verifiedId,
        aud: "authenticated",
        role: "authenticated",
        created_at: "2026-01-01T00:00:00Z",
        app_metadata: {},
        user_metadata: {},
      };
      f.routes.set("/auth/v1/user", () => reply(wrapped ? { user } : user));
      const verified = await f.auth.authenticated(f.request({}, bearer));
      assert(verified.user.id === verifiedId);
      assert(verified.token === bearer.slice(7));
      authOnly(f, bearer);
      f.rpc("is_cleanup_admin", false);
      await verified.client.rpc("is_cleanup_admin");
      assert(f.calls.length === 2 && f.calls[1].path === "/rest/v1/rpc/is_cleanup_admin");
      assert(f.calls[1].authorization === bearer && f.calls[1].apikey === publicKey);
      assert(f.effects.length === 0);
    }
  }
});

Deno.test("verified modern caller header is forwarded unchanged for contact and media RLS", async () => {
  for (const name of ["contact", "media", "mediaRead"] as const) {
    const f = fixture();
    const bearer = accept(f);
    f.rpc("reveal_listing_contact", [{ phone: "synthetic-contact" }]);
    f.routes.set("/rest/v1/media", () => reply([{ object_key: "verified/rls-visible.jpg" }]));
    const input = name === "contact"
      ? { listing_id: id, explicit_consent: true }
      : { ...(name === "media" ? { action: "read" } : {}), media_id: id };
    await result(await f.handlers()[name](f.request(input, bearer)), 200);
    assert(f.calls.length === 2 && f.calls[0].path === "/auth/v1/user");
    assert(f.calls[1].path.startsWith("/rest/v1/"));
    assert(f.calls.every((c) => c.authorization === bearer && c.apikey === publicKey));
    assert(!f.effects.includes("service-client"));
  }
});

Deno.test("privileged media owner comes from Auth user, never decoded ES256-shaped subject or role", async () => {
  const f = fixture();
  // Deliberately inconsistent Auth response/claims detects local claim trust.
  // Real Auth must validate signature and return the correct subject itself.
  const bearer = accept(f, modernToken({ sub: other, role: "service_role" }));
  f.env.MEDIA_PIPELINE_ENABLED = "true";
  f.rpc("prepare_media_verification", [{
    intent_id: id,
    source_key: "quarantine/synthetic.jpg",
    expected_bytes: jpeg().length,
    clean_key: "verified/synthetic.jpg",
    existing_media: null,
    expires_at: new Date(Date.now() + 120000).toISOString(),
  }]);
  f.rpc("commit_verified_media", [{ media_id: id, published_key: "verified/synthetic.jpg" }]);
  await result(
    await f.handlers().media(f.request({ action: "complete", intent_id: id }, bearer)),
    200,
  );
  assert(f.calls[0].path === "/auth/v1/user" && f.calls[0].authorization === bearer);
  const privileged = f.calls.slice(1);
  assert(privileged.length === 2);
  assert(
    privileged.every((c) =>
      c.body.p_owner === owner && c.authorization === `Bearer ${serviceKey}` &&
      c.apikey === serviceKey
    ),
  );
  assert(f.effects.join(",") === "service-client,download,write");
});

Deno.test("modern deletion claims are read only after Auth and must match its verified identity", async () => {
  for (const claimedOwner of [owner, other]) {
    const f = fixture();
    const bearer = accept(f, modernToken({ sub: claimedOwner }));
    f.rpc("begin_account_deletion", {
      id,
      owner_id: owner,
      state: "pending",
      not_before: new Date(Date.now() + 60000).toISOString(),
    });
    await result(
      await f.handlers().accountDelete(f.request({ confirmation: "DELETE_MY_ACCOUNT" }, bearer)),
      claimedOwner === owner ? 202 : 403,
      claimedOwner === owner ? undefined : "recent_sign_in_required",
    );
    if (claimedOwner !== owner) authOnly(f, bearer);
    else {
      assert(f.calls.length === 2 && f.calls[0].path === "/auth/v1/user");
      const call = f.calls[1];
      assert(call.path === "/rest/v1/rpc/begin_account_deletion");
      assert(call.body.p_owner === owner && call.body.p_session === session);
      assert(call.authorization === `Bearer ${serviceKey}` && call.apikey === serviceKey);
      assert(f.effects.join(",") === "service-client");
    }
  }
});

Deno.test("modern role claims cannot bypass lifecycle caller-RLS admin authorization", async () => {
  const f = fixture();
  const bearer = accept(f, modernToken({ role: "service_role", app_metadata: { role: "admin" } }));
  f.rpc("is_cleanup_admin", false);
  await result(
    await f.handlers().lifecycle(f.request({ action: "cleanup" }, bearer)),
    403,
    "admin_required",
  );
  assert(f.calls.length === 2 && f.calls[0].path === "/auth/v1/user");
  assert(f.calls[1].path === "/rest/v1/rpc/is_cleanup_admin");
  assert(f.calls.every((c) => c.authorization === bearer && c.apikey === publicKey));
  assert(f.effects.length === 0);
});

Deno.test("public media validates every supplied non-public token with no anonymous fallback", async () => {
  for (const [_case, value] of rejectedTokens()) {
    // The configured public key intentionally selects the anonymous RLS path.
    if (value === publicKey) continue;
    const f = fixture();
    const bearer = `Bearer ${value}`;
    // If a regression downgrades this request, a tempting public object is available.
    f.routes.set("/rest/v1/media", () => reply([{ object_key: "verified/public.jpg" }]));
    await result(
      await f.handlers().mediaRead(f.request({ media_id: id }, bearer)),
      401,
      "invalid_session",
    );
    authOnly(f, bearer);
  }
});

Deno.test("public media without a user stays on anonymous RLS and signs only visible rows", async () => {
  for (const authorization of [null, `Bearer ${publicKey}`]) {
    for (const visible of [false, true]) {
      const f = fixture();
      f.routes.set(
        "/rest/v1/media",
        () => reply(visible ? [{ object_key: "verified/public.jpg" }] : []),
      );
      await result(
        await f.handlers().mediaRead(f.request({ media_id: id }, authorization)),
        visible ? 200 : 404,
        visible ? undefined : "media_not_found",
      );
      assert(f.calls.length === 1 && f.calls[0].path === "/rest/v1/media");
      assert(f.calls[0].authorization === `Bearer ${publicKey}` && f.calls[0].apikey === publicKey);
      assert(f.effects.join(",") === (visible ? "read:verified/public.jpg" : ""));
    }
  }
});

Deno.test("verified modern media read cannot retry as anonymous after RLS denies access", async () => {
  for (const status of [200, 403]) {
    const f = fixture();
    const bearer = accept(f);
    f.routes.set(
      "/rest/v1/media",
      (call) =>
        call.authorization === `Bearer ${publicKey}`
          ? reply([{ object_key: "verified/public-fallback.jpg" }])
          : reply(status === 200 ? [] : { message: privateMarker }, status),
    );
    await result(
      await f.handlers().mediaRead(f.request({ media_id: id }, bearer)),
      404,
      "media_not_found",
    );
    assert(f.calls.length === 2 && f.calls[0].path === "/auth/v1/user");
    assert(f.calls[1].path === "/rest/v1/media");
    assert(f.calls.every((c) => c.authorization === bearer && c.apikey === publicKey));
    assert(f.effects.length === 0);
  }
});

Deno.test("accepted modern authentication does not enable the media pipeline", async () => {
  const f = fixture();
  const bearer = accept(f);
  for (
    const input of [
      { action: "reserve", listing_id: id, bytes: 100, mime: "image/jpeg" },
      { action: "complete", intent_id: id },
    ]
  ) {
    await result(
      await f.handlers().media(f.request(input, bearer)),
      503,
      "media_pipeline_unavailable",
    );
  }
  assert(f.calls.length === 2 && f.calls.every((c) => c.path === "/auth/v1/user"));
  assert(f.effects.length === 0);
});
