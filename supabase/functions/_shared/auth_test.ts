import { supabaseKey } from "./auth.ts";
function assert(v: unknown): asserts v {
  if (!v) throw new Error("Assertion failed");
}
Deno.test("Supabase key adapter supports documented built-in default maps", () => {
  assert(
    supabaseKey(
      "public",
      (n) => n === "SUPABASE_PUBLISHABLE_KEYS" ? '{"default":"synthetic-public"}' : undefined,
    ) ===
      "synthetic-public",
  );
  assert(
    supabaseKey(
      "secret",
      (n) => n === "SUPABASE_SECRET_KEYS" ? '{"default":"synthetic-secret"}' : undefined,
    ) ===
      "synthetic-secret",
  );
  assert(
    supabaseKey(
      "secret",
      (n) => n === "SUPABASE_SERVICE_ROLE_KEY" ? "synthetic-legacy" : undefined,
    ) === "synthetic-legacy",
  );
  for (const raw of [undefined, "{", "[]", '{"other":"not-default"}', '{"default":false}']) {
    let failed = false;
    try {
      supabaseKey("secret", (n) => n === "SUPABASE_SECRET_KEYS" ? raw : undefined);
    } catch {
      failed = true;
    }
    assert(failed);
  }
});

Deno.test("public image reads use anon RLS only for absent or configured public key", async () => {
  const { resolveReadContext } = await import("./auth.ts");
  let verified = 0;
  const user = () => {
    verified++;
    return Promise.resolve("verified-user");
  };
  assert(await resolveReadContext(null, ["configured-public"], () => "anon", user) === "anon");
  assert(
    await resolveReadContext(
      "Bearer configured-public",
      ["configured-public"],
      () => "anon",
      user,
    ) === "anon",
  );
  assert(
    await resolveReadContext("Bearer real-user", ["configured-public"], () => "anon", user) ===
      "verified-user",
  );
  assert(verified === 1);
});
Deno.test("invalid expired wrong-project read tokens never downgrade to anonymous", async () => {
  const { resolveReadContext } = await import("./auth.ts");
  let anonymous = 0;
  for (
    const header of ["bad", "Bearer expired", "Bearer wrong-project", "Bearer forged", "Bearer x y"]
  ) {
    let failed = false;
    try {
      await resolveReadContext(header, ["configured-public"], () => {
        anonymous++;
        return "anon";
      }, () => Promise.reject(new Error("Auth rejection")));
    } catch {
      failed = true;
    }
    assert(failed);
  }
  assert(anonymous === 0);
});
Deno.test("named new API keys take precedence over coexisting revoked legacy keys", () => {
  const values: Record<string, string> = {
    SUPABASE_ANON_KEY: "old-public",
    SUPABASE_SERVICE_ROLE_KEY: "old-secret",
    SUPABASE_PUBLISHABLE_KEYS: '{"default":"new-public"}',
    SUPABASE_SECRET_KEYS: '{"default":"new-secret"}',
  };
  assert(supabaseKey("public", (key) => values[key]) === "new-public");
  assert(supabaseKey("secret", (key) => values[key]) === "new-secret");
  values.SUPABASE_SECRET_KEYS = "malformed";
  assert(supabaseKey("secret", (key) => values[key]) === "old-secret");
});
