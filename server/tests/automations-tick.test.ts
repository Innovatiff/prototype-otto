/**
 * The tick choreography, driven through injected deps — claim races,
 * handler failure posture, stale-fire suppression, schedule advancement —
 * plus the pure claim predicate and the scheduler-invoker auth checks.
 */
import { strict as assert } from "node:assert";
import { test } from "node:test";

import type { Automation } from "@otto/shared";

import { evaluateClaim, type RunCompletion } from "../src/automations/store.js";
import {
  MAX_PER_TICK,
  completionFor,
  isStaleFire,
  runTick,
  type TickDeps,
} from "../src/automations/tick.js";
import { isAuthorizedInvoker, schedulerConfig } from "../src/routes/automations.js";

const NOW = new Date("2026-08-19T11:02:00.000Z"); // 07:02 in New York

function automation(id: string, overrides: Partial<Automation> = {}): Automation {
  return {
    id,
    ownerId: "u1",
    type: "morning_brief",
    label: "Morning brief",
    enabled: true,
    schedule: { kind: "fixed", rrule: "FREQ=DAILY", timeOfDay: "07:00" },
    timezone: "America/New_York",
    action: { kind: "morning_brief", params: {} },
    lastRunAt: null,
    nextRunAt: "2026-08-19T11:00:00.000Z", // today's 07:00, two minutes ago
    lastResult: null,
    createdAt: "2026-08-01T00:00:00.000Z",
    ...overrides,
  };
}

interface Journal {
  executed: string[];
  completed: Map<string, RunCompletion>;
}

function makeDeps(
  due: Automation[],
  options: {
    claimDenied?: Set<string>;
    execute?: TickDeps["execute"];
  } = {},
): { deps: TickDeps; journal: Journal } {
  const journal: Journal = { executed: [], completed: new Map() };
  const deps: TickDeps = {
    now: () => NOW,
    loadDue: (_now, limit) => {
      assert.equal(limit, MAX_PER_TICK);
      return Promise.resolve(due);
    },
    claim: (id) =>
      Promise.resolve(
        options.claimDenied?.has(id) === true
          ? null
          : (due.find((entry) => entry.id === id) ?? null),
      ),
    complete: (id, completion) => {
      journal.completed.set(id, completion);
      return Promise.resolve();
    },
    execute:
      options.execute ??
      ((candidate) => {
        journal.executed.push(candidate.id);
        return Promise.resolve("delivered" as const);
      }),
  };
  return { deps, journal };
}

test("a due automation is claimed, executed, and advanced to tomorrow's occurrence", async () => {
  const { deps, journal } = makeDeps([automation("a1")]);
  const summary = await runTick(deps);
  assert.deepEqual(summary, { due: 1, claimed: 1, delivered: 1, suppressed: 0, failed: 0, stale: 0 });
  assert.deepEqual(journal.executed, ["a1"]);
  const completion = journal.completed.get("a1");
  assert.equal(completion?.lastResult, "delivered");
  assert.equal(completion?.lastRunAt, NOW.toISOString());
  // Recomputed in the owner's zone strictly after now: tomorrow 07:00 EDT.
  assert.equal(completion?.nextRunAt, "2026-08-20T11:00:00.000Z");
});

test("losing the claim race skips the automation entirely — no execute, no write", async () => {
  const { deps, journal } = makeDeps([automation("a1"), automation("a2")], {
    claimDenied: new Set(["a1"]),
  });
  const summary = await runTick(deps);
  assert.equal(summary.claimed, 1);
  assert.deepEqual(journal.executed, ["a2"]);
  assert.equal(journal.completed.has("a1"), false);
});

test("a handler throw records 'failed', delivers nothing, and still advances the schedule", async () => {
  const { deps, journal } = makeDeps([automation("a1")], {
    execute: () => Promise.reject(new Error("model exploded")),
  });
  const summary = await runTick(deps);
  assert.deepEqual(summary, { due: 1, claimed: 1, delivered: 0, suppressed: 0, failed: 1, stale: 0 });
  const completion = journal.completed.get("a1");
  assert.equal(completion?.lastResult, "failed");
  // Failure must not spin: the next attempt is the next occurrence, not
  // the next tick.
  assert.equal(completion?.nextRunAt, "2026-08-20T11:00:00.000Z");
});

test("a fire more than an hour past its moment is suppressed WITHOUT running the handler", async () => {
  const { deps, journal } = makeDeps([
    automation("a1", { nextRunAt: "2026-08-19T05:00:00.000Z" }), // six hours late
  ]);
  const summary = await runTick(deps);
  assert.deepEqual(summary, { due: 1, claimed: 1, delivered: 0, suppressed: 1, failed: 0, stale: 1 });
  assert.deepEqual(journal.executed, []);
  assert.equal(journal.completed.get("a1")?.lastResult, "suppressed");
});

