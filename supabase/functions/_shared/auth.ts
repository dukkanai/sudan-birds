import { createClient } from "npm:@supabase/supabase-js@2.57.4";
import { ApiError } from "./http.ts";
export function requiredEnv(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new ApiError(503, "service_not_configured");
  return value;
}
export async function authenticated(req: Request) {
  const authorization = req.headers.get("authorization");
  if (!authorization?.match(/^Bearer \S+$/i)) throw new ApiError(401, "authentication_required");
  // Caller token, NEVER service_role: all queries and RPCs retain RLS.
  const client = createClient(requiredEnv("SUPABASE_URL"), supabaseKey("public"), {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data, error } = await client.auth.getUser(authorization.slice(7));
  if (error || !data.user) throw new ApiError(401, "invalid_session");
  return { client, user: data.user, token: authorization.slice(7) };
}

// Never reuse caller Authorization headers on this client. Every exposed service
// operation must derive its owner from authenticated(), not request JSON.
export function serviceClient() {
  return createClient(requiredEnv("SUPABASE_URL"), supabaseKey("secret"), {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}
// Call ONLY after Auth.getUser has verified this exact token. Account-global
// last_sign_in_at and refresh-issued iat are NOT session reauthentication proof.
export function requireRecentSignIn(token: string, expectedUserId: string, now = Date.now()) {
  try {
    if (token.length > 16384) throw new Error();
    const parts = token.split(".");
    if (parts.length !== 3) throw new Error();
    const raw = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    const payload: unknown = JSON.parse(atob(raw.padEnd(Math.ceil(raw.length / 4) * 4, "=")));
    if (
      !payload || typeof payload !== "object" || !("sub" in payload) ||
      payload.sub !== expectedUserId || !("amr" in payload) || !Array.isArray(payload.amr) ||
      payload.amr.length > 20 || !("session_id" in payload) ||
      typeof payload.session_id !== "string" ||
      !/^[a-f\d]{8}-[a-f\d]{4}-[1-8][a-f\d]{3}-[89ab][a-f\d]{3}-[a-f\d]{12}$/i.test(
        payload.session_id,
      )
    ) throw new Error();
    const methods = new Set(["password", "oauth", "otp", "totp", "sso/saml"]);
    const recent = payload.amr.filter((entry: unknown) => {
      if (
        !entry || typeof entry !== "object" || !("method" in entry) || !("timestamp" in entry) ||
        typeof entry.method !== "string" || !methods.has(entry.method) ||
        typeof entry.timestamp !== "number" || !Number.isInteger(entry.timestamp)
      ) return false;
      const age = now - entry.timestamp * 1000;
      return age >= -30000 && age <= 600000;
    }) as Array<{ timestamp: number }>;
    if (recent.length === 0) throw new Error();
    return {
      sessionId: payload.session_id,
      authenticatedAt: Math.max(...recent.map((e) => e.timestamp)),
    };
  } catch {
    throw new ApiError(403, "recent_sign_in_required");
  }
}

export function supabaseKey(
  kind: "public" | "secret",
  get: (name: string) => string | undefined = (name) => Deno.env.get(name),
): string {
  // A configured named new key wins even when a disabled legacy key remains in
  // the hosted environment. Malformed/absent maps may fall back to legacy.
  try {
    const raw = get(kind === "public" ? "SUPABASE_PUBLISHABLE_KEYS" : "SUPABASE_SECRET_KEYS");
    const parsed: unknown = raw ? JSON.parse(raw) : null;
    if (
      parsed && typeof parsed === "object" && "default" in parsed &&
      typeof parsed.default === "string" && parsed.default.length > 0
    ) return parsed.default;
  } catch { /* No secret JSON is logged. */ }
  const legacy = get(kind === "public" ? "SUPABASE_ANON_KEY" : "SUPABASE_SERVICE_ROLE_KEY");
  if (legacy) return legacy;
  throw new ApiError(503, "service_not_configured");
}

export async function resolveReadContext<T>(
  authorization: string | null,
  publicKeys: readonly string[],
  anonymous: () => T,
  verifiedUser: () => Promise<T>,
): Promise<T> {
  if (authorization === null) return anonymous();
  const match = /^Bearer (\S+)$/i.exec(authorization);
  if (!match) throw new ApiError(401, "invalid_session");
  if (publicKeys.includes(match[1])) return anonymous();
  // Any other token MUST be verified. Expired/wrong-project/malformed user tokens
  // never silently fall back to anonymous and never gain service privileges.
  return await verifiedUser();
}
export async function publicReadClient(req: Request) {
  const key = supabaseKey("public");
  const known = [key];
  const legacy = Deno.env.get("SUPABASE_ANON_KEY");
  if (legacy) known.push(legacy);
  try {
    const raw = Deno.env.get("SUPABASE_PUBLISHABLE_KEYS");
    const parsed = raw ? JSON.parse(raw) : null;
    if (parsed && typeof parsed.default === "string" && parsed.default) known.push(parsed.default);
  } catch { /* An invalid optional map grants nothing. */ }
  return await resolveReadContext(
    req.headers.get("authorization"),
    known,
    () =>
      createClient(requiredEnv("SUPABASE_URL"), key, {
        auth: { persistSession: false, autoRefreshToken: false },
      }),
    async () => (await authenticated(req)).client,
  );
}
