import { ApiError } from "./http.ts";
export const operatorErrors = new Set([
  "storage_configuration_required",
  "storage_permission_required",
  "legacy_upload_review_required",
  "auth_configuration_required",
  "database_configuration_required",
]);
const retryErrors = new Set([
  "storage_retry_required",
  "auth_retry_required",
  "database_retry_required",
  "completion_retry_required",
  "cleanup_retry_required",
]);
export function deletionFailure(error: unknown) {
  const code = error instanceof ApiError ? error.code : "cleanup_retry_required";
  if (code === "cleanup_pending") return { code: null, requiresOperator: false };
  const safe = operatorErrors.has(code) || retryErrors.has(code) ? code : "cleanup_retry_required";
  return { code: safe, requiresOperator: operatorErrors.has(safe) };
}
