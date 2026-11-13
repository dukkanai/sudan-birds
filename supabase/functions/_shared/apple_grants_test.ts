import { generateKeyPair, type JWTPayload, SignJWT } from "npm:jose@6.2.17";
import { appleTokenFingerprint } from "./apple_crypto.ts";
import { AppleGrantClient } from "./apple_grants.ts";
import { AppleHttp } from "./apple_http.ts";
import {
  assert,
  binding,
  clientId,
  failure,
  fixture,
  identity,
  marker,
  now,
  otherOwner,
  owner,
  publicJwk,
  refreshToken,
  secret,
  subject,
  token,
  tokenResponse,
} from "./apple_test_fixtures.ts";

Deno.test("Apple grant verifies signature and exact server identity without releasing provider tokens", async () => {
  const f = fixture(await token());
  const result = await f.client.validateRefreshToken(refreshToken, secret, owner, identity);
  assert(Object.isFrozen(result));
  assert(
    result.ownerId === owner && result.appleSubject === subject && result.clientId === clientId,
  );
  assert(
    result.validatedAt === now &&
      result.tokenFingerprint === await appleTokenFingerprint(refreshToken),
  );
  assert(
    !JSON.stringify(result).includes(refreshToken) && !JSON.stringify(result).includes(secret),
  );
  assert(
    Object.keys(result).sort().join(",") ===
      "appleSubject,clientId,ownerId,tokenFingerprint,validatedAt",
  );
  assert(f.calls.length === 2);
  const [post, keys] = f.calls;
  assert(
    post.url === "https://appleid.apple.com/auth/token" &&
      keys.url === "https://appleid.apple.com/auth/keys",
  );
  for (const call of f.calls) {
    assert(call.init?.redirect === "error" && call.init.credentials === "omit");
    assert(call.init.cache === "no-store" && call.init.referrerPolicy === "no-referrer");
    assert(!new Headers(call.init.headers).has("authorization"));
  }
  const form = new URLSearchParams(post.init?.body as string);
  assert(form.get("client_id") === clientId && form.get("refresh_token") === refreshToken);
  assert(form.get("client_secret") === secret && form.get("grant_type") === "refresh_token");
  assert(keys.init?.method === "GET" && keys.init.body === undefined);
});

for (
  const [name, changes] of [
    ["subject", { sub: "another-apple-subject" }],
    ["audience", { aud: "another-client" }],
    ["multi-audience", { aud: [clientId, "another-client"] }],
    ["issuer", { iss: "https://evil.invalid" }],
    ["alternate issuer", { iss: "https://account.apple.com" }],
    ["expired", { exp: now / 1000 }],
    ["future issued", { iat: now / 1000 + 1 }],
    ["missing issued", { iat: undefined }],
    ["missing expiry", { exp: undefined }],
    ["fractional issued", { iat: now / 1000 - 0.5 }],
    ["not yet valid", { nbf: now / 1000 + 10 }],
  ] satisfies Array<[string, JWTPayload]>
) {
  Deno.test(`Apple ID token rejects ${name}`, async () => {
    const f = fixture(await token(changes));
    await failure(
      f.client.validateRefreshToken(refreshToken, secret, owner, identity),
      "apple_token_invalid",
    );
  });
}

for (
  const [name, changed] of [
    ["owner", { ...identity, user_id: otherOwner }],
    ["provider", { ...identity, provider: "google" }],
    ["missing subject", { ...identity, id: "" }],
  ] as const
) {
  Deno.test(`Apple binding rejects ${name} before network`, async () => {
    const f = fixture(await token());
    await failure(
      f.client.validateRefreshToken(refreshToken, secret, owner, changed),
      "apple_binding_invalid",
    );
    assert(f.calls.length === 0);
  });
}

Deno.test("Apple validation snapshots identity before awaits and returns immutable binding", async () => {
  const mutable = { ...identity };
  const f = fixture(await token());
  const pending = f.client.validateRefreshToken(refreshToken, secret, owner, mutable);
  mutable.id = "late-other-subject";
  mutable.user_id = otherOwner;
  const result = await pending;
  assert(result.appleSubject === subject && result.ownerId === owner);
});

Deno.test("Apple repeated grant validation is not a replay/authentication attestation", async () => {
  const f = fixture(await token());
  const first = await f.client.validateRefreshToken(refreshToken, secret, owner, identity);
  const repeated = await f.client.validateRefreshToken(refreshToken, secret, owner, identity);
  assert(first.tokenFingerprint === repeated.tokenFingerprint);
  assert(!("authenticatedAt" in repeated) && !("amr" in repeated));
  assert(f.calls.length === 4); // No implicit retries or fabricated freshness.
});

Deno.test("Apple rejects a correctly shaped token signed by another private key", async () => {
  const pair = await generateKeyPair("RS256");
  const forged = await new SignJWT({
    iss: "https://appleid.apple.com",
    sub: subject,
    aud: clientId,
    iat: now / 1000 - 1,
    exp: now / 1000 + 300,
  })
    .setProtectedHeader({ alg: "RS256", kid: "synthetic-key" }).sign(pair.privateKey);
  const f = fixture(forged);
  await failure(
    f.client.validateRefreshToken(refreshToken, secret, owner, identity),
    "apple_token_invalid",
  );
});

