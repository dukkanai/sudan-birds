/** Local-only SDK adapter; never deploy. See the source-pinned launcher. */
import {
  GetObjectCommand,
  HeadObjectCommand,
  PutObjectCommand,
  S3Client,
  type S3ClientConfig,
} from "npm:@aws-sdk/client-s3@3.1164.0";
import { getSignedUrl } from "npm:@aws-sdk/s3-request-presigner@3.1164.0";
import { presignCreateOnly } from "../supabase/functions/_shared/presign.ts";
import {
  cancelImageStream,
  readExactImageStream,
} from "../supabase/functions/_shared/image_stream.ts";
import { ApiError } from "../supabase/functions/_shared/http.ts";
import { reportFailure } from "../supabase/functions/_shared/diagnostics.ts";

const bucket = "synthetic-bucket";
const host = `${bucket}.synthetic.invalid`;
// Literal non-credentials, used only for offline cryptographic fixtures.
const credentials = {
  accessKeyId: "SYNTHETIC_TEST_ONLY",
  secretAccessKey: "SYNTHETIC_NOT_A_REAL_CREDENTIAL",
};
const encoder = new TextEncoder();
const hex = (bytes: ArrayBuffer) =>
  Array.from(new Uint8Array(bytes), (b) => b.toString(16).padStart(2, "0")).join("");
const digest = async (value: string | Uint8Array) =>
  hex(
    await crypto.subtle.digest(
      "SHA-256",
      typeof value === "string" ? encoder.encode(value) : value as Uint8Array<ArrayBuffer>,
    ),
  );
