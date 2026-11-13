import { Diagnostics, validateDestination, withShutdown } from "./remaining_http_local.ts";
const id = "11111111-1111-4111-8111-111111111111";
Deno.test("local transport confines Auth deletion to users created by this run", () => {
  const owned = new Set([id]);
  validateDestination(`http://127.0.0.1:54321/auth/v1/admin/users/${id}`, "DELETE", owned);
  for (
    const [url, method] of [
      [`https://example.supabase.co/auth/v1/admin/users/${id}`, "DELETE"],
      [`http://127.0.0.1:54321/auth/v1/admin/users/${id}`, "DELETE"],
      ["http://127.0.0.1:54321/rest/v1/listings", "DELETE"],
      ["http://localhost:54321/auth/v1/user", "GET"],
      ["http://user@127.0.0.1:54321/auth/v1/user", "GET"],
      ["http://127.0.0.1:54321/auth/v1/user#fragment", "GET"],
      ["http://127.0.0.1:54322/auth/v1/user", "GET"],
      ["http://127.0.0.1:54321/rest/v1/rpc/unknown", "POST"],
    ]
  ) {
    let denied = false;
    try {
      validateDestination(url, method, new Set());
    } catch {
      denied = true;
    }
    if (!denied) throw new Error("Unexpected route allowed");
  }
});

Deno.test("diagnostics preserve primary failure when shutdown also fails", async () => {
  const report = new Diagnostics();
  report.phase = "contact";
  report.checks = 42;
  report.requests = 12;
  const primary = new Error("PRIVATE_RESPONSE");
  let caught: unknown;
  try {
    await withShutdown(
      () => Promise.reject(primary),
      () => Promise.reject(new Error("SECRET_TOKEN")),
      report,
    );
  } catch (error) {
    caught = error;
  }
  if (
    caught !== primary ||
    report.failureLine() !== "FAIL local HTTP phase=contact checks=42 requests=12"
  ) throw new Error("Primary failure lost");
});
Deno.test("shutdown-only failure has its own phase and cannot emit raw details", async () => {
  const report = new Diagnostics();
  let caught = false;
  try {
    await withShutdown(
      () => Promise.resolve(),
      () => Promise.reject(new Error("PRIVATE_ID")),
      report,
    );
  } catch {
    caught = true;
  }
  if (!caught || report.failureLine() !== "FAIL local HTTP phase=shutdown checks=0 requests=0") {
    throw new Error("Missing shutdown failure");
  }
});
Deno.test("diagnostics constrain unexpected phase and counters to fixed output", () => {
  const report = new Diagnostics();
  Object.assign(report, { phase: "SECRET_TOKEN", checks: NaN, requests: -1 });
  if (report.failureLine() !== "FAIL local HTTP phase=setup checks=0 requests=0") {
    throw new Error("Unsafe diagnostic");
  }
});
