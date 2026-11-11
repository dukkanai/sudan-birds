import {
  createLocalJWKSet,
  decodeProtectedHeader,
  type JSONWebKeySet,
  jwtVerify,
} from "npm:jose@6.2.17";
import { AppleError, boundedText, record } from "./apple_errors.ts";
import {
  type AppleBinding,
  type AppleCryptoDependencies,
  appleTokenFingerprint,
  snapshotBinding,
  validAppleToken,
} from "./apple_crypto.ts";
import { AppleHttp } from "./apple_http.ts";

// Must be obtained from Auth.getUser for the verified bearer, or a trusted
// service-only lookup. This module cannot authenticate a caller or attest that
// a caller-supplied identity is authoritative. Never expose it as a token-upload API.
export interface TrustedAppleIdentity {
  readonly user_id: string;
  readonly provider: string;
  readonly id: string; // Provider subject, NOT Supabase's identity_id UUID.
}
export interface VerifiedAppleGrant extends AppleBinding {
  readonly tokenFingerprint: string;
  readonly validatedAt: number;
}
export interface AppleGrantDependencies {
  http?: AppleHttp;
  now?: () => number;
  crypto?: AppleCryptoDependencies;
}

function jwks(value: Record<string, unknown>): JSONWebKeySet {
  const keys = value.keys;
  if (!Array.isArray(keys) || keys.length === 0 || keys.length > 10) {
    throw new AppleError("apple_response_invalid");
  }
  const kids = new Set<string>();
  for (const key of keys) {
    if (
      !record(key) || key.kty !== "RSA" || key.alg !== "RS256" || key.use !== "sig" ||
      !boundedText(key.kid, 256) || kids.has(key.kid) ||
      !boundedText(key.n, 1400) || !boundedText(key.e, 16) ||
      !/^[A-Za-z0-9_-]+$/.test(key.n) || !/^[A-Za-z0-9_-]+$/.test(key.e) ||
      ["d", "p", "q", "dp", "dq", "qi", "oth", "k"].some((name) => name in key) ||
      (key.key_ops !== undefined &&
        (!Array.isArray(key.key_ops) || key.key_ops.length !== 1 || key.key_ops[0] !== "verify"))
    ) throw new AppleError("apple_response_invalid");
    kids.add(key.kid);
  }
  return { keys } as JSONWebKeySet;
}

export class AppleGrantClient {
  readonly #clientId: string;
  readonly #http: AppleHttp;
  readonly #now: () => number;
  readonly #crypto: AppleCryptoDependencies | undefined;

  constructor(clientId: string, deps: AppleGrantDependencies = {}) {
    if (!boundedText(clientId, 255)) throw new AppleError("apple_configuration_required");
    this.#clientId = clientId;
    this.#http = deps.http ?? new AppleHttp();
    this.#now = deps.now ?? Date.now;
    this.#crypto = deps.crypto;
  }