test("a slightly late fire (inside the grace window) runs normally", async () => {
  const { deps, journal } = makeDeps([
    automation("a1", { nextRunAt: "2026-08-19T10:30:00.000Z" }), // 32 minutes late
  ]);
  const summary = await runTick(deps);
  assert.equal(summary.delivered, 1);
  assert.deepEqual(journal.executed, ["a1"]);
});

test("a relative_to_event automation parks with nextRunAt null until the calendar re-arms it", async () => {
  const { deps, journal } = makeDeps([
    automation("a1", {
      type: "meeting_prep",
      schedule: { kind: "relative_to_event", minutesBefore: 30, eventFilter: { minAttendees: 2 } },
      action: { kind: "meeting_prep", params: {} },
    }),
  ]);
  await runTick(deps);
  assert.equal(journal.completed.get("a1")?.nextRunAt, null);
});

test("a completion-write failure abandons that automation but not the rest of the pass", async () => {
  const first = automation("a1");
  const second = automation("a2");
  const { deps, journal } = makeDeps([first, second]);
  const complete = deps.complete;
  deps.complete = (id, completion) =>
    id === "a1" ? Promise.reject(new Error("firestore hiccup")) : complete(id, completion);
  const summary = await runTick(deps);
  assert.equal(summary.claimed, 2);
  assert.deepEqual(journal.executed, ["a1", "a2"]);
  assert.ok(journal.completed.has("a2"));
});

test("isStaleFire: null is never stale, garbage is always stale", () => {
  assert.equal(isStaleFire(null, NOW), false);
  assert.equal(isStaleFire("not a date", NOW), true);
  assert.equal(isStaleFire("2026-08-19T10:30:00.000Z", NOW), false);
  assert.equal(isStaleFire("2026-08-19T09:00:00.000Z", NOW), true);
});

test("completionFor stamps the run and recomputes from the rule in-zone", () => {
  const completion = completionFor(automation("a1"), "suppressed", NOW);
  assert.deepEqual(completion, {
    lastRunAt: "2026-08-19T11:02:00.000Z",
    lastResult: "suppressed",
    nextRunAt: "2026-08-20T11:00:00.000Z",
  });
});

// ── evaluateClaim: the transactional predicate, pure ────────────────

test("evaluateClaim accepts a due, enabled, unlocked automation", () => {
  assert.equal(evaluateClaim(automation("a1"), NOW)?.id, "a1");
  // An expired lock is no lock.
  assert.equal(
    evaluateClaim({ ...automation("a1"), lockedUntil: "2026-08-19T11:01:00.000Z" }, NOW)?.id,
    "a1",
  );
});

test("evaluateClaim rejects everything else", () => {
  assert.equal(evaluateClaim({ nonsense: true }, NOW), null);
  assert.equal(evaluateClaim(automation("a1", { enabled: false }), NOW), null);
  assert.equal(evaluateClaim(automation("a1", { nextRunAt: null }), NOW), null);
  assert.equal(
    evaluateClaim(automation("a1", { nextRunAt: "2026-08-19T11:05:00.000Z" }), NOW),
    null,
    "not due yet",
  );
  assert.equal(
    evaluateClaim({ ...automation("a1"), lockedUntil: "2026-08-19T11:03:30.000Z" }, NOW),
    null,
    "held by a live lock",
  );
});

// ── Scheduler invoker auth ──────────────────────────────────────────

test("schedulerConfig requires both env vars — half-configured fails closed", () => {
  assert.equal(schedulerConfig({}), null);
  assert.equal(schedulerConfig({ SCHEDULER_INVOKER: "sa@p.iam.gserviceaccount.com" }), null);
  assert.equal(schedulerConfig({ SCHEDULER_AUDIENCE: "https://api/automations/tick" }), null);
  assert.deepEqual(
    schedulerConfig({
      SCHEDULER_INVOKER: "sa@p.iam.gserviceaccount.com",
      SCHEDULER_AUDIENCE: "https://api/automations/tick",
    }),
    { invoker: "sa@p.iam.gserviceaccount.com", audience: "https://api/automations/tick" },
  );
});

test("only the configured invoker's VERIFIED email is authorized", () => {
  const config = {
    invoker: "sa@p.iam.gserviceaccount.com",
    audience: "https://api/automations/tick",
  };
  const payload = (overrides: Record<string, unknown>) =>
    ({
      iss: "https://accounts.google.com",
      sub: "123",
      aud: config.audience,
      iat: 0,
      exp: 0,
      ...overrides,
    }) as never;
  assert.equal(
    isAuthorizedInvoker(payload({ email: config.invoker, email_verified: true }), config),
    true,
  );
  assert.equal(
    isAuthorizedInvoker(payload({ email: "other@p.iam.gserviceaccount.com", email_verified: true }), config),
    false,
  );
  assert.equal(
    isAuthorizedInvoker(payload({ email: config.invoker, email_verified: false }), config),
    false,
  );
  assert.equal(isAuthorizedInvoker(payload({}), config), false);
  assert.equal(isAuthorizedInvoker(undefined, config), false);
});
