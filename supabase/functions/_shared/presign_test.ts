import { S3Client } from "npm:@aws-sdk/client-s3@3.1164.0";
import { presignCreateOnly } from "./presign.ts";
function assert(v: unknown): asserts v {
  if (!v) throw new Error("Assertion failed");
}
Deno.test("create-only condition, type and exact length are cryptographically signed", async () => {
  const client = new S3Client({
    region: "auto",
    endpoint: "https://synthetic.invalid",
    credentials: {
      accessKeyId: "SYNTHETIC_TEST_ONLY",
      secretAccessKey: "SYNTHETIC_NOT_A_REAL_CREDENTIAL",
    },
    requestChecksumCalculation: "WHEN_REQUIRED",
    responseChecksumValidation: "WHEN_REQUIRED",
    retryMode: "standard",
    defaultsMode: "standard",
    maxAttempts: 1,
    useFipsEndpoint: false,
    useDualstackEndpoint: false,
    defaultUserAgentProvider: () => Promise.resolve([["sudan-birds-test", "0.1"]]),
  });
  const url = new URL(
    await presignCreateOnly(
      client,
      "synthetic-bucket",
      "quarantine/synthetic",
      100,
      "image/jpeg",
      120,
    ),
  );
  const headers = url.searchParams.get("X-Amz-SignedHeaders")!.split(";");
  for (const header of ["if-none-match", "content-type", "content-length"]) {
    assert(headers.includes(header));
  }
  assert(url.searchParams.has("X-Amz-Signature"));
  client.destroy();
});
