import { AppleError, boundedText, record } from "./apple_errors.ts";

export interface AppleBinding {
  readonly ownerId: string;
  readonly appleSubject: string;
  readonly clientId: string;
}
export interface AppleCipherContext extends AppleBinding {
  readonly grantId: string;
  readonly keyVersion: string;
  readonly tokenFingerprint: string;
}
export interface AppleCryptoDependencies {
  subtle: SubtleCrypto;
  random: (bytes: Uint8Array<ArrayBuffer>) => Uint8Array<ArrayBuffer>;
}
const defaults: AppleCryptoDependencies = {
  subtle: globalThis.crypto.subtle,
  random: (bytes) => globalThis.crypto.getRandomValues(bytes),
};
const uuid = /^[a-f\d]{8}-[a-f\d]{4}-[1-8][a-f\d]{3}-[89ab][a-f\d]{3}-[a-f\d]{12}$/;
const encoder = new TextEncoder();

export function snapshotBinding(value: AppleBinding): Readonly<AppleBinding> {
  try {
    if (!record(value)) throw new Error();
    const { ownerId, appleSubject, clientId } = value;
    if (
      typeof ownerId !== "string" || !uuid.test(ownerId) ||
      !boundedText(appleSubject, 255) || !boundedText(clientId, 255)
    ) throw new AppleError("apple_binding_invalid");
    return Object.freeze({ ownerId, appleSubject, clientId });
  } catch {
    throw new AppleError("apple_binding_invalid");
  }
}

export function validAppleToken(value: unknown): asserts value is string {
  if (!boundedText(value, 8192)) throw new AppleError("apple_input_invalid");
}

export async function appleTokenFingerprint(
  token: string,
  deps = defaults,
): Promise<string> {
  validAppleToken(token);
  const bytes = encoder.encode(token);
  try {
    const hash = new Uint8Array(await deps.subtle.digest("SHA-256", bytes));
    return Array.from(hash, (byte) => byte.toString(16).padStart(2, "0")).join("");
  } catch {
    throw new AppleError("apple_crypto_failed");
  } finally {
    try {
      bytes.fill(0);
    } catch { /* Preserve the primary crypto failure. */ }
  }
}

function snapshotContext(value: AppleCipherContext): Readonly<AppleCipherContext> {
  try {
    const binding = snapshotBinding(value);
    const { grantId, keyVersion, tokenFingerprint } = value;
    if (
      typeof grantId !== "string" || !uuid.test(grantId) || !boundedText(keyVersion, 64) ||
      typeof tokenFingerprint !== "string" || !/^[a-f\d]{64}$/.test(tokenFingerprint)
    ) throw new AppleError("apple_binding_invalid");
    return Object.freeze({
      ...binding,
      grantId,
      keyVersion,
      tokenFingerprint,
    });
  } catch {
    throw new AppleError("apple_binding_invalid");
  }
}

function aad(context: AppleCipherContext): Uint8Array<ArrayBuffer> {
  // A versioned, canonical JSON tuple avoids concatenation ambiguity. Context
  // always comes from trusted storage, never from the ciphertext envelope.
  return encoder.encode(JSON.stringify([
    "sudan-birds/apple-grant/aes-256-gcm/v1",
    context.ownerId,
    context.appleSubject,
    context.clientId,
    context.grantId,
    context.keyVersion,
    context.tokenFingerprint,
  ]));
}

function base64url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes)).replaceAll("+", "-").replaceAll("/", "_")
    .replaceAll("=", "");
}
function decode(value: unknown, limit: number): Uint8Array<ArrayBuffer> {
  if (typeof value !== "string" || value.length > limit || !/^[A-Za-z0-9_-]+$/.test(value)) {
    throw new AppleError("apple_crypto_failed");
  }
  const bytes = Uint8Array.from(
    atob(value.replaceAll("-", "+").replaceAll("_", "/")),
    (c) => c.charCodeAt(0),
  );
  if (base64url(bytes) !== value) throw new AppleError("apple_crypto_failed");
  return bytes;
}

export interface AppleCiphertext {
  readonly version: 1;
  readonly iv: string;
  readonly ciphertext: string;
}

// Accept only a non-extractable, 256-bit AES-GCM key provisioned by the caller.
// These primitives never generate, persist, load or rotate production keys.
function checkKey(key: CryptoKey, usage: KeyUsage) {
  if (
    key.type !== "secret" || key.extractable || key.algorithm.name !== "AES-GCM" ||
    (key.algorithm as AesKeyAlgorithm).length !== 256 || !key.usages.includes(usage)
  ) throw new AppleError("apple_crypto_failed");
}

export async function encryptAppleGrant(
  token: string,
  context: AppleCipherContext,
  key: CryptoKey,
  deps = defaults,
): Promise<Readonly<AppleCiphertext>> {
  const frozen = snapshotContext(context);
  validAppleToken(token);
  const plaintext = encoder.encode(token);
  try {
    checkKey(key, "encrypt");
    if (await appleTokenFingerprint(token, deps) !== frozen.tokenFingerprint) {
      throw new AppleError("apple_binding_invalid");
    }
    const iv = deps.random(new Uint8Array(12));
    if (!(iv instanceof Uint8Array) || iv.length !== 12) throw new Error();
    const encrypted = await deps.subtle.encrypt(
      {
        name: "AES-GCM",
        iv,
        additionalData: aad(frozen),
        tagLength: 128,
      },
      key,
      plaintext,
    );
    return Object.freeze({
      version: 1,
      iv: base64url(iv),
      ciphertext: base64url(new Uint8Array(encrypted)),
    });
  } catch (error) {
    if (error instanceof AppleError && error.code === "apple_binding_invalid") throw error;
    throw new AppleError("apple_crypto_failed");
  } finally {
    try {
      plaintext.fill(0);
    } catch { /* Preserve the primary crypto failure. */ }
  }
}

export async function decryptAppleGrant(
  envelope: AppleCiphertext,
  context: AppleCipherContext,
  key: CryptoKey,
  deps = defaults,
): Promise<string> {
  const frozen = snapshotContext(context);
  let plaintext: Uint8Array | undefined;
  try {
    checkKey(key, "decrypt");
    if (
      !record(envelope) || envelope.version !== 1 ||
      Object.keys(envelope).sort().join(",") !== "ciphertext,iv,version"
    ) throw new Error();
    const iv = decode(envelope.iv, 16);
    const ciphertext = decode(envelope.ciphertext, 10944);
    if (iv.length !== 12 || ciphertext.length < 17 || ciphertext.length > 8208) throw new Error();
    plaintext = new Uint8Array(
      await deps.subtle.decrypt(
        {
          name: "AES-GCM",
          iv,
          additionalData: aad(frozen),
          tagLength: 128,
        },
        key,
        ciphertext,
      ),
    );
    const token = new TextDecoder("utf-8", { fatal: true }).decode(plaintext);
    validAppleToken(token);
    if (await appleTokenFingerprint(token, deps) !== frozen.tokenFingerprint) throw new Error();
    return token;
  } catch {
    throw new AppleError("apple_crypto_failed");
  } finally {
    try {
      plaintext?.fill(0);
    } catch { /* Preserve the primary crypto failure. */ }
  }
}
