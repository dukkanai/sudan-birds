import { createClient } from "@supabase/supabase-js";
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
  const client = createClient(requiredEnv("SUPABASE_URL"), requiredEnv("SUPABASE_ANON_KEY"), {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data, error } = await client.auth.getUser(authorization.slice(7));
  if (error || !data.user) throw new ApiError(401, "invalid_session");
  return { client, user: data.user };
}
