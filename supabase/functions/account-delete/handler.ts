import { authenticated, requireRecentSignIn, serviceClient } from "../_shared/auth.ts";
import { ApiError, body, boundary, fields, json } from "../_shared/http.ts";
import { processDeletion } from "../_shared/deletion_service.ts";
import { lifecycleDependencies } from "../_shared/lifecycle.ts";
export function createAccountDeleteHandler(
  deps = { authenticated, serviceClient, lifecycleDependencies },
) {
  return boundary(async (req) => {
    const { user, token } = await deps.authenticated(req);
    const input = await body(req);
    fields(input, ["confirmation"]);
    if (input.confirmation !== "DELETE_MY_ACCOUNT") {
      throw new ApiError(400, "deletion_confirmation_required");
    }
    const recent = requireRecentSignIn(token, user.id);
    const service = deps.serviceClient();
    const { data, error } = await service.rpc("begin_account_deletion", {
      p_owner: user.id,
      p_session: recent.sessionId,
      p_auth_at: recent.authenticatedAt,
    });
    if (error?.code === "42501") throw new ApiError(403, "recent_sign_in_required");
    if (error || !data) throw new ApiError(503, "deletion_unavailable");
    if (data.owner_id !== user.id) throw new ApiError(500, "invalid_deletion_job");
    const result = await processDeletion(data, deps.lifecycleDependencies(service));
    return json(result, result.status === "completed" ? 200 : 202);
  });
}
