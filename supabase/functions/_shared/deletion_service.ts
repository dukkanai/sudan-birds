import { ApiError, uuid } from "./http.ts";
import { deletionFailure } from "./deletion_errors.ts";
import { reportFailure } from "./diagnostics.ts";
export interface DeletionJob {
  id: string;
  owner_id: string;
  state: "pending" | "auth_pending" | "completed";
  not_before: string;
}
export interface DeletionDependencies {
  list(owner: string): Promise<Array<{ object_key: string }>>;
  remove(key: string): Promise<boolean>;
  mark(key: string, fenced: boolean): Promise<void>;
  ready(id: string): Promise<string>;
  deleteAuth(owner: string): Promise<void>;
  finish(id: string): Promise<void>;
  recordFailure(id: string, code: string | null): Promise<void>;
}
export async function processDeletion(
  job: DeletionJob,
  deps: DeletionDependencies,
  now = Date.now(),
) {
  // Database replies are runtime data. Validate before even returning "completed"
  // and before invoking privileged cleanup/Auth operations with their identifiers.
  try {
    uuid(job?.id);
    uuid(job.owner_id);
    if (
      !["pending", "auth_pending", "completed"].includes(job.state) ||
      typeof job.not_before !== "string" || !Number.isFinite(Date.parse(job.not_before))
    ) throw new Error();
  } catch {
    throw new ApiError(500, "invalid_deletion_job");
  }
  if (job.state === "completed") return { status: "completed" as const };
  const wait = Math.ceil((Date.parse(job.not_before) - now) / 1000);
  if (!Number.isFinite(wait)) throw new ApiError(500, "invalid_deletion_job");
  if (wait > 0) return { status: "pending" as const, job_id: job.id, retry_after_seconds: wait };
  try {
    for (const object of await deps.list(job.owner_id)) {
      const fenced = await deps.remove(object.object_key);
      if (!fenced) throw new ApiError(502, "cleanup_fencing_unproven");
      await deps.mark(object.object_key, fenced);
    }
    // This DB check requires EVERY registered object deleted, not just this batch.
    const owner = await deps.ready(job.id);
    if (owner !== job.owner_id) throw new ApiError(500, "invalid_deletion_job");
    await deps.deleteAuth(owner);
    await deps.finish(job.id);
    return { status: "completed" as const };
  } catch (error) {
    const failure = deletionFailure(error);
    try {
      await deps.recordFailure(job.id, failure.code);
    } catch {
      // Preserve the original pending classification, but do not silently lose
      // the fact that its durable failure/retry bookkeeping could not be saved.
      reportFailure("deletion_failure_record_pending");
    }
    return {
      status: "pending" as const,
      job_id: job.id,
      retry_after_seconds: failure.requiresOperator ? 3600 : 30,
      blocker_code: failure.code,
      requires_operator: failure.requiresOperator,
    };
  }
}
