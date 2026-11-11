import { completeMedia, type MediaDependencies } from "./media_service.ts";
import { assert, jpeg } from "./test_fixtures.ts";
function fixture() {
  const source = jpeg();
  const calls: string[] = [];
  const deps: MediaDependencies = {
    capacity: () => {},
    prepare: () =>
      Promise.resolve({
        intent_id: "intent",
        source_key: "quarantine",
        expected_bytes: source.length,
        clean_key: "clean-attempt",
        existing_media: null,
        expires_at: new Date(Date.now() + 60000).toISOString(),
      }),
    download: () => Promise.resolve(source),
    write: () => {
      calls.push("write");
      return Promise.resolve();
    },
    commit: () => {
      calls.push("commit");
      return Promise.resolve({
        media_id: "00000000-0000-4000-8000-000000000001",
        published_key: "clean-attempt",
      });
    },
    remove: (key) => {
      calls.push("remove:" + key);
      return Promise.resolve(true);
    },
  };
  return { deps, calls };
}
Deno.test("verified image commits only after immutable write", async () => {
  const { deps, calls } = fixture();
  const result = await completeMedia("owner", "intent", "alt", deps);
  assert(result.status === "verified");
  assert(calls.join(",") === "write,commit");
});
Deno.test("malformed download or byte mismatch never writes or commits", async () => {
  for (const bytes of [new Uint8Array(), new Uint8Array(jpeg().length)]) {
    const { deps, calls } = fixture();
    deps.download = () => Promise.resolve(bytes);
    let failed = false;
    try {
      await completeMedia("owner", "intent", "", deps);
    } catch {
      failed = true;
    }
    assert(failed && calls.length === 0);
  }
});
Deno.test("definite racing loser removes only its own canonical key", async () => {
  const { deps, calls } = fixture();
  deps.commit = () =>
    Promise.resolve({ media_id: "00000000-0000-4000-8000-000000000001", published_key: "winner" });
  await completeMedia("owner", "intent", "", deps);
  assert(calls.join(",") === "write,remove:clean-attempt");
});
Deno.test("ambiguous commit cannot delete a possibly published canonical key", async () => {
  const { deps, calls } = fixture();
  deps.commit = () => Promise.reject(new Error("network lost after commit"));
  try {
    await completeMedia("owner", "intent", "", deps);
  } catch { /* expected */ }
  assert(calls.join(",") === "write");
});
Deno.test("replay returns existing media without download, encode or rewrite", async () => {
  const { deps, calls } = fixture();
  deps.prepare = () =>
    Promise.resolve({
      intent_id: "intent",
      source_key: "q",
      expected_bytes: 1,
      clean_key: null,
      existing_media: "00000000-0000-4000-8000-000000000002",
      expires_at: "expired",
    });
  deps.download = () => Promise.reject(new Error("Must not download"));
  assert(
    (await completeMedia("owner", "intent", "", deps)).media_id ===
      "00000000-0000-4000-8000-000000000002",
  );
  assert(calls.length === 0);
});
Deno.test("GET or PUT failure cannot publish", async () => {
  for (const stage of ["download", "write"] as const) {
    const { deps, calls } = fixture();
    deps[stage] = (): Promise<never> => Promise.reject(new Error("storage unavailable"));
    let failed = false;
    try {
      await completeMedia("owner", "intent", "", deps);
    } catch {
      failed = true;
    }
    assert(failed);
    assert(!calls.includes("commit"));
  }
});

Deno.test("malformed committed responses never fence a possibly published winner", async () => {
  for (
    const committed of [null, {}, { media_id: "invalid", published_key: "winner" }, {
      media_id: "00000000-0000-4000-8000-000000000001",
    }, { media_id: "00000000-0000-4000-8000-000000000001", published_key: "" }]
  ) {
    const { deps, calls } = fixture();
    deps.commit = () => Promise.resolve(committed as Awaited<ReturnType<typeof deps.commit>>);
    let code;
    try {
      await completeMedia("owner", "intent", "", deps);
    } catch (error) {
      code = (error as { code?: string }).code;
    }
    assert(code === "verification_pending_retry");
    assert(calls.join(",") === "write");
  }
});

Deno.test("invalid verification claims stop before download or writes", async () => {
  for (
    const overrides of [
      { intent_id: "different-intent" },
      { source_key: "" },
      { expected_bytes: 0 },
      { expected_bytes: 2_097_153 },
      { expires_at: "invalid" },
      { clean_key: "quarantine" },
      { existing_media: "not-a-uuid" },
    ]
  ) {
    const { deps, calls } = fixture();
    const claim = await deps.prepare("owner", "intent");
    deps.prepare = () => Promise.resolve({ ...claim, ...overrides });
    deps.download = () => {
      calls.push("download");
      return Promise.resolve(jpeg());
    };
    let code;
    try {
      await completeMedia("owner", "intent", "", deps);
    } catch (error) {
      code = (error as { code?: string }).code;
    }
    assert(code === "invalid_verification_response" && calls.length === 0);
  }
});

Deno.test("loser cleanup failures are observable without changing definite publication success", async () => {
  const original = console.error;
  const logs: unknown[] = [];
  console.error = (value) => logs.push(value);
  try {
    for (const mode of ["reject", "unfenced"] as const) {
      const { deps } = fixture();
      deps.commit = () =>
        Promise.resolve({
          media_id: "00000000-0000-4000-8000-000000000001",
          published_key: "winner",
        });
      deps.remove = () =>
        mode === "reject" ? Promise.reject(new Error("SECRET_KEY")) : Promise.resolve(false);
      assert((await completeMedia("owner", "intent", "", deps)).status === "verified");
    }
    assert(
      logs.length === 2 && logs.every((log) => log === '{"event":"media_loser_cleanup_pending"}'),
    );
  } finally {
    console.error = original;
  }
});
