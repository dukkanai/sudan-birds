import { authenticated, serviceClient } from "../_shared/auth.ts";
import { ApiError, body, boundary, json, uuid } from "../_shared/http.ts";
import { processDeletion } from "../_shared/deletion_service.ts";
import { lifecycleDependencies } from "../_shared/lifecycle.ts";
import { authorizedJob } from "../_shared/job_authorization.ts";
Deno.serve(boundary(async (req) => {
  const job = await authorizedJob(
    req.headers.get("x-lifecycle-job-secret"),
    Deno.env.get("LIFECYCLE_JOB_SECRET"),
  );
  if (!job) {
    const { client } = await authenticated(req);
    const allowed = await client.rpc("is_cleanup_admin");
    if (allowed.error || allowed.data !== true) throw new ApiError(403, "admin_required");
  }
  const input = await body(req);
  const service = serviceClient();
  const deps = lifecycleDependencies(service);
  if (job && input.action !== "scheduled") throw new ApiError(403, "job_scope_denied");
  if (input.action === "scheduled") {
    if (!job) throw new ApiError(403, "job_authorization_required");
    const { data, error } = await service.rpc("claim_due_deletion_job");
    if (error) throw new ApiError(503, "cleanup_unavailable");
    if (data?.[0]) {
      const result = await processDeletion(data[0], deps);
      return json(result, result.status === "completed" ? 200 : 202);
    }
    // No deletion due: one small orphan batch, never an unbounded sweep.
  }
  if (input.action === "deletion_job") {
    const { data, error } = await service.rpc("get_deletion_job", { p_job: uuid(input.job_id) });
    if (error || !data?.[0]) throw new ApiError(404, "deletion_job_not_found");
    const result = await processDeletion(data[0], deps);
    return json(result, result.status === "completed" ? 200 : 202);
  }
  if (input.action === "cleanup" || input.action === "scheduled") {
    const { data, error } = await service.rpc("list_cleanup_objects", { p_limit: 3 });
    if (error) throw new ApiError(503, "cleanup_unavailable");
    let deleted = 0;
    for (const object of data ?? []) {
      const fenced = await deps.remove(object.object_key);
      if (!fenced) throw new ApiError(502, "cleanup_fencing_unproven");
      await deps.mark(object.object_key, fenced);
      deleted++;
    }
    return json({ deleted, more_may_remain: deleted === 3 });
  }
  throw new ApiError(400, "invalid_action");
}));
