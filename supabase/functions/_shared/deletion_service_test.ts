import { ApiError } from "./http.ts";
import {
  type DeletionDependencies,
  type DeletionJob,
  processDeletion,
} from "./deletion_service.ts";
import { requireRecentSignIn } from "./auth.ts";
function assert(v: unknown): asserts v {
  if (!v) throw new Error("Assertion failed");
}
function fixture() {
  const calls: string[] = [];
  const job: DeletionJob = {
    id: "00000000-0000-4000-8000-000000000001",
    owner_id: "00000000-0000-4000-8000-000000000002",
    state: "pending",
    not_before: new Date(0).toISOString(),
  };
  const deps: DeletionDependencies = {
    recordFailure: () => Promise.resolve(),
    list: () => Promise.resolve([{ object_key: "one" }]),
    remove: () => {
      calls.push("remove");
      return Promise.resolve(true);
    },
    mark: () => {
      calls.push("mark");
      return Promise.resolve();
    },
    ready: () => {
      calls.push("ready");
      return Promise.resolve("00000000-0000-4000-8000-000000000002");
    },
    deleteAuth: () => {
      calls.push("auth");
      return Promise.resolve();
    },
    finish: () => {
      calls.push("finish");
      return Promise.resolve();
    },
  };
  return { job, deps, calls };
}
Deno.test("deletion waits out reusable upload URLs", async () => {
  const { job, deps, calls } = fixture();
  job.not_before = new Date(Date.now() + 60000).toISOString();
  assert((await processDeletion(job, deps)).status === "pending");
  assert(calls.length === 0);
});
Deno.test("cleanup and verification precede Auth deletion and final success", async () => {
  const { job, deps, calls } = fixture();
  assert((await processDeletion(job, deps)).status === "completed");
  assert(calls.join(",") === "remove,mark,ready,auth,finish");
});
Deno.test("failed R2 removal never marks deleted or deletes Auth", async () => {
  const { job, deps, calls } = fixture();
  deps.remove = () => Promise.reject(new Error("R2 failed"));
  assert((await processDeletion(job, deps)).status === "pending");
  assert(calls.length === 0);
});
Deno.test("incomplete batch never deletes Auth", async () => {
  const { job, deps, calls } = fixture();
  deps.ready = () => Promise.reject(new Error("more objects"));
  assert((await processDeletion(job, deps)).status === "pending");
  assert(!calls.includes("auth"));
});
Deno.test("Auth or final bookkeeping failure remains pending and retryable", async () => {
  for (const stage of ["deleteAuth", "finish"] as const) {
    const { job, deps } = fixture();
    deps[stage] = () => Promise.reject(new Error("retry later"));
    assert((await processDeletion(job, deps)).status === "pending");
  }
});
Deno.test("completed jobs are idempotent", async () => {
  const { job, deps, calls } = fixture();
  job.state = "completed";
  assert((await processDeletion(job, deps)).status === "completed");
  assert(calls.length === 0);
});
Deno.test("recent authentication binds verified JWT AMR, not another session or refresh iat", () => {
  const now = Date.now(), user = "synthetic-owner";
  const token = (payload: unknown) =>
    "synthetic." +
    btoa(
      JSON.stringify({
        session_id: "00000000-0000-4000-8000-000000000001",
        ...(payload as Record<string, unknown>),
      }),
    ).replace(/=/g, "") + ".signature";
  requireRecentSignIn(
    token({ sub: user, amr: [{ method: "oauth", timestamp: Math.floor(now / 1000) - 10 }] }),
    user,
    now,
  );
  for (
    const payload of [
      {
        sub: user,
        iat: Math.floor(now / 1000),
        amr: [{ method: "oauth", timestamp: Math.floor(now / 1000) - 601 }],
      },
      { sub: user, iat: Math.floor(now / 1000) },
      { sub: "other", amr: [{ method: "password", timestamp: Math.floor(now / 1000) }] },
      { sub: user, amr: [{ method: "token_refresh", timestamp: Math.floor(now / 1000) }] },
      { sub: user, amr: [{ method: "oauth", timestamp: Math.floor(now / 1000) + 31 }] },
    ]
  ) {
    let failed = false;
    try {
      requireRecentSignIn(token(payload), user, now);
    } catch {
      failed = true;
    }
    assert(failed);
  }
});

Deno.test("absence without commit-time fencing cannot delete Auth", async () => {
  const { job, deps, calls } = fixture();
  deps.remove = () => Promise.resolve(false);
  assert((await processDeletion(job, deps)).status === "pending");
  assert(!calls.includes("mark"));
  assert(!calls.includes("auth"));
});
Deno.test("operator blockers are durable sanitized codes rather than generic progress", async () => {
  const { job, deps } = fixture();
  let saved: string | null = null;
  deps.remove = () => Promise.reject(new ApiError(503, "storage_configuration_required"));
  deps.recordFailure = (_id, code) => {
    saved = code;
    return Promise.resolve();
  };
  const result = await processDeletion(job, deps);
  assert(result.status === "pending");
  assert("requires_operator" in result && result.requires_operator);
  assert(saved === "storage_configuration_required");
  assert(JSON.stringify(result).includes("storage_configuration_required"));
});
Deno.test("unknown failures never leak raw messages and ordinary remaining batches are not blockers", async () => {
  for (
    const error of [new Error("SECRET_TOKEN_PRIVATE_CONTACT"), new ApiError(409, "cleanup_pending")]
  ) {
    const { job, deps } = fixture();
    deps.ready = () => Promise.reject(error);
    const result = await processDeletion(job, deps);
    assert(!JSON.stringify(result).includes("SECRET"));
    assert(result.status === "pending");
    if (error instanceof ApiError) assert("blocker_code" in result && result.blocker_code === null);
  }
});

Deno.test("invalid deletion jobs cannot run cleanup Auth deletion or report completion", async () => {
  for (
    const overrides of [
      { id: "" },
      { owner_id: "" },
      { state: "unknown" },
      { not_before: "invalid" },
      { state: "completed", owner_id: "invalid" },
    ]
  ) {
    const { job, deps, calls } = fixture();
    deps.list = () => {
      calls.push("list");
      return Promise.resolve([]);
    };
    deps.recordFailure = () => {
      calls.push("record");
      return Promise.resolve();
    };
    let code;
    try {
      await processDeletion({ ...job, ...overrides } as DeletionJob, deps);
    } catch (error) {
      code = (error as { code?: string }).code;
    }
    assert(code === "invalid_deletion_job" && calls.length === 0);
  }
});

Deno.test("failure-record persistence error is observable while retaining original blocker", async () => {
  const { job, deps } = fixture();
  const original = console.error;
  const logs: unknown[] = [];
  console.error = (value) => logs.push(value);
  try {
    deps.remove = () => Promise.reject(new ApiError(503, "storage_permission_required"));
    deps.recordFailure = () => Promise.reject(new Error("SECRET_SQL"));
    const result = await processDeletion(job, deps);
    assert(
      result.status === "pending" && "blocker_code" in result &&
        result.blocker_code === "storage_permission_required",
    );
    assert(logs.length === 1 && logs[0] === '{"event":"deletion_failure_record_pending"}');
  } finally {
    console.error = original;
  }
});
