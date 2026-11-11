import { authenticated, serviceClient } from "../_shared/auth.ts";
import { ApiError, body, boundary, fields, json, uuid } from "../_shared/http.ts";
import { processDeletion } from "../_shared/deletion_service.ts";
import { lifecycleDependencies } from "../_shared/lifecycle.ts";
import { authorizedJob } from "../_shared/job_authorization.ts";
export function createLifecycleHandler(deps = {
  authenticated,
  serviceClient,
  lifecycleDependencies,
  jobSecret: () => Deno.env.get("LIFECYCLE_JOB_SECRET"),
}) {
  return boundary(async (req) => {
    const job = await authorizedJob(
      req.headers.get("x-lifecycle-job-secret"),
      deps.jobSecret(),
    );
    if (!job) {
      const { client } = await deps.authenticated(req);
      const allowed = await client.rpc("is_cleanup_admin");
      if (allowed.error || allowed.data !== true) throw new ApiError(403, "admin_required");
    }
    const input = await body(req);
    if (job && input.action !== "scheduled") throw new ApiError(403, "job_scope_denied");
    if (
      typeof input.action !== "string" ||
      !["scheduled", "deletion_job", "cleanup"].includes(input.action)
    ) {
      throw new ApiError(400, "invalid_action");
    }
    fields(input, input.action === "deletion_job" ? ["action", "job_id"] : ["action"]);
    if (input.action === "scheduled" && !job) throw new ApiError(403, "job_authorization_required");
    const jobId = input.action === "deletion_job" ? uuid(input.job_id) : null;
    const service = deps.serviceClient();
    const lifecycle = deps.lifecycleDependencies(service);
    if (input.action === "scheduled") {
      const { data, error } = await service.rpc("claim_due_deletion_job");
      if (error) throw new ApiError(503, "cleanup_unavailable");
      if (data?.[0]) {
        const result = await processDeletion(data[0], lifecycle);
        return json(result, result.status === "completed" ? 200 : 202);
      }
      // No deletion due: one small orphan batch, never an unbounded sweep.
    }
    if (input.action === "deletion_job") {
      const { data, error } = await service.rpc("get_deletion_job", { p_job: jobId });
      if (error || !data?.[0]) throw new ApiError(404, "deletion_job_not_found");
      if (data[0].id !== jobId) throw new ApiError(500, "invalid_deletion_job");
      const result = await processDeletion(data[0], lifecycle);
      return json(result, result.status === "completed" ? 200 : 202);
    }
    if (input.action === "cleanup" || input.action === "scheduled") {
      const { data, error } = await service.rpc("list_cleanup_objects", { p_limit: 3 });
      if (error) throw new ApiError(503, "cleanup_unavailable");
      let deleted = 0;
      for (const object of data ?? []) {
        const fenced = await lifecycle.remove(object.object_key);
        if (!fenced) throw new ApiError(502, "cleanup_fencing_unproven");
        await lifecycle.mark(object.object_key, fenced);
        deleted++;
      }
      return json({ deleted, more_may_remain: deleted === 3 });
    }
    throw new ApiError(400, "invalid_action");
  });
}
