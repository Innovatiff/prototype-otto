import { strict as assert } from "node:assert";
import { test } from "node:test";

import { Plan, Progression, ScheduledSession } from "@otto/shared";

import { INTERVIEW_GUIDANCE, PlanConstraints } from "../src/plans/interview.js";

// ── Step 0: the schema amendment ────────────────────────────────────

test("schedule entries carry progression overrides; templates stay untouched", () => {
  const entry = ScheduledSession.safeParse({
    sessionId: "s1",
    dayOffset: 28,
    timeOfDay: "07:00",
    progression: { loadMultiplier: 0.6, note: "deload week — keep it light" },
  });
  assert.ok(entry.success);
  // progression is optional — plain entries still parse.
  assert.ok(ScheduledSession.safeParse({ sessionId: "s1", dayOffset: 0 }).success);
  // Zero/negative multipliers are nonsense.
  assert.ok(!Progression.safeParse({ loadMultiplier: 0 }).success);
});

test("a template-style plan (few sessions, many schedule entries) validates", () => {
  const step = {
    id: "st1",
    type: "counted",
    title: "Goblet squat",
    cue: "Chest tall, sit between your heels.",
    target: { sets: 3, reps: 8, load: 20 },
    completion: "manual",
  };
  const document = {
    id: "p1",
    ownerId: "u1",
    meta: { domain: "fitness", goal: "strength", horizonDays: 56, version: 1 },
    constraints: { domain: "fitness", goal: "strength" },
    sessions: [{ id: "s1", title: "Lower A", estimatedMinutes: 45, steps: [step] }],
    schedule: Array.from({ length: 32 }, (_, i) => ({
      sessionId: "s1",
      dayOffset: i,
      progression: { loadMultiplier: 1 + 0.025 * Math.floor(i / 4) },
    })),
    status: "active",
    createdAt: "2026-08-18T12:00:00.000Z",
  };
  assert.ok(Plan.safeParse(document).success);
  // Lifecycle is part of the contract: a plan without a status is invalid.
  assert.ok(!Plan.safeParse({ ...document, status: undefined }).success);
});

// ── Step 1: the interview contract ──────────────────────────────────

test("constraints require domain and goal; domain is closed", () => {
  assert.ok(
    PlanConstraints.safeParse({
      domain: "fitness",
      goal: "get stronger",
      daysPerWeek: 4,
      minutesPerSession: 45,
      equipment: ["dumbbells"],
      limitations: ["left shoulder"],
    }).success,
  );
  assert.ok(!PlanConstraints.safeParse({ domain: "cooking", goal: "x" }).success);
  assert.ok(!PlanConstraints.safeParse({ domain: "fitness" }).success);
  assert.ok(!PlanConstraints.safeParse({ domain: "fitness", goal: "x", daysPerWeek: 9 }).success);
});

test("the interview guidance carries the load-bearing rules", () => {
  assert.ok(INTERVIEW_GUIDANCE.includes("At most 4 questions"));
  assert.ok(INTERVIEW_GUIDANCE.includes("NEVER ask anything your MEMORIES"));
  assert.ok(INTERVIEW_GUIDANCE.includes("Still working around the left shoulder?"));
  assert.ok(INTERVIEW_GUIDANCE.includes("One question per turn"));
  assert.ok(INTERVIEW_GUIDANCE.includes("MATERIALLY"));
  // All three domain menus present.
  for (const menu of ["days per week", "when they're sharpest", "minutes per day"]) {
    assert.ok(INTERVIEW_GUIDANCE.includes(menu), `missing menu item: ${menu}`);
  }
});
