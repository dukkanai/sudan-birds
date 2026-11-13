import { type AppleDeadline, AppleHttp } from "./apple_http.ts";
import { assert, failure, marker } from "./apple_test_fixtures.ts";

const form = () => new URLSearchParams({ token: "synthetic-token" });
function transport(reply: () => Response | Promise<Response>, deadline?: () => AppleDeadline) {
  let calls = 0, disposed = 0;
  const client = new AppleHttp({
    deadline: deadline ?? (() => ({
      signal: new AbortController().signal,
      dispose() {
        disposed++;
      },
    })),
    fetch: (_url, init) => {
      assert(init?.redirect === "error" && init.signal instanceof AbortSignal);
      calls++;
      return Promise.resolve(reply());
    },
  });
  return { client, calls: () => calls, disposed: () => disposed };
}

for (
  const [status, code, uncertain] of [
    [400, "apple_request_rejected", false],
    [401, "apple_configuration_required", false],
    [403, "apple_configuration_required", false],
    [429, "apple_rate_limited", false],
    [500, "apple_unavailable", true],
    [503, "apple_unavailable", true],
    [302, "apple_redirect_rejected", true],
    [307, "apple_redirect_rejected", true],
    [204, "apple_response_invalid", true],
  ] as const
) {
  Deno.test(`Apple HTTP ${status} retains only a fixed label and never retries`, async () => {
    const f = transport(() =>
      new Response(status === 204 ? null : marker, {
        status,
        headers: { location: "https://evil.invalid" },
      })
    );
    await failure(f.client.request("revoke", form()), code, uncertain);
    assert(f.calls() === 1 && f.disposed() === 1);
  });
}

Deno.test("Apple fetch failure has uncertain revocation outcome, no retry and no raw error", async () => {
  const f = transport(() => {
    throw new Error(marker);
  });
  await failure(f.client.request("revoke", form()), "apple_transport_failed", true);
  assert(f.calls() === 1 && f.disposed() === 1);
});

Deno.test("Apple rejects followed redirect and mismatched effective URL", async () => {
  for (const property of ["redirected", "url"]) {
    const response = new Response(null);
    Object.defineProperty(response, property, {
      value: property === "redirected" ? true : "https://evil.invalid",
    });
    const f = transport(() => response);
    await failure(f.client.request("revoke", form()), "apple_redirect_rejected", true);
    assert(f.calls() === 1);
  }
});

Deno.test("Apple timeout bounds a fetch ignoring cancellation and preserves unknown commit", async () => {
  const controller = new AbortController();
  let disposed = false;
  const f = transport(() => {
    queueMicrotask(() => controller.abort());
    // Simulates a successful remote mutation whose response never reaches us.
    return new Promise<Response>(() => {});
  }, () => ({
    signal: controller.signal,
    dispose() {
      disposed = true;
    },
  }));
  await failure(f.client.request("revoke", form()), "apple_timeout", true);
  assert(f.calls() === 1 && disposed);
});

Deno.test("Apple already-expired deadline never sends a credential", async () => {
  const controller = new AbortController();
  controller.abort();
  const f = transport(
    () => new Response(null),
    () => ({ signal: controller.signal, dispose() {} }),
  );
  await failure(f.client.request("revoke", form()), "apple_timeout");
  assert(f.calls() === 0);
});

Deno.test("Apple late response after a timeout is canceled without replacing the primary error", async () => {
  const controller = new AbortController();
  let deliver!: (response: Response) => void;
  let canceled = false;
  const f = transport(() =>
    new Promise<Response>((resolve) => {
      deliver = resolve;
    }), () => ({ signal: controller.signal, dispose() {} }));
  const pending = f.client.request("revoke", form());
  controller.abort();
  const error = await failure(pending, "apple_timeout", true);
  deliver(
    new Response(
      new ReadableStream({
        cancel() {
          canceled = true;
          throw new Error(marker);
        },
      }),
    ),
  );
  await Promise.resolve();
  await Promise.resolve();
  assert(canceled && error.code === "apple_timeout" && f.calls() === 1);
});

