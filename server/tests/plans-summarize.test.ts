import { strict as assert } from "node:assert";
import { test } from "node:test";

import { summarizeFacts, summaryLine } from "../src/plans/summarize.js";
import { executeToolUse, type ToolContext } from "../src/tools/execute.js";
import type { TurnEvent } from "@otto/shared";

function eightWeekPlan(overrides: Record<string, unknown> = {}) {
  const schedule = [];
  for (let week = 0; week < 8; week += 1) {
    const progression = week === 4 ? { loadMultiplier: 0.6, note: "deload" } : undefined;
    schedule.push(
      { sessionId: "lower-a", dayOffset: week * 7, progression },
      { sessionId: "upper-a", dayOffset: week * 7 + 2, progression },
      { sessionId: "lower-b", dayOffset: week * 7 + 4, progression },
      { sessionId: "upper-b", dayOffset: week * 7 + 5, progression },
    );
  }
  return {
    meta: { horizonDays: 56 },
    sessions: [
      { title: "Lower A", estimatedMinutes: 45 },
      { title: "Upper A", estimatedMinutes: 45 },
      { title: "Lower B", estimatedMinutes: 45 },
      { title: "Upper B", estimatedMinutes: 45 },
    ],
    schedule,
    ...overrides,
  };
}

test("summary facts are computed from the plan, deterministically", () => {
  const facts = summarizeFacts(eightWeekPlan());
  assert.equal(facts.weeks, 8);
  assert.equal(facts.daysPerWeek, 4);
  assert.equal(facts.minutes, "45");
  assert.equal(facts.deloadWeek, 5);
  assert.deepEqual(facts.templateTitles, ["Lower A", "Upper A", "Lower B", "Upper B"]);
  assert.equal(
    summaryLine(eightWeekPlan()),
    "8 weeks · 4 sessions/week · ~45 min · deload week 5 · " +
      "templates: Lower A, Upper A, Lower B, Upper B",
  );
});

test("varied session lengths become a range; no deload omits the part", () => {
  const plan = eightWeekPlan({
    meta: { horizonDays: 28 },
    sessions: [
      { title: "Deep work day", estimatedMinutes: 30 },
      { title: "Meeting day", estimatedMinutes: 60 },
      { title: "Lower B", estimatedMinutes: 45 },
      { title: "Upper B", estimatedMinutes: 45 },
    ],
    schedule: [
      { sessionId: "a", dayOffset: 0 },
      { sessionId: "b", dayOffset: 2 },
      { sessionId: "a", dayOffset: 7 },
    ],
  });
  const facts = summarizeFacts(plan);
  assert.equal(facts.weeks, 4);
  assert.equal(facts.minutes, "30-60");
  assert.equal(facts.deloadWeek, null);
  assert.ok(!summaryLine(plan).includes("deload"));
});

test("a mixed-load week does not count as the deload week", () => {
  const plan = eightWeekPlan({
    schedule: [
      { sessionId: "lower-a", dayOffset: 28, progression: { loadMultiplier: 0.6 } },
      { sessionId: "upper-a", dayOffset: 30, progression: { loadMultiplier: 1.05 } },
      { sessionId: "lower-a", dayOffset: 0 },
    ],
  });
  assert.equal(summarizeFacts(plan).deloadWeek, null);
});

// ── The executor's no-API failure path ──────────────────────────────

test("invalid generate_plan input fails as is_error without emitting events", async () => {
  const emitted: TurnEvent[] = [];
  const ctx: ToolContext = {
    uid: "u1",
    turnId: "t1",
    now: new Date("2026-03-05T12:00:00Z"),
    timezone: "America/New_York",
    entitled: { tier: "free", meterUid: "u1", anchorAt: null, hasConsent: true },
    emit: (event) => emitted.push(event),
  };
  const outcome = await executeToolUse("generate_plan", { domain: "cooking" }, ctx);
  assert.equal(outcome.isError, true);
  assert.match(outcome.result, /domain and goal/);
  assert.deepEqual(emitted, []);
});
