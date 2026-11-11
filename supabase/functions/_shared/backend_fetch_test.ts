import { backendFetch } from "./backend_fetch.ts";
import { fixture, id, privateMarker } from "./endpoint_fixtures.ts";
import { assert } from "./test_fixtures.ts";

Deno.test("backend transport retains caller request and combines timeout with existing cancellation", async () => {
  const previousTimeout = AbortSignal.timeout;
  const deadline = new AbortController();
  const caller = new AbortController();
  let signal: AbortSignal | null | undefined;
  let calls = 0;
  AbortSignal.timeout = (milliseconds) => {
    assert(milliseconds === 15_000);
    return deadline.signal;
  };
  try {
    const fetcher = backendFetch((_input, init) => {
      calls++;
      signal = init?.signal;
      assert(init?.method === "POST" && init?.body === "synthetic-body");
      assert(new Headers(init?.headers).get("authorization") === "Bearer synthetic");
      return Promise.resolve(Response.json({ ok: true }));
    });
    await fetcher("https://synthetic.invalid", {
      method: "POST",
      body: "synthetic-body",
      headers: { authorization: "Bearer synthetic" },
      signal: caller.signal,
    });
    assert(signal && !signal.aborted && calls === 1);
    caller.abort();
    assert(signal.aborted);
    await fetcher("https://synthetic.invalid", {
      method: "POST",
      body: "synthetic-body",
      headers: { authorization: "Bearer synthetic" },
    });
    assert(signal && !signal.aborted);
    deadline.abort();
    assert(signal.aborted);
  } finally {
    AbortSignal.timeout = previousTimeout;
  }
});

Deno.test("transport abort produces safe uncertainty without retrying the request", async () => {
  const previousTimeout = AbortSignal.timeout;
  const controller = new AbortController();
  AbortSignal.timeout = () => controller.signal;
  let calls = 0;
  try {
    const fetcher = backendFetch((_input, init) => {
      calls++;
      return new Promise<Response>((_resolve, reject) => {
        init?.signal?.addEventListener("abort", () => reject(new Error(privateMarker)), {
          once: true,
        });
      });
    });
    const pending = fetcher("https://synthetic.invalid", { method: "POST" });
    controller.abort();
    const response = await pending;
    assert(response.status === 503 && calls === 1);
    assert(await response.text() === '{"message":"upstream_unavailable"}');
  } finally {
    AbortSignal.timeout = previousTimeout;
  }
});

Deno.test("Auth and privileged deletion transport exceptions never enter raw SDK logs", async () => {
  const original = console.error;
  const logs: unknown[] = [];
  console.error = (value) => logs.push(value);
  try {
    const f = fixture();
    f.routes.set("/auth/v1/user", () => {
      throw new Error(privateMarker);
    });
    const response = await f.handlers().contact(
      f.request({ listing_id: id, explicit_consent: true }),
    );
    const failure = await response.json();
    assert(response.status === 503 && failure.error === "authentication_unavailable");
    const client = f.auth.serviceClient();
    f.routes.set(`/auth/v1/admin/users/${id}`, () => {
      throw new Error(privateMarker);
    });
    const deleted = await client.auth.admin.deleteUser(id);
    assert(deleted.error !== null);
    const rpc = await client.rpc("synthetic_mutation");
    assert(rpc.error !== null);
    assert(logs.length === 4);
    assert(logs.filter((value) => value === '{"event":"upstream_transport_failed"}').length === 3);
    assert(
      logs.includes(JSON.stringify({ event: "request_failed", request_id: failure.request_id })),
    );
    assert(!JSON.stringify(logs).includes(privateMarker));
  } finally {
    console.error = original;
  }
});
