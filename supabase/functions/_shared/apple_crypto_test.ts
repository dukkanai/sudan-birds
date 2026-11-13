import {
  type AppleCipherContext,
  type AppleCryptoDependencies,
  appleTokenFingerprint,
  decryptAppleGrant,
  encryptAppleGrant,
} from "./apple_crypto.ts";
import {
  assert,
  binding,
  failure,
  marker,
  otherOwner,
  refreshToken,
} from "./apple_test_fixtures.ts";

const key = await crypto.subtle.generateKey({ name: "AES-GCM", length: 256 }, false, [
  "encrypt",
  "decrypt",
]);
const context: AppleCipherContext = {
  ...binding,
  grantId: "4a25a310-8219-4cce-9f01-9aac41000003",
  keyVersion: "synthetic-v1",
  tokenFingerprint: await appleTokenFingerprint(refreshToken),
};

Deno.test("Apple AES-256-GCM round-trips with fresh IV and contains no plaintext", async () => {
  const first = await encryptAppleGrant(refreshToken, context, key);
  const second = await encryptAppleGrant(refreshToken, context, key);
  assert(Object.isFrozen(first));
  assert(first.iv !== second.iv && first.ciphertext !== second.ciphertext);
  assert(!JSON.stringify(first).includes(refreshToken));
  assert(await decryptAppleGrant(first, context, key) === refreshToken);
});

Deno.test("Apple maximum-size token and ciphertext envelope round-trip exactly", async () => {
  const maximum = "s".repeat(8192);
  const bound = { ...context, tokenFingerprint: await appleTokenFingerprint(maximum) };
  const envelope = await encryptAppleGrant(maximum, bound, key);
  assert(envelope.ciphertext.length === 10944 && envelope.iv.length === 16);
  assert(await decryptAppleGrant(envelope, bound, key) === maximum);
});

Deno.test("Apple refuses crypto keys missing the operation's required usage", async () => {
  const encryptOnly = await crypto.subtle.generateKey({ name: "AES-GCM", length: 256 }, false, [
    "encrypt",
  ]);
  const decryptOnly = await crypto.subtle.generateKey({ name: "AES-GCM", length: 256 }, false, [
    "decrypt",
  ]);
  await failure(encryptAppleGrant(refreshToken, context, decryptOnly), "apple_crypto_failed");
  const envelope = await encryptAppleGrant(refreshToken, context, key);
  await failure(decryptAppleGrant(envelope, context, encryptOnly), "apple_crypto_failed");
});

for (
  const [name, value] of [
    ["ownerId", otherOwner],
    ["appleSubject", "other-subject"],
    ["clientId", "other-client"],
    ["grantId", "4a25a310-8219-4cce-9f01-9aac41000004"],
    ["keyVersion", "synthetic-v2"],
    ["tokenFingerprint", "0".repeat(64)],
  ] as const
) {
  Deno.test(`Apple ciphertext cannot be moved to a different ${name}`, async () => {
    const envelope = await encryptAppleGrant(refreshToken, context, key);
    await failure(
      decryptAppleGrant(envelope, { ...context, [name]: value }, key),
      "apple_crypto_failed",
    );
  });
}

Deno.test("Apple rejects mismatched token fingerprint before encryption", async () => {
  await failure(encryptAppleGrant("another-token", context, key), "apple_binding_invalid");
});

Deno.test("Apple rejects modified ciphertext, IV, tag and noncanonical envelopes", async () => {
  const envelope = await encryptAppleGrant(refreshToken, context, key);
  const flip = (text: string) => (text[0] === "A" ? "B" : "A") + text.slice(1);
  for (
    const changed of [
      { ...envelope, ciphertext: flip(envelope.ciphertext) },
      { ...envelope, iv: flip(envelope.iv) },
      { ...envelope, ciphertext: envelope.ciphertext.slice(0, -4) },
      { ...envelope, ciphertext: envelope.ciphertext + "=" },
      { ...envelope, iv: "!" },
      { ...envelope, iv: "A" },
      { ...envelope, ciphertext: "A".repeat(10945) },
      { ...envelope, ownerId: otherOwner },
    ]
  ) await failure(decryptAppleGrant(changed, context, key), "apple_crypto_failed");
});

