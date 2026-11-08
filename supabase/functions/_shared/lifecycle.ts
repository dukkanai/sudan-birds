import { serviceClient } from "./auth.ts";
import { ApiError } from "./http.ts";
import { removePayloadAndFence } from "./r2.ts";
import { type DeletionDependencies } from "./deletion_service.ts";
function dbFailure(
  error: { code?: string; message?: string } | null,
  normalPending = false,
): never {
  if (error?.message === "Cleanup fencing unproven") {
    throw new ApiError(409, "legacy_upload_review_required");
  }
  if (normalPending && error?.message === "Cleanup pending") {
    throw new ApiError(409, "cleanup_pending");
  }
  if (error?.code === "42501" || error?.code === "PGRST301") {
    throw new ApiError(503, "database_configuration_required");
  }
  throw new ApiError(503, "database_retry_required");
}
export function lifecycleDependencies(
  service: ReturnType<typeof serviceClient>,
): DeletionDependencies {
  return {
    async list(owner) {
      const { data, error } = await service.rpc("list_cleanup_objects", {
        p_owner: owner,
        p_limit: 3,
      });
      if (error) dbFailure(error);
      return data ?? [];
    },
    async remove(key) {
      try {
        return await removePayloadAndFence(key);
      } catch (error) {
        if (error instanceof ApiError && error.code === "service_not_configured") {
          throw new ApiError(503, "storage_configuration_required");
        }
        const status = typeof error === "object" && error !== null && "$metadata" in error
          ? (error as { $metadata?: { httpStatusCode?: number } }).$metadata?.httpStatusCode
          : undefined;
        if (status === 401 || status === 403) {
          throw new ApiError(503, "storage_permission_required");
        }
        throw new ApiError(503, "storage_retry_required");
      }
    },
    async mark(key, fenced) {
      const { error } = await service.rpc("mark_object_deleted", { p_key: key, p_fenced: fenced });
      if (error) dbFailure(error);
    },
    async ready(id) {
      const { data, error } = await service.rpc("deletion_ready_for_auth", { p_job: id });
      if (error || !data) dbFailure(error, true);
      return data;
    },
    async deleteAuth(owner) {
      const { error } = await service.auth.admin.deleteUser(owner);
      if (error) {
        if (error.status === 401 || error.status === 403) {
          throw new ApiError(503, "auth_configuration_required");
        }
        const check = await service.auth.admin.getUserById(owner);
        if (!check.error || check.error.status !== 404) {
          throw new ApiError(503, "auth_retry_required");
        }
      }
    },
    async finish(id) {
      const { error } = await service.rpc("finish_account_deletion", { p_job: id });
      if (error) throw new ApiError(503, "completion_retry_required");
    },
    async recordFailure(id, code) {
      const { error } = await service.rpc("record_deletion_failure", { p_job: id, p_code: code });
      if (error) throw new ApiError(503, "database_retry_required");
    },
  };
}
