import { ApiError, uuid } from "./http.ts";

const unavailable = () => new ApiError(503, "media_pipeline_unavailable");
const maxWindowMs = 20 * 60 * 1000;
function account(value: unknown): string {
  // Require the exact UUID length before validation and case normalization.
  if (typeof value !== "string" || value.length !== 36) throw unavailable();
  return uuid(value).toLowerCase();
}
function utc(value: string | undefined): number {
  if (!value || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(value)) {
    throw unavailable();
  }
  const parsed = Date.parse(value);
  if (!Number.isFinite(parsed) || new Date(parsed).toISOString() !== value) throw unavailable();
  return parsed;
}

// Only a fixed, explicitly configured two-fixture trial is supported. The flag
// alone cannot enable production uploads. Never expose raw configuration/IDs.
export function mediaTrial(
  userId: string,
  getEnv: (name: string) => string | undefined,
  now: () => number,
) {
  const read = () => {
    try {
      if (getEnv("MEDIA_PIPELINE_ENABLED") !== "true") throw unavailable();
      const raw = getEnv("MEDIA_TRIAL_ACCOUNT_IDS");
      if (!raw || raw.length > 256) throw unavailable();
      const parsed: unknown = JSON.parse(raw);
      if (!Array.isArray(parsed) || parsed.length !== 2) throw unavailable();
      const accounts = parsed.map(account).sort();
      if (accounts[0] === accounts[1] || !accounts.includes(account(userId))) {
        throw unavailable();
      }
      const starts = utc(getEnv("MEDIA_TRIAL_STARTS_AT"));
      const expires = utc(getEnv("MEDIA_TRIAL_EXPIRES_AT"));
      const current = now();
      if (
        expires <= starts || expires - starts > maxWindowMs ||
        !Number.isSafeInteger(current) || current < starts || current >= expires
      ) throw unavailable();
      return { accounts: accounts.join(","), starts, expires, current };
    } catch {
      // Includes malformed values, environment access and clock failures.
      throw unavailable();
    }
  };
  const admitted = read();
  const check = () => {
    const active = read();
    // Configuration changes cannot extend or replace an admitted request's
    // authorization. New requests still validate the entire fixed window.
    if (
      active.accounts !== admitted.accounts || active.starts !== admitted.starts ||
      active.expires !== admitted.expires
    ) throw unavailable();
    return active.current;
  };
  return {
    check,
    expiresAt: new Date(admitted.expires).toISOString(),
    uploadExpiresIn() {
      const ttl = Math.min(120, Math.floor((admitted.expires - check()) / 1000));
      if (ttl < 1) throw unavailable();
      return ttl;
    },
  };
}
