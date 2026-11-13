import { PutObjectCommand, type S3Client } from "npm:@aws-sdk/client-s3@3.1164.0";
import { getSignedUrl } from "npm:@aws-sdk/s3-request-presigner@3.1164.0";
import { ApiError } from "./http.ts";
export async function presignCreateOnly(
  client: S3Client,
  bucket: string,
  key: string,
  bytes: number,
  mime: string,
  expiresIn: number,
) {
  const url = await getSignedUrl(
    client,
    new PutObjectCommand({
      Bucket: bucket,
      Key: key,
      ContentType: mime,
      ContentLength: bytes,
      IfNoneMatch: "*",
    }),
    {
      expiresIn,
      signableHeaders: new Set(["if-none-match", "content-type", "content-length"]),
    },
  );
  const signed = new URL(url).searchParams.get("X-Amz-SignedHeaders")?.split(";") ?? [];
  if (!["if-none-match", "content-type", "content-length"].every((h) => signed.includes(h))) {
    throw new ApiError(503, "conditional_upload_unavailable");
  }
  return url;
}
