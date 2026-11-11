import { exportJWK, generateKeyPair, type JWTPayload, SignJWT } from "npm:jose@6.2.17";
import { AppleError, type AppleErrorCode } from "./apple_errors.ts";
import { AppleGrantClient } from "./apple_grants.ts";
import { type AppleDeadline, AppleHttp } from "./apple_http.ts";

// Generated in memory for each test process. Never persisted, and never a
// static private signing key or an Apple credential.
const pair = await generateKeyPair("RS256", { modulusLength: 2048, extractable: false });
export const publicJwk = {
  ...await exportJWK(pair.publicKey),
  kid: "synthetic-key",
  alg: "RS256",
  use: "sig",
};
export const owner = "4a25a310-8219-4cce-9f01-9aac41000001";
export const otherOwner = "4a25a310-8219-4cce-9f01-9aac41000002";
export const subject = "synthetic-apple-subject";
export const clientId = "invalid.synthetic.apple.client";
export const marker = "SYNTHETIC_PRIVATE_MARKER_ONLY";
export const refreshToken = "synthetic-refresh-token-not-valid-at-apple";
export const secret = "synthetic-client-secret-not-valid-at-apple";
export const now = 1_800_000_000_000;
export const identity = { user_id: owner, provider: "apple", id: subject };
export const binding = { ownerId: owner, appleSubject: subject, clientId };

export function assert(value: unknown): asserts value {
  if (!value) throw new Error("Assertion failed");
}
export async function failure(
  operation: Promise<unknown>,
  code: AppleErrorCode,
  uncertain = false,
) {
  try {
    await operation;
  } catch (error) {
    assert(error instanceof AppleError);
    assert(error.code === code && error.message === code);
    assert(error.outcomeUnknown === uncertain);
    assert(error.cause === undefined && !String(error.stack).includes(marker));
    assert(!JSON.stringify(error).includes(marker));
    return error;
  }
  throw new Error("Expected safe Apple failure");
}
export function token(payload: JWTPayload = {}, header: Record<string, unknown> = {}) {
  return new SignJWT({
    iss: "https://appleid.apple.com",
    aud: clientId,
    sub: subject,
    iat: now / 1000 - 1,
    exp: now / 1000 + 300,
    ...payload,
  }).setProtectedHeader({ alg: "RS256", kid: "synthetic-key", ...header }).sign(pair.privateKey);
}
export function tokenResponse(idToken: string, changes: Record<string, unknown> = {}) {
  return Response.json({
    id_token: idToken,
    access_token: "synthetic-access-token",
    token_type: "Bearer",
    expires_in: 3600,
    ...changes,
  });
}
export function fixture(
  idToken: string,
  options: {
    tokenReply?: () => Response;
    keyReply?: () => Response;
    clock?: () => number;
    deadline?: () => AppleDeadline;
  } = {},
) {
  const calls: Array<{ url: string; init?: RequestInit }> = [];
  const http = new AppleHttp({
    deadline: options.deadline ?? (() => ({ signal: new AbortController().signal, dispose() {} })),
    fetch: (url, init) => {
      calls.push({ url: String(url), init });
      if (String(url) === "https://appleid.apple.com/auth/token") {
        return Promise.resolve(options.tokenReply?.() ?? tokenResponse(idToken));
      }
      if (String(url) === "https://appleid.apple.com/auth/keys") {
        return Promise.resolve(options.keyReply?.() ?? Response.json({ keys: [publicJwk] }));
      }
      throw new Error(marker);
    },
  });
  return {
    calls,
    client: new AppleGrantClient(clientId, { http, now: options.clock ?? (() => now) }),
  };
}