Deno.test("Apple empty chunk floods are bounded even when a timer cannot run", async () => {
  let reads = 0, canceled = false;
  const f = transport(() =>
    new Response(
      new ReadableStream({
        pull(controller) {
          reads++;
          controller.enqueue(new Uint8Array());
        },
        cancel() {
          canceled = true;
        },
      }),
    )
  );
  await failure(f.client.request("revoke", form()), "apple_response_invalid", true);
  assert(reads <= 1025 && canceled);
});

Deno.test("Apple timeout remains active through response body and cancels its stream", async () => {
  const controller = new AbortController();
  let canceled = false;
  const f = transport(() =>
    new Response(
      new ReadableStream({
        pull() {
          queueMicrotask(() => controller.abort());
        },
        cancel() {
          canceled = true;
        },
      }),
    ), () => ({ signal: controller.signal, dispose() {} }));
  await failure(f.client.request("revoke", form()), "apple_timeout", true);
  assert(canceled && f.calls() === 1);
});

Deno.test("Apple primary error survives stream cancel and deadline disposal errors", async () => {
  const f = transport(() =>
    new Response(
      new ReadableStream({
        cancel() {
          throw new Error(marker);
        },
      }),
      { status: 401 },
    ), () => ({
      signal: new AbortController().signal,
      dispose() {
        throw new Error(marker);
      },
    }));
  await failure(f.client.request("revoke", form()), "apple_configuration_required");
});

Deno.test("Apple successful receipt survives a cleanup exception", async () => {
  const f = transport(() => new Response(null), () => ({
    signal: new AbortController().signal,
    dispose() {
      throw new Error(marker);
    },
  }));
  assert((await f.client.request("revoke", form())).length === 0);
});

Deno.test("Apple revoke success must be exactly an empty HTTP 200 body", async () => {
  for (const body of ["{}", " ", marker, new Uint8Array([0])]) {
    const f = transport(() => new Response(body, { status: 200 }));
    await failure(f.client.request("revoke", form()), "apple_response_invalid", true);
  }
});

Deno.test("Apple bounds declared and streamed body sizes, including empty-200 revoke", async () => {
  for (const length of ["32769", "9999999999999999999999999", "-1", "NaN"]) {
    const f = transport(() =>
      new Response("{}", {
        headers: { "content-type": "application/json", "content-length": length },
      })
    );
    await failure(f.client.json("keys"), "apple_response_invalid");
  }
  let canceled = false;
  const f = transport(() =>
    new Response(
      new ReadableStream({
        start(controller) {
          controller.enqueue(new Uint8Array(16_384));
          controller.enqueue(new Uint8Array(16_385));
        },
        cancel() {
          canceled = true;
        },
      }),
      { headers: { "content-type": "application/json" } },
    )
  );
  await failure(f.client.json("keys"), "apple_response_invalid");
  assert(canceled);
  const revoke = transport(() => new Response(null, { headers: { "content-length": "1" } }));
  await failure(revoke.client.request("revoke", form()), "apple_response_invalid", true);
});

Deno.test("Apple token responses must declare JSON and use valid bounded UTF-8", async () => {
  for (const headers of [new Headers(), new Headers({ "content-type": "text/html" })]) {
    const f = transport(() => new Response("{}", { headers }));
    await failure(f.client.json("keys"), "apple_response_invalid");
  }
});

Deno.test("Apple stream read error is safely uncertain after an apparent revoke 200", async () => {
  const f = transport(() =>
    new Response(
      new ReadableStream({
        start(controller) {
          controller.error(new Error(marker));
        },
      }),
    )
  );
  await failure(f.client.request("revoke", form()), "apple_transport_failed", true);
});

Deno.test("Apple transport never logs raw inputs, responses or exceptions", async () => {
  const originals = [console.log, console.warn, console.error];
  const logs: unknown[] = [];
  console.log = console.warn = console.error = (...args) => logs.push(args);
  try {
    const f = transport(() => {
      throw new Error(marker);
    });
    await failure(f.client.request("revoke", form()), "apple_transport_failed", true);
    assert(logs.length === 0);
  } finally {
    [console.log, console.warn, console.error] = originals;
  }
});
