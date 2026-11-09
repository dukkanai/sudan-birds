import {
  GetObjectCommand,
  HeadObjectCommand,
  PutObjectCommand,
  S3Client,
} from "npm:@aws-sdk/client-s3@3.1164.0";
import { getSignedUrl } from "npm:@aws-sdk/s3-request-presigner@3.1164.0";
import { requiredEnv } from "./auth.ts";
import { ApiError } from "./http.ts";
import { presignCreateOnly } from "./presign.ts";
import { cancelImageStream, readExactImageStream } from "./image_stream.ts";
export function storageConfiguration(get?: (name: string) => string | undefined) {
  const account = requiredEnv("R2_ACCOUNT_ID", get);
  if (!/^[a-f\d]{32}$/i.test(account)) throw new ApiError(503, "service_not_configured");
  return {
    account,
    bucket: requiredEnv("R2_BUCKET", get),
    accessKeyId: requiredEnv("R2_ACCESS_KEY_ID", get),
    secretAccessKey: requiredEnv("R2_SECRET_ACCESS_KEY", get),
  };
}
function storage() {
  const config = storageConfiguration();
  return new S3Client({
    region: "auto",
    endpoint: `https://${config.account}.r2.cloudflarestorage.com`,
    credentials: {
      accessKeyId: config.accessKeyId,
      secretAccessKey: config.secretAccessKey,
    },
    requestChecksumCalculation: "WHEN_REQUIRED",
    responseChecksumValidation: "WHEN_REQUIRED",
    maxAttempts: 2,
    retryMode: "standard",
    defaultsMode: "standard",
    useFipsEndpoint: false,
    useDualstackEndpoint: false,
    defaultUserAgentProvider: () => Promise.resolve([["sudan-birds", "0.1"]]),
  });
}
export async function signUpload(key: string, bytes: number, mime: string, expiresIn = 120) {
  const client = storage();
  try {
    return await presignCreateOnly(client, requiredEnv("R2_BUCKET"), key, bytes, mime, expiresIn);
  } finally {
    client.destroy();
  }
}
export async function signRead(key: string) {
  const client = storage();
  try {
    return await getSignedUrl(
      client,
      new GetObjectCommand({ Bucket: requiredEnv("R2_BUCKET"), Key: key }),
      { expiresIn: 60 },
    );
  } finally {
    client.destroy();
  }
}
export async function downloadImage(key: string, expectedBytes: number): Promise<Uint8Array> {
  const client = storage();
  try {
    const signal = AbortSignal.timeout(15_000);
    const result = await client.send(
      new GetObjectCommand({ Bucket: requiredEnv("R2_BUCKET"), Key: key }),
      { abortSignal: signal },
    );
    if (!result.Body) throw new ApiError(400, "invalid_image");
    const stream = result.Body.transformToWebStream();
    if (result.ContentLength !== expectedBytes || result.ContentType !== "image/jpeg") {
      await cancelImageStream(stream);
      throw new ApiError(400, "invalid_image");
    }
    // send() resolves before the body is consumed. Keep this operation's client
    // alive through stream completion/cancellation, including error paths. If
    // cancellation does not settle within its bounded grace, finally destroys
    // this operation's transport instead of waiting forever.
    return await readExactImageStream(stream, expectedBytes, signal);
  } finally {
    client.destroy();
  }
}
export async function writeVerified(key: string, bytes: Uint8Array, intentExpiresAt: string) {
  const deadline = Date.parse(intentExpiresAt);
  const expiresIn = Math.min(30, Math.floor((deadline - Date.now()) / 1000));
  if (!Number.isFinite(expiresIn) || expiresIn < 3) throw new ApiError(409, "upload_expired");
  // Canonical writes are create-only too. A retained zero-byte tombstone fences
  // even an in-flight request at R2 commit; expiration alone is not that proof.
  const url = await signUpload(key, bytes.length, "image/jpeg", expiresIn);
  // Signing may await SDK work. Withhold the PUT unless its full signed TTL
  // still fits the absolute intent/trial deadline on the same server clock.
  const remainingMs = deadline - Date.now();
  if (!Number.isFinite(remainingMs) || expiresIn * 1000 > remainingMs) {
    throw new ApiError(409, "upload_expired");
  }
  const response = await fetch(url, {
    method: "PUT",
    body: bytes as Uint8Array<ArrayBuffer>,
    headers: {
      "Content-Type": "image/jpeg",
      "Content-Length": String(bytes.length),
      "If-None-Match": "*",
    },
    signal: AbortSignal.timeout(Math.min(15_000, Math.floor(remainingMs))),
    redirect: "error",
  });
  if (!response.ok) {
    await response.body?.cancel();
    throw new ApiError(
      response.status === 412 ? 409 : 502,
      response.status === 412 ? "upload_conflict" : "image_storage_failed",
    );
  }
  await response.body?.cancel();
}
export async function removePayloadAndFence(key: string): Promise<boolean> {
  const client = storage();
  try {
    const Bucket = requiredEnv("R2_BUCKET");
    // Remove payload by replacing it with a trusted zero-byte fence. NEVER delete
    // this tombstone: earlier create-only PUTs are rejected atomically at commit.
    await client.send(
      new PutObjectCommand({
        Bucket,
        Key: key,
        Body: new Uint8Array(),
        ContentLength: 0,
        ContentType: "application/x-sudan-birds-tombstone",
        Metadata: { "birds-tombstone": "1" },
      }),
      { abortSignal: AbortSignal.timeout(10_000) },
    );
    const head = await client.send(new HeadObjectCommand({ Bucket, Key: key }), {
      abortSignal: AbortSignal.timeout(10_000),
    });
    if (head.ContentLength !== 0 || head.Metadata?.["birds-tombstone"] !== "1") {
      throw new ApiError(502, "storage_cleanup_failed");
    }
    return true;
  } finally {
    client.destroy();
  }
}
