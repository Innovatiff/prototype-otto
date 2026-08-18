import { strict as assert } from "node:assert";
import { test } from "node:test";

import { PlanCalendarEventsRequest, type Plan, type Step } from "@otto/shared";

import { applyPatch } from "../src/plans/adapt.js";
import { meterMonthKey, nextMeterValue } from "../src/plans/store.js";
import { invalidCalendarLinks, summarizePlanDoc } from "../src/routes/plans.js";

const NOW = new Date("2026-08-18T12:00:00.000Z");

function step(id: string): Step {
  return {
    id,
    type: "counted",
    title: "Goblet squat",
    cue: "Chest tall. Dumbbell at your chest.",
    target: { sets: 3, reps: 8, load: 20 },
    completion: "manual",
  };
}

function linkedPlan(): Plan {
  return {
    id: "plan-1",
    ownerId: "u1",
    meta: { domain: "fitness", goal: "get stronger", horizonDays: 28, version: 1 },
    constraints: { domain: "fitness", goal: "get stronger" },
    sessions: [
      { id: "lower-a", title: "Lower A", estimatedMinutes: 45, steps: [step("s1")] },
      { id: "upper-a", title: "Upper A", estimatedMinutes: 45, steps: [step("s2")] },
    ],
    schedule: [
      { sessionId: "lower-a", dayOffset: 0 },
      { sessionId: "upper-a", dayOffset: 2 },
      { sessionId: "lower-a", dayOffset: 7 },
      { sessionId: "upper-a", dayOffset: 9 },
    ],
    status: "active",
    calendarEvents: [
      { sessionId: "lower-a", dayOffset: 0, eventId: "ev-0" },
      { sessionId: "upper-a", dayOffset: 2, eventId: "ev-2" },
      { sessionId: "lower-a", dayOffset: 7, eventId: "ev-7" },
      { sessionId: "upper-a", dayOffset: 9, eventId: "ev-9" },
    ],
    createdAt: "2026-08-04T12:00:00.000Z",
  };
}

// ── The route's integrity check ─────────────────────────────────────

test("links must reference real schedule coordinates", () => {
  const plan = linkedPlan();
  assert.deepEqual(
    invalidCalendarLinks(plan, [{ sessionId: "lower-a", dayOffset: 0, eventId: "x" }]),
    [],
  );
  assert.deepEqual(
    invalidCalendarLinks(plan, [
      { sessionId: "lower-a", dayOffset: 3, eventId: "x" },
      { sessionId: "ghost", dayOffset: 0, eventId: "y" },
    ]),
    ["lower-a@3", "ghost@0"],
  );
});

test("the request schema caps the batch and requires verified ids", () => {
  assert.ok(!PlanCalendarEventsRequest.safeParse({ events: [] }).success);
  assert.ok(
    !PlanCalendarEventsRequest.safeParse({
      events: [{ sessionId: "s", dayOffset: 0, eventId: "" }],
    }).success,
  );
  assert.ok(
    PlanCalendarEventsRequest.safeParse({
      events: [{ sessionId: "s", dayOffset: 0, eventId: "ek-123" }],
    }).success,
  );
});

// ── Adaptation carries only still-true links ────────────────────────

test("a patch carries links for untouched entries and drops removed/shifted ones", () => {
  const result = applyPatch({
    plan: linkedPlan(),
    patch: {
      summary: "Moved next week around.",
      removeSessions: [{ sessionId: "lower-a", dayOffset: 7 }],
      shiftSessions: [{ sessionId: "upper-a", dayOffset: 9, newDayOffset: 10 }],
    },
    newId: "plan-2",
    now: NOW,
  });
  assert.ok(result.ok);
  if (result.ok) {
    // Untouched links survive; the removed and shifted ones are dropped —
    // a link must always describe the event it points at.
    assert.deepEqual(result.plan.calendarEvents, [
      { sessionId: "lower-a", dayOffset: 0, eventId: "ev-0" },
      { sessionId: "upper-a", dayOffset: 2, eventId: "ev-2" },
    ]);
  }
});

// ── List summaries: the body stays behind ───────────────────────────

test("summaries carry counts and lifecycle, never sessions or schedule", () => {
  const summary = summarizePlanDoc(linkedPlan());
  assert.deepEqual(summary, {
    id: "plan-1",
    meta: { domain: "fitness", goal: "get stronger", horizonDays: 28, version: 1 },
    status: "active",
    sessionCount: 2,
    scheduleEntryCount: 4,
    createdAt: "2026-08-04T12:00:00.000Z",
  });
  assert.ok(!("sessions" in summary));
  assert.ok(!("supersedes" in summary));
  const versioned = summarizePlanDoc({ ...linkedPlan(), supersedes: "plan-0" });
  assert.equal(versioned.supersedes, "plan-0");
});

// ── Plan metering (count only; no enforcement) ──────────────────────

test("the meter increments within a month and resets across months", () => {
  assert.equal(meterMonthKey(NOW), "2026-08");
  // First plan ever, and first plan of a new month, both count 1.
  assert.equal(nextMeterValue({}, "2026-08"), 1);
  assert.equal(nextMeterValue({ month: "2026-07", count: 9 }, "2026-08"), 1);
  // Same month increments.
  assert.equal(nextMeterValue({ month: "2026-08", count: 2 }, "2026-08"), 3);
  // Corrupt data restarts the count instead of propagating garbage.
  assert.equal(nextMeterValue({ month: "2026-08", count: "many" }, "2026-08"), 1);
  assert.equal(nextMeterValue({ month: "2026-08", count: Number.NaN }, "2026-08"), 1);
  assert.equal(nextMeterValue({ month: "2026-08", count: -4 }, "2026-08"), 1);
  assert.equal(nextMeterValue({ month: "2026-08", count: 2.9 }, "2026-08"), 3);
});

test("a plan without links produces a version without the field", () => {
  const plan = { ...linkedPlan(), calendarEvents: undefined };
  const result = applyPatch({
    plan,
    patch: { summary: "Light week.", removeSessions: [{ sessionId: "lower-a", dayOffset: 7 }] },
    newId: "plan-2",
    now: NOW,
  });
  assert.ok(result.ok);
  if (result.ok) {
    assert.equal(result.plan.calendarEvents, undefined);
  }
});