  // Refresh validation proves ownership of this grant only. Its ID-token iat
  // does NOT prove fresh interactive login, consent, deletion approval or AMR.
  async validateRefreshToken(
    refreshToken: string,
    clientSecret: string,
    expectedOwnerId: string,
    trustedIdentity: TrustedAppleIdentity,
  ): Promise<Readonly<VerifiedAppleGrant>> {
    try {
      validAppleToken(refreshToken);
      validAppleToken(clientSecret);
      if (
        !record(trustedIdentity) || trustedIdentity.provider !== "apple" ||
        trustedIdentity.user_id !== expectedOwnerId
      ) throw new AppleError("apple_binding_invalid");
      // Snapshot before any await: caller mutation must not change the target.
      const binding = snapshotBinding({
        ownerId: expectedOwnerId,
        appleSubject: trustedIdentity.id,
        clientId: this.#clientId,
      });
      const response = await this.#http.json(
        "validate",
        new URLSearchParams({
          client_id: this.#clientId,
          client_secret: clientSecret,
          grant_type: "refresh_token",
          refresh_token: refreshToken,
        }),
      );
      if (
        !boundedText(response.id_token, 8192) || !boundedText(response.access_token, 8192) ||
        response.token_type !== "Bearer" || typeof response.expires_in !== "number" ||
        !Number.isSafeInteger(response.expires_in) || response.expires_in <= 0 ||
        // Apple documents no rotation here. Do not silently discard a changed
        // credential if a future contract introduces one.
        (response.refresh_token !== undefined && response.refresh_token !== refreshToken)
      ) throw new AppleError("apple_response_invalid");
      const idToken = response.id_token;
      let header;
      try {
        header = decodeProtectedHeader(idToken);
      } catch {
        throw new AppleError("apple_token_invalid");
      }
      if (
        header.alg !== "RS256" || !boundedText(header.kid, 256) ||
        (header.typ !== undefined && header.typ !== "JWT") ||
        Object.keys(header).some((name) => !["alg", "kid", "typ"].includes(name))
      ) throw new AppleError("apple_token_invalid");
      // No createRemoteJWKSet: every fetch goes through the same fixed-origin,
      // bounded transport. jku/x5u or any other token-controlled URL is rejected.
      const keys = jwks(await this.#http.json("keys"));
      const now = this.#now();
      if (!Number.isSafeInteger(now) || !Number.isFinite(new Date(now).valueOf())) {
        throw new AppleError("apple_configuration_required");
      }
      try {
        const { payload } = await jwtVerify(idToken, createLocalJWKSet(keys), {
          algorithms: ["RS256"],
          issuer: "https://appleid.apple.com",
          audience: binding.clientId,
          subject: binding.appleSubject,
          requiredClaims: ["iss", "aud", "sub", "iat", "exp"],
          currentDate: new Date(now),
          clockTolerance: 0,
        });
        if (
          payload.aud !== binding.clientId || payload.iss !== "https://appleid.apple.com" ||
          payload.sub !== binding.appleSubject || !Number.isSafeInteger(payload.iat) ||
          !Number.isSafeInteger(payload.exp) || payload.iat! > Math.floor(now / 1000) ||
          payload.iat! < 0 || payload.exp! <= payload.iat!
        ) throw new Error();
      } catch {
        throw new AppleError("apple_token_invalid");
      }
      return Object.freeze({
        ...binding,
        tokenFingerprint: await appleTokenFingerprint(refreshToken, this.#crypto),
        validatedAt: now,
      });
    } catch (error) {
      if (error instanceof AppleError) throw error;
      throw new AppleError("apple_token_invalid");
    }
  }

  // The durable outbox must supply a previously verified immutable binding and
  // the SAME retained token on retries. An empty 200 is a receipt, not a durable
  // commit: erase ciphertext only together with recording that receipt in DB.
  async revoke(
    refreshToken: string,
    clientSecret: string,
    retained: AppleBinding & { readonly tokenFingerprint: string },
  ): Promise<Readonly<{ status: "revoked_or_already_invalid" }>> {
    try {
      validAppleToken(refreshToken);
      validAppleToken(clientSecret);
      const binding = snapshotBinding(retained);
      const fingerprint = retained.tokenFingerprint;
      if (
        binding.clientId !== this.#clientId ||
        typeof fingerprint !== "string" || !/^[a-f\d]{64}$/.test(fingerprint) ||
        await appleTokenFingerprint(refreshToken, this.#crypto) !== fingerprint
      ) throw new AppleError("apple_binding_invalid");
      await this.#http.request(
        "revoke",
        new URLSearchParams({
          client_id: binding.clientId,
          client_secret: clientSecret,
          token: refreshToken,
          token_type_hint: "refresh_token",
        }),
      );
      return Object.freeze({ status: "revoked_or_already_invalid" });
    } catch (error) {
      if (error instanceof AppleError) throw error;
      throw new AppleError("apple_input_invalid");
    }
  }
}