const hmac = async (key: Uint8Array, value: string) => {
  const k = await crypto.subtle.importKey(
    "raw",
    key as Uint8Array<ArrayBuffer>,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  return new Uint8Array(await crypto.subtle.sign("HMAC", k, encoder.encode(value)));
};
const encode = (value: string) =>
  encodeURIComponent(value).replace(
    /[!'()*]/g,
    (c) => `%${c.charCodeAt(0).toString(16).toUpperCase()}`,
  );
export class FixtureAssertion extends Error {}
export function check(value: unknown, message: string): asserts value {
  if (!value) throw new FixtureAssertion(message);
}
interface SignedRequest {
  method: string;
  protocol: string;
  hostname: string;
  path: string;
  query?: Record<string, string | string[] | null>;
  headers: Record<string, string>;
  body?: unknown;
}
/** Independent WebCrypto recomputation, not the SDK verifier or a live service. */
export async function verifySignature(request: SignedRequest, presigned = false) {
  check(request.hostname === host && request.protocol === "https:", "closed transport origin");
  const headers = Object.fromEntries(
    Object.entries(request.headers).map(([k, v]) => [k.toLowerCase(), v]),
  );
  const query = request.query ?? {};
  const q = (name: string) => {
    const v = query[name];
    check(typeof v === "string", "signature query field");
    return v;
  };
  const auth = headers.authorization ?? "";
  const match =
    /^AWS4-HMAC-SHA256 Credential=([^,]+), SignedHeaders=([^,]+), Signature=([a-f0-9]{64})$/.exec(
      auth,
    );
  const credential = presigned ? q("X-Amz-Credential") : match?.[1];
  const signedHeaders = presigned ? q("X-Amz-SignedHeaders") : match?.[2];
  const signature = presigned ? q("X-Amz-Signature") : match?.[3];
  const date = presigned ? q("X-Amz-Date") : headers["x-amz-date"];
  check(
    credential && signedHeaders && signature && /^\d{8}T\d{6}Z$/.test(date ?? ""),
    "SigV4 envelope",
  );
  const scope = `${date.slice(0, 8)}/auto/s3/aws4_request`;
  check(credential === `${credentials.accessKeyId}/${scope}`, "SigV4 credential scope");
  if (presigned) check(q("X-Amz-Algorithm") === "AWS4-HMAC-SHA256", "presign algorithm");
  const names = signedHeaders.split(";");
  check(
    names.includes("host") && names.join(";") === [...names].sort().join(";"),
    "signed header order",
  );
  headers.host = request.hostname;
  const canonicalHeaders = names.map((name) => {
    check(typeof headers[name] === "string", "missing signed header");
    return `${name}:${headers[name].trim().replace(/\s+/g, " ")}\n`;
  }).join("");
  const pairs = Object.entries(query).flatMap(([k, v]) => {
    if (presigned && k === "X-Amz-Signature") return [];
    return (Array.isArray(v) ? v : [v ?? ""]).map((value) => [encode(k), encode(value)]);
  });
  pairs.sort((a, b) => a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : a[1] < b[1] ? -1 : a[1] > b[1] ? 1 : 0);
  const canonicalQuery = pairs.map(([k, v]) => `${k}=${v}`).join("&");
  const payload = presigned
    ? (query["X-Amz-Content-Sha256"] ?? "UNSIGNED-PAYLOAD")
    : headers["x-amz-content-sha256"];
  check(typeof payload === "string", "payload hash missing");
  const canonical = [
    request.method,
    request.path,
    canonicalQuery,
    canonicalHeaders,
    signedHeaders,
    payload,
  ].join("\n");
  const text = `AWS4-HMAC-SHA256\n${date}\n${scope}\n${await digest(canonical)}`;
  let key = await hmac(encoder.encode(`AWS4${credentials.secretAccessKey}`), date.slice(0, 8));
  key = await hmac(key, "auto");
  key = await hmac(key, "s3");
  key = await hmac(key, "aws4_request");
  check(hex((await hmac(key, text)).buffer) === signature, "SigV4 mismatch");
  return names;
}
export type StorageMode =
  | "normal"
  | "wrong_length"
  | "wrong_type"
  | "short_stream"
  | "long_stream"
  | "missing_body"
  | "get_denied"
  | "get_retry_once"
  | "put_conflict"
  | "put_failed"
  | "bad_fence"
  | "stall_stream";

export function createSdkStorage(
  fixture: Uint8Array,
  sample: (phase: string) => void,
  options: {
    counterfactualNoDestroy?: boolean;
    delayMs?: number;
    now?: () => number;
    afterSign?: () => Promise<void> | void;
    onEvent?: (event: { client: number; name: string }) => void;
    onDestroy?: () => void;
    putCancellation?: () => Promise<void>;
  } = {},
) {
  let mode: StorageMode = "normal";
  let attempts = 0;
  let hold: Promise<void> | undefined;
  let entered: (() => void) | undefined;
  let headHold: Promise<void> | undefined;
  let headEntered: (() => void) | undefined;
  let cancellation: (() => Promise<void>) | undefined;
  const now = options.now ?? Date.now;
  const effects = {
    clients: 0,
    destroys: 0,
    get: 0,
    put: 0,
    head: 0,
    presign_put: 0,
    presign_get: 0,
    signed_put: 0,
    put_response_canceled: 0,
    verified_signatures: 0,
    streams: 0,
    closed: 0,
    canceled: 0,
    cancellation_settled: 0,
    destroyed_with_pending_cancellation: 0,
    stream_chunks: 0,
    sdk_attempts: 0,
  };
  const objects = new Map<string, { bytes: number; tombstone: boolean }>();
  const delay = () =>
    options.delayMs
      ? new Promise<void>((resolve) => setTimeout(resolve, options.delayMs))
      : Promise.resolve();
  const chunked = (
    data: Uint8Array,
    state: { id: number; destroyed: boolean; pending: number },
  ) => {
    effects.streams++;
    const event = (name: string) => options.onEvent?.({ client: state.id, name });
    const cancel = async () => {
      check(!state.destroyed, "client destroyed before stream cancellation");
      effects.canceled++;
      state.pending++;
      event("cancel-start");
      try {
        await cancellation?.();
      } finally {
        state.pending--;
        effects.cancellation_settled++;
        event("cancel-settled");
      }
    };
    if (mode === "stall_stream") {
      return new ReadableStream<Uint8Array>({ pull() {}, cancel }, { highWaterMark: 0 });
    }
    let offset = 0;
    return new ReadableStream<Uint8Array>({
      pull(controller) {
        check(!state.destroyed, "client destroyed during stream consumption");
        if (offset >= data.length) {
          effects.closed++;
          event("stream-close");
          controller.close();
          return;
        }
        const end = Math.min(data.length, offset + 65536);
        effects.stream_chunks++;
        check(effects.stream_chunks <= 1024, "stream chunk bound");
        controller.enqueue(data.slice(offset, end));
        offset = end;
      },
      cancel,
    }, { highWaterMark: 0 });
  };
  const config = (requestHandler?: S3ClientConfig["requestHandler"]): S3ClientConfig => ({
    // Same reviewed options as production storage(), except the synthetic
    // endpoint/credentials and explicitly injected closed requestHandler.
    region: "auto",
    endpoint: "https://synthetic.invalid",
    credentials,
    requestChecksumCalculation: "WHEN_REQUIRED",
    responseChecksumValidation: "WHEN_REQUIRED",
    maxAttempts: 2,
    retryMode: "standard",
    defaultsMode: "standard",
    useFipsEndpoint: false,
    useDualstackEndpoint: false,
    defaultUserAgentProvider: () => Promise.resolve([["sudan-birds", "0.1"]]),
    ...(requestHandler ? { requestHandler } : {}),
  });
  const client = () => {
    check(++effects.clients <= 128, "client bound");
    const state = { id: effects.clients, destroyed: false, pending: 0 };
    const event = (name: string) => options.onEvent?.({ client: state.id, name });
    const c = new S3Client(config({
      async handle(req: SignedRequest, requestOptions?: { abortSignal?: { aborted: boolean } }) {
        check(!state.destroyed, "transport after client destruction");
        check(++effects.sdk_attempts <= 128, "SDK attempt bound");
        check(!requestOptions?.abortSignal?.aborted, "aborted before transport");
        await delay();
        await verifySignature(req as SignedRequest);
        effects.verified_signatures++;
        sample("signed_sdk_command");
        event(`${req.method}:transport`);
        const key = decodeURIComponent(req.path.slice(1));
        check(/^synthetic\/[a-z0-9-]+\.jpg$/.test(key), "closed transport key");
        if (req.method === "GET") {
          effects.get++;
          attempts++;
          entered?.();
          if (hold) await hold;
          if (mode === "get_denied" || (mode === "get_retry_once" && attempts === 1)) {
            const statusCode = mode === "get_denied" ? 403 : 503;
            const code = statusCode === 403 ? "AccessDenied" : "SlowDown";
            return {
              response: {
                statusCode,
                headers: { "content-type": "application/xml" },
                body: encoder.encode(
                  `<Error><Code>${code}</Code><Message>synthetic</Message></Error>`,
                ),
              },
            };
          }
          const data = mode === "short_stream"
            ? fixture.subarray(0, fixture.length - 1)
            : mode === "long_stream"
            ? (() => {
              const expanded = new Uint8Array(fixture.length + 1);
              expanded.set(fixture);
              return expanded;
            })()
            : fixture;
          return {
            response: {
              statusCode: 200,
              headers: {
                "content-length": String(
                  mode === "wrong_length" ? fixture.length - 1 : fixture.length,
                ),
                "content-type": mode === "wrong_type" ? "text/plain" : "image/jpeg",
              },
              body: mode === "missing_body" ? undefined : chunked(data, state),
            },
          };
        }
        if (req.method === "PUT") {
          effects.put++;
          check(
            req.headers["content-length"] === "0" &&
              req.headers["content-type"] === "application/x-sudan-birds-tombstone" &&
              req.headers["x-amz-meta-birds-tombstone"] === "1",
            "tombstone serialization",
          );
          check(req.body instanceof Uint8Array && req.body.byteLength === 0, "tombstone body");
          objects.set(key, { bytes: 0, tombstone: true });
          return { response: { statusCode: 200, headers: {}, body: new Uint8Array() } };
        }
        if (req.method === "HEAD") {
          effects.head++;
          headEntered?.();
          if (headHold) await headHold;
          check(objects.get(key)?.tombstone, "head without prior tombstone");
          return {
            response: {
              statusCode: 200,
              headers: {
                "content-length": "0",
                "x-amz-meta-birds-tombstone": mode === "bad_fence" ? "0" : "1",
              },
              body: new Uint8Array(),
            },
          };
        }
        throw new FixtureAssertion("unexpected SDK method");
      },
      destroy() {
        check(!state.destroyed, "client destroyed more than once");
        if (state.pending) effects.destroyed_with_pending_cancellation++;
        state.destroyed = true;
        effects.destroys++;
        event("destroy");
        options.onDestroy?.();
      },
    }));
    sample("client_created");
    return c;
  };
  const usingClient = async <T>(operation: (c: S3Client) => Promise<T>): Promise<T> => {
    const c = client();
    try {
      return await operation(c);
    } finally {
      if (!options.counterfactualNoDestroy) {
        try {
          c.destroy();
        } catch {
          // Match production's outcome-preserving owned-client cleanup guard.
          reportFailure("storage_client_cleanup_failed");
        }
      }
    }
  };
  const signUpload = (key: string, bytes: number, mime: string, expiresIn = 120) =>
    usingClient(async (c) => {
      effects.presign_put++;
      const signed = await presignCreateOnly(c, bucket, key, bytes, mime, expiresIn);
      await options.afterSign?.();
      return signed;
    });
  const signRead = async (key: string) => {
    const signed = await usingClient(async (c) => {
      effects.presign_get++;
      return await getSignedUrl(c, new GetObjectCommand({ Bucket: bucket, Key: key }), {
        expiresIn: 60,
      });
    });
    // Independent synthetic-service verification is outside the signing
    // client's lifetime, as real service verification would be.
    await verifyPresigned(signed, "GET", {});
    return signed;
  };
  const verifyPresigned = async (
    signed: string,
    method: string,
    headers: Record<string, string>,
  ) => {
    const url = new URL(signed);
    const names = await verifySignature({
      method,
      protocol: url.protocol,
      hostname: url.hostname,
      path: url.pathname,
      query: Object.fromEntries(url.searchParams),
      headers,
    }, true);
    effects.verified_signatures++;
    check(Number(url.searchParams.get("X-Amz-Expires")) <= 120, "presign expiry bound");
    return names;
  };
  const signedPut = async (signed: string, bytes: Uint8Array, signal: AbortSignal) => {
    await delay();
    if (signal.aborted) throw new DOMException("synthetic closed transport abort", "AbortError");
    const names = await verifyPresigned(signed, "PUT", {
      "content-type": "image/jpeg",
      "content-length": String(bytes.length),
      "if-none-match": "*",
    });
    check(
      ["content-type", "content-length", "if-none-match"].every((n) => names.includes(n)),
      "conditional signed headers",
    );
    effects.signed_put++;
    const key = decodeURIComponent(new URL(signed).pathname.slice(1));
    const conflict = mode === "put_conflict" || objects.has(key);
    const body = options.putCancellation
      ? new ReadableStream<Uint8Array>({
        cancel() {
          effects.put_response_canceled++;
          return options.putCancellation!();
        },
      })
      : null;
    if (conflict || mode === "put_failed") {
      return new Response(body, { status: conflict ? 412 : 500 });
    }
    objects.set(key, { bytes: bytes.length, tombstone: false });
    return new Response(body, { status: 200 });
  };
  const deps = {
    storageConfiguration: () => ({ account: "a".repeat(32), bucket, ...credentials }),
    signRead,
    signUpload,
    downloadImage: (key: string, expectedBytes: number) =>
      usingClient(async (c) => {
        const signal = AbortSignal.timeout(15000);
        const result = await c.send(new GetObjectCommand({ Bucket: bucket, Key: key }), {
          abortSignal: signal,
        });
        if (!result.Body) throw new ApiError(400, "invalid_image");
        const stream = result.Body.transformToWebStream();
        if (result.ContentLength !== expectedBytes || result.ContentType !== "image/jpeg") {
          await cancelImageStream(stream);
          throw new ApiError(400, "invalid_image");
        }
        return await readExactImageStream(stream, expectedBytes, signal);
      }),
    writeVerified: async (key: string, bytes: Uint8Array, expiresAt: string) => {
      const deadline = Date.parse(expiresAt);
      const expiresIn = Math.min(30, Math.floor((deadline - now()) / 1000));
      if (!Number.isFinite(expiresIn) || expiresIn < 3) throw new ApiError(409, "upload_expired");
      const signed = await signUpload(key, bytes.length, "image/jpeg", expiresIn);
      const remainingMs = deadline - now();
      if (!Number.isFinite(remainingMs) || expiresIn * 1000 > remainingMs) {
        throw new ApiError(409, "upload_expired");
      }
      // Production uses fetch with timeout/redirect:error. This local variant
      // verifies and handles the signed request entirely in memory instead.
      const response = await signedPut(
        signed,
        bytes,
        AbortSignal.timeout(Math.min(15_000, Math.floor(remainingMs))),
      );
      if (!response.ok) {
        if (response.body) await cancelImageStream(response.body);
        throw new ApiError(
          response.status === 412 ? 409 : 502,
          response.status === 412 ? "upload_conflict" : "image_storage_failed",
        );
      }
      if (response.body) await cancelImageStream(response.body);
      sample("after_signed_write");
    },
    removePayloadAndFence: (key: string) =>
      usingClient(async (c) => {
        await c.send(
          new PutObjectCommand({
            Bucket: bucket,
            Key: key,
            Body: new Uint8Array(),
            ContentLength: 0,
            ContentType: "application/x-sudan-birds-tombstone",
            Metadata: { "birds-tombstone": "1" },
          }),
          { abortSignal: AbortSignal.timeout(10000) },
        );
        const head = await c.send(new HeadObjectCommand({ Bucket: bucket, Key: key }), {
          abortSignal: AbortSignal.timeout(10000),
        });
        if (head.ContentLength !== 0 || head.Metadata?.["birds-tombstone"] !== "1") {
          throw new ApiError(502, "storage_cleanup_failed");
        }
        return true;
      }),
  };
  return {
    deps,
    effects,
    verifyPresigned,
    setMode(next: StorageMode) {
      mode = next;
      attempts = 0;
    },
    holdDownload(waiting?: Promise<void>, onEntered?: () => void) {
      hold = waiting;
      entered = onEntered;
    },
    holdHead(waiting?: Promise<void>, onEntered?: () => void) {
      headHold = waiting;
      headEntered = onEntered;
    },
    setCancellation(operation?: () => Promise<void>) {
      cancellation = operation;
    },
    inspectDefaultClient() {
      const c = new S3Client(config());
      const result = {
        runtime: c.config.runtime,
        handler: c.config.requestHandler.constructor.name,
      };
      // No send occurs and no socket is opened. This is separate from all
      // measured mock-transport workloads; its counters are not included.
      c.destroy();
      return result;
    },
  };
}
