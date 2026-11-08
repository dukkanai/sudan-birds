import { authenticated, requireRecentSignIn, serviceClient } from "../_shared/auth.ts";
import { ApiError, body, boundary, json } from "../_shared/http.ts";
import { processDeletion } from "../_shared/deletion_service.ts";
import { lifecycleDependencies } from "../_shared/lifecycle.ts";
Deno.serve(boundary(async (req) => {
  const { user, token } = await authenticated(req);
  const input = await body(req);
  if (input.confirmation !== "DELETE_MY_ACCOUNT") {
    throw new ApiError(400, "deletion_confirmation_required");
  }
  const recent = requireRecentSignIn(token, user.id);
  const service = serviceClient();
  const { data, error } = await service.rpc("begin_account_deletion", {
    p_owner: user.id,
    p_session: recent.sessionId,
    p_auth_at: recent.authenticatedAt,
  });
  if (error?.code === "42501") throw new ApiError(403, "recent_sign_in_required");
  if (error || !data) throw new ApiError(503, "deletion_unavailable");
  const result = await processDeletion(data, lifecycleDependencies(service));
  return json(result, result.status === "completed" ? 200 : 202);
}));
