export async function allowedProbeToken(
  provided: string | null,
  expected: string | undefined,
): Promise<boolean> {
  if (!expected || !/^[A-Za-z0-9_-]{43}$/.test(expected) || !provided || provided.length !== 43) {
    return false;
  }
  const encode = new TextEncoder();
  const [a, b] = await Promise.all(
    [expected, provided].map((value) => crypto.subtle.digest("SHA-256", encode.encode(value))),
  );
  const x = new Uint8Array(a), y = new Uint8Array(b);
  let different = 0;
  for (let i = 0; i < 32; i++) different |= x[i] ^ y[i];
  return different === 0;
}
