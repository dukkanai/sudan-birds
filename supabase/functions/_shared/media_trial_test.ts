import { ApiError } from "./http.ts";
import { mediaTrial } from "./media_trial.ts";
import { assert } from "./test_fixtures.ts";

// Invented UUIDs only; no account or deployment configuration is read.
const first = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const second = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const outsider = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
const start = Date.parse("2026-01-01T00:00:00.000Z");
const end = start + 20 * 60 * 1000;
function fixture() {
  const env: Record<string, string | undefined> = {
    MEDIA_PIPELINE_ENABLED: "true",
    MEDIA_TRIAL_ACCOUNT_IDS: JSON.stringify([first, second]),
    MEDIA_TRIAL_STARTS_AT: new Date(start).toISOString(),
    MEDIA_TRIAL_EXPIRES_AT: new Date(end).toISOString(),
  };
  const clock = { now: start };
  return {
    env,
    clock,
    open: (user = first) => mediaTrial(user, (key) => env[key], () => clock.now),
  };
}
function denied(fn: () => unknown) {
  try {
    fn();
  } catch (error) {
    assert(error instanceof ApiError);
    assert(error.status === 503 && error.code === "media_pipeline_unavailable");
    assert(error.message === "media_pipeline_unavailable");
    return;
  }
  throw new Error("Expected closed trial gate");
}

Deno.test("trial flag alone or non-exact enable values never admit uploads", () => {
  for (const value of [undefined, "", "false", "TRUE", "1", "true "]) {
    const f = fixture();
    f.env.MEDIA_PIPELINE_ENABLED = value;
    denied(() => f.open());
  }
  for (
    const name of ["MEDIA_TRIAL_ACCOUNT_IDS", "MEDIA_TRIAL_STARTS_AT", "MEDIA_TRIAL_EXPIRES_AT"]
  ) {
    const f = fixture();
    delete f.env[name];
    denied(() => f.open());
  }
  denied(() =>
    mediaTrial(first, (key) => key === "MEDIA_PIPELINE_ENABLED" ? "true" : undefined, () => start)
  );
});

Deno.test("trial requires exactly two unique structurally valid UUIDs without wildcards", () => {
  for (
    const raw of [
      undefined,
      "",
      "not json",
      "[",
      "null",
      "true",
      JSON.stringify({ 0: first, 1: second, length: 2 }),
      JSON.stringify(first),
      JSON.stringify([]),
      JSON.stringify([first]),
      JSON.stringify([first, second, outsider]),
      JSON.stringify([first, first]),
      JSON.stringify([first, first.toUpperCase()]),
      JSON.stringify([first, "*"]),
      JSON.stringify([first, "all"]),
      JSON.stringify([first, `${second},${outsider}`]),
      JSON.stringify([first, ` ${second}`]),
      JSON.stringify([first, `${second}\n`]),
      JSON.stringify([first, `${second}\r\n`]),
      JSON.stringify([first, null]),
      JSON.stringify([first, 12]),
      JSON.stringify([first, {}]),
      JSON.stringify([first, []]),
      JSON.stringify([first, "00000000-0000-0000-0000-000000000000"]),
      JSON.stringify([first, "bbbbbbbb-bbbb-9bbb-8bbb-bbbbbbbbbbbb"]),
      JSON.stringify([first, "bbbbbbbb-bbbb-4bbb-0bbb-bbbbbbbbbbbb"]),
      " ".repeat(257) + JSON.stringify([first, second]),
    ]
  ) {
    const f = fixture();
    f.env.MEDIA_TRIAL_ACCOUNT_IDS = raw;
    denied(() => f.open());
  }
});

Deno.test("trial validates Auth identity and matches UUIDs exactly with canonical case", () => {
  const f = fixture();
  for (const user of [first, second, first.toUpperCase()]) {
    assert(f.open(user).uploadExpiresIn() === 120);
  }
  for (
    const user of [
      outsider,
      "",
      ` ${first}`,
      `${first}\n`,
      `${first}\r\n`,
      `${first}/suffix`,
      "*",
      "not-an-id",
    ]
  ) {
    denied(() => f.open(user));
  }
  f.env.MEDIA_TRIAL_ACCOUNT_IDS = JSON.stringify([second.toUpperCase(), first]);
  assert(f.open(second).check() === start);
});