Deno.test("Apple ciphertext cannot be decrypted by a different key", async () => {
  const other = await crypto.subtle.generateKey({ name: "AES-GCM", length: 256 }, false, [
    "encrypt",
    "decrypt",
  ]);
  const envelope = await encryptAppleGrant(refreshToken, context, key);
  await failure(decryptAppleGrant(envelope, context, other), "apple_crypto_failed");
});

Deno.test("Apple refuses extractable, short and wrong-algorithm encryption keys", async () => {
  const extractable = await crypto.subtle.generateKey({ name: "AES-GCM", length: 256 }, true, [
    "encrypt",
    "decrypt",
  ]);
  const short = await crypto.subtle.generateKey({ name: "AES-GCM", length: 128 }, false, [
    "encrypt",
    "decrypt",
  ]);
  const cbc = await crypto.subtle.generateKey({ name: "AES-CBC", length: 256 }, false, [
    "encrypt",
    "decrypt",
  ]);
  for (const wrong of [extractable, short, cbc]) {
    await failure(encryptAppleGrant(refreshToken, context, wrong), "apple_crypto_failed");
  }
});

Deno.test("Apple encryption snapshots immutable context before asynchronous crypto", async () => {
  const mutable = { ...context };
  const result = encryptAppleGrant(refreshToken, mutable, key);
  mutable.ownerId = otherOwner;
  mutable.clientId = "late-client";
  assert(await decryptAppleGrant(await result, context, key) === refreshToken);
});

Deno.test("Apple crypto errors are fixed labels and plaintext byte buffers are cleared", async () => {
  let captured: ArrayBufferView | undefined;
  const subtle = new Proxy(crypto.subtle, {
    get(target, property) {
      if (property === "encrypt") {
        return (_algorithm: unknown, _key: unknown, bytes: ArrayBufferView) => {
          captured = bytes;
          throw new Error(marker);
        };
      }
      const value = Reflect.get(target, property);
      return typeof value === "function" ? value.bind(target) : value;
    },
  });
  const deps: AppleCryptoDependencies = {
    subtle,
    random: (bytes) => crypto.getRandomValues(bytes),
  };
  await failure(encryptAppleGrant(refreshToken, context, key, deps), "apple_crypto_failed");
  assert(captured && new Uint8Array(captured.buffer).every((byte) => byte === 0));
  await failure(
    encryptAppleGrant(refreshToken, context, key, {
      ...deps,
      random() {
        throw new Error(marker);
      },
    }),
    "apple_crypto_failed",
  );
});

Deno.test("Apple rejects unbounded and control-character tokens without crypto/network", async () => {
  for (const value of ["", "x".repeat(8193), "token\nsecret", "token with spaces"]) {
    await failure(appleTokenFingerprint(value), "apple_input_invalid");
  }
});

Deno.test("Apple context getter failures never expose raw errors outside crypto guards", async () => {
  for (const property of ["ownerId", "grantId", "tokenFingerprint"]) {
    const broken = { ...context };
    Object.defineProperty(broken, property, {
      get() {
        throw new Error(marker);
      },
    });
    await failure(encryptAppleGrant(refreshToken, broken, key), "apple_binding_invalid");
    const envelope = await encryptAppleGrant(refreshToken, context, key);
    await failure(decryptAppleGrant(envelope, broken, key), "apple_binding_invalid");
  }
});

Deno.test("Apple buffer cleanup cannot replace a primary injected crypto failure", async () => {
  const subtle = new Proxy(crypto.subtle, {
    get(target, property) {
      if (property === "digest") {
        return (_algorithm: unknown, bytes: Uint8Array<ArrayBuffer>) => {
          structuredClone(bytes.buffer, { transfer: [bytes.buffer] });
          throw new Error(marker);
        };
      }
      const value = Reflect.get(target, property);
      return typeof value === "function" ? value.bind(target) : value;
    },
  });
  await failure(
    appleTokenFingerprint(refreshToken, {
      subtle,
      random: (bytes) => crypto.getRandomValues(bytes),
    }),
    "apple_crypto_failed",
  );
});
