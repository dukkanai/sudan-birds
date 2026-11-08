import { GetObjectCommand, PutObjectCommand, S3Client } from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";
import { requiredEnv } from "./auth.ts";
import { ApiError } from "./http.ts";
function storage() {
  const account = requiredEnv("R2_ACCOUNT_ID");
  if (!/^[a-f\d]{32}$/i.test(account)) throw new ApiError(503, "service_not_configured");
  return new S3Client({
    region: "auto",
    endpoint: `https://${account}.r2.cloudflarestorage.com`,
    credentials: {
      accessKeyId: requiredEnv("R2_ACCESS_KEY_ID"),
      secretAccessKey: requiredEnv("R2_SECRET_ACCESS_KEY"),
    },
    requestChecksumCalculation: "WHEN_REQUIRED",
    responseChecksumValidation: "WHEN_REQUIRED",
  });
}
export async function signUpload(key: string, bytes: number, mime: string) {
  // Length and type are signed but are NOT a substitute for decoding verification.
  const command = new PutObjectCommand({
    Bucket: requiredEnv("R2_BUCKET"),
    Key: key,
    ContentType: mime,
    ContentLength: bytes,
  });
  return await getSignedUrl(storage(), command, { expiresIn: 120 });
}
export async function signRead(key: string) {
  const command = new GetObjectCommand({ Bucket: requiredEnv("R2_BUCKET"), Key: key });
  return await getSignedUrl(storage(), command, { expiresIn: 60 });
}