for (
  const [name, header] of [
    ["unknown kid", { kid: "unknown" }],
    ["jku", { jku: "https://evil.invalid/keys" }],
    ["embedded jwk", { jwk: publicJwk }],
    ["x5u", { x5u: "https://evil.invalid/cert" }],
    ["unexpected type", { typ: "at+jwt" }],
  ] as const
) {
  Deno.test(`Apple rejects ${name} without a token-controlled fetch`, async () => {
    const f = fixture(await token({}, header));
    await failure(
      f.client.validateRefreshToken(refreshToken, secret, owner, identity),
      "apple_token_invalid",
    );
    assert(f.calls.every((c) => c.url.startsWith("https://appleid.apple.com/auth/")));
  });
}

Deno.test("Apple rejects unsigned and HMAC tokens rather than confusing key types", async () => {
  const unsigned = btoa(JSON.stringify({ alg: "none", kid: "synthetic-key" })) + ".e30.";
  const hmac = await new SignJWT({ sub: subject }).setProtectedHeader({
    alg: "HS256",
    kid: "synthetic-key",
  })
    .sign(crypto.getRandomValues(new Uint8Array(32)));
  for (const input of [unsigned, hmac, "malformed"]) {
    const f = fixture(input);
    await failure(
      f.client.validateRefreshToken(refreshToken, secret, owner, identity),
      "apple_token_invalid",
    );
    assert(f.calls.length === 1);
  }
});

for (
  const keys of [
    [],
    Array(11).fill(publicJwk),
    [publicJwk, publicJwk],
    [{ ...publicJwk, alg: "HS256" }],
    [{ ...publicJwk, use: "enc" }],
    [{ ...publicJwk, d: marker }],
    [{ ...publicJwk, key_ops: ["sign"] }],
    [{ ...publicJwk, n: "!invalid" }],
  ]
) {
  Deno.test(`Apple rejects invalid JWKS shape ${JSON.stringify(keys).length}`, async () => {
    const f = fixture(await token(), { keyReply: () => Response.json({ keys }) });
    await failure(
      f.client.validateRefreshToken(refreshToken, secret, owner, identity),
      "apple_response_invalid",
    );
  });
}

for (
  const [name, changes] of [
    ["missing ID token", { id_token: undefined }],
    ["missing access token", { access_token: undefined }],
    ["wrong token type", { token_type: "MAC" }],
    ["invalid expiry", { expires_in: -1 }],
    ["changed refresh token", { refresh_token: "unexpected-rotation" }],
  ]
) {
  Deno.test(`Apple validation rejects ${name}`, async () => {
    const signed = await token();
    const f = fixture(signed, {
      tokenReply: () => tokenResponse(signed, changes as Record<string, unknown>),
    });
    await failure(
      f.client.validateRefreshToken(refreshToken, secret, owner, identity),
      "apple_response_invalid",
    );
  });
}

Deno.test("Apple malformed JSON and UTF-8 do not disclose upstream content", async () => {
  for (const value of [marker, "[]", "null", new Uint8Array([0xff])]) {
    const f = fixture(await token(), {
      tokenReply: () => new Response(value, { headers: { "content-type": "application/json" } }),
    });
    await failure(
      f.client.validateRefreshToken(refreshToken, secret, owner, identity),
      "apple_response_invalid",
    );
  }
});

Deno.test("Apple revocation binds exact token/client and accepts repeat empty-200 receipts", async () => {
  const calls: RequestInit[] = [];
  const client = new AppleGrantClient(clientId, {
    http: new AppleHttp({
      deadline: () => ({ signal: new AbortController().signal, dispose() {} }),
      fetch: (url, init) => {
        assert(String(url) === "https://appleid.apple.com/auth/revoke");
        calls.push(init!);
        return Promise.resolve(new Response(null, { status: 200 }));
      },
    }),
  });
  const retained = { ...binding, tokenFingerprint: await appleTokenFingerprint(refreshToken) };
  for (let i = 0; i < 2; i++) {
    assert(
      (await client.revoke(refreshToken, secret, retained)).status === "revoked_or_already_invalid",
    );
  }
  assert(calls.length === 2 && calls[0].body === calls[1].body);
  assert(calls[0].method === "POST" && calls[0].redirect === "error");
  assert(new Headers(calls[0].headers).get("content-type") === "application/x-www-form-urlencoded");
  assert(new Headers(calls[0].headers).get("accept") === "application/json");
  assert(calls[0].credentials === "omit" && calls[0].cache === "no-store");
  assert(new URLSearchParams(calls[0].body as string).get("token_type_hint") === "refresh_token");
  await failure(client.revoke("different-token", secret, retained), "apple_binding_invalid");
  await failure(
    client.revoke(refreshToken, secret, { ...retained, clientId: "different-client" }),
    "apple_binding_invalid",
  );
  assert(calls.length === 2);
});