Deno.test("trial accepts only real canonical UTC millisecond timestamps", () => {
  for (const key of ["MEDIA_TRIAL_STARTS_AT", "MEDIA_TRIAL_EXPIRES_AT"]) {
    for (
      const value of [
        undefined,
        "",
        "not-a-date",
        "2026-01-01",
        "2026-01-01T00:00:00",
        "2026-01-01T00:00:00Z",
        "2026-01-01T00:00:00.000+00:00",
        "2026-01-01T00:00:00.000z",
        "2026-01-01T00:00:00.0000Z",
        "2026-02-30T00:00:00.000Z",
        "2026-01-01T24:00:00.000Z",
        "2026-01-01T00:00:60.000Z",
        "2026-13-01T00:00:00.000Z",
        " 2026-01-01T00:00:00.000Z",
        "2026-01-01T00:00:00.000Z\n",
      ]
    ) {
      const f = fixture();
      f.env[key] = value;
      denied(() => f.open());
    }
  }
});

Deno.test("trial window has positive duration at most twenty minutes and exclusive expiry", () => {
  const f = fixture();
  for (const expiry of [start - 1, start, end + 1]) {
    f.env.MEDIA_TRIAL_EXPIRES_AT = new Date(expiry).toISOString();
    denied(() => f.open());
  }
  f.env.MEDIA_TRIAL_EXPIRES_AT = new Date(end).toISOString();
  for (const time of [start - 1, end, end + 1, NaN, Infinity, -Infinity, start + 0.5]) {
    f.clock.now = time;
    denied(() => f.open());
  }
  for (const time of [start, start + 1, end - 1]) {
    f.clock.now = time;
    assert(f.open().check() === time);
  }
});

Deno.test("trial PUT TTL caps at 120 seconds and floors remaining time without zero TTL", () => {
  const f = fixture();
  const trial = f.open();
  for (
    const [remaining, ttl] of [[120001, 120], [120000, 120], [119999, 119], [31001, 31], [1000, 1]]
  ) {
    f.clock.now = end - remaining;
    assert(trial.uploadExpiresIn() === ttl);
  }
  for (const remaining of [999, 1, 0, -1]) {
    f.clock.now = end - remaining;
    denied(() => trial.uploadExpiresIn());
  }
});

Deno.test("admitted trial rereads clock and config and cannot extend or replace its window", () => {
  for (
    const [key, value] of [
      ["MEDIA_PIPELINE_ENABLED", "false"],
      ["MEDIA_TRIAL_ACCOUNT_IDS", JSON.stringify([first, outsider])],
      ["MEDIA_TRIAL_ACCOUNT_IDS", JSON.stringify([second, outsider])],
      ["MEDIA_TRIAL_STARTS_AT", new Date(start + 1).toISOString()],
      ["MEDIA_TRIAL_EXPIRES_AT", new Date(end - 1).toISOString()],
      ["MEDIA_TRIAL_EXPIRES_AT", new Date(end + 1).toISOString()],
    ]
  ) {
    const f = fixture();
    const trial = f.open();
    f.clock.now += 100;
    f.env[key] = value;
    denied(trial.check);
    denied(trial.uploadExpiresIn);
  }
  const f = fixture();
  const trial = f.open();
  f.clock.now = end;
  denied(trial.check);
  f.clock.now = start - 1;
  denied(trial.check);
});

Deno.test("trial masks environment and clock errors without exposing raw data", () => {
  denied(() =>
    mediaTrial(first, () => {
      throw new Error("private config");
    }, () => start)
  );
  const f = fixture();
  denied(() =>
    mediaTrial(first, (key) => f.env[key], () => {
      throw new Error("private clock");
    })
  );
});
