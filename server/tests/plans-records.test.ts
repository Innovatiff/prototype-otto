import { strict as assert } from "node:assert";
import { test } from "node:test";

import { SessionRecordUpload, type Plan, type SessionRecord, type Step } from "@otto/shared";

import { buildAdaptMessage } from "../src/plans/adapt.js";
import { summarizeRecords } from "../src/routes/plans.js";

// Plan created Aug 4 noon; "now" is Aug 18 noon — 14 full days elapsed.
const NOW = new Date("2026-08-18T12:00:00.000Z");

function step(id: string): Step {
  return {
    id,
    type: "counted",
    title: "Movement",
    cue: "Go.",
    target: { sets: 3, reps: 8, load: 20 },
    completion: "manual",
  };
}

function plan(): Plan {
  const schedule = [];
  for (let week = 0; week < 8; week += 1) {
    schedule.push(
      { sessionId: "lower-a", dayOffset: week * 7 },
      { sessionId: "upper-a", dayOffset: week * 7 + 2 },
    );
  }
  return {
    id: "plan-1",
    ownerId: "u1",
    meta: { domain: "fitness", goal: "get stronger", horizonDays: 56, version: 1 },
    constraints: { domain: "fitness", goal: "get stronger" },
    sessions: [
      { id: "lower-a", title: "Lower A", estimatedMinutes: 45, steps: [step("s1")] },
      { id: "upper-a", title: "Upper A", estimatedMinutes: 45, steps: [step("s2"), step("s3")] },
    ],
    schedule,
    status: "active",
    createdAt: "2026-08-04T12:00:00.000Z",
  };
}

function record(
  id: string,
  completedAt: string,
  overrides: Partial<SessionRecord> = {},
): SessionRecord {
  return {
    id,
    ownerId: "u1",
    planId: "plan-1",
    sessionId: "lower-a",
    startedAt: completedAt,
    completedAt,
    completedSteps: ["s1"],
    skippedSteps: [],
    loggedValues: {},
    durationSec: 2400,
    endedEarly: false,
    ...overrides,
  };
}

test("adherence counts scheduled-past against attended, overall and rolling week", () => {
  // 14 days elapsed → scheduled entries with dayOffset < 14: days 0, 2, 7, 9.
  const summary = summarizeRecords(
    plan(),
    [
      record("r1", "2026-08-04T13:00:00.000Z"), // day 0 — outside the rolling week
      record("r2", "2026-08-12T13:00:00.000Z"), // day 8 — inside it
    ],
    NOW,
  );
  assert.equal(summary.scheduledToDate, 4);
  assert.equal(summary.records, 2);
  assert.equal(summary.missedToDate, 2);
  // Rolling week [Aug 11, Aug 18): scheduled days 7 (Aug 11) and 9 (Aug 13);
  // one record attended → one missed. Two would trigger the check-in.
  assert.equal(summary.missedThisWeek, 1);
  assert.equal(summary.lastCompletedAt, "2026-08-12T13:00:00.000Z");
});

test("an ended-early session still counts as showing up", () => {
  const summary = summarizeRecords(
    plan(),
    [record("r1", "2026-08-12T13:00:00.000Z", { endedEarly: true, completedSteps: [] })],
    NOW,
  );
  assert.equal(summary.missedToDate, 3);
  assert.equal(summary.missedThisWeek, 1);
});

test("steps skipped in two or more sessions become substitution candidates", () => {
  const summary = summarizeRecords(
    plan(),
    [
      record("r1", "2026-08-05T13:00:00.000Z", {
        sessionId: "upper-a",
        skippedSteps: ["s2", "s2"], // duplicates within one session count once
      }),
      record("r2", "2026-08-12T13:00:00.000Z", {
        sessionId: "upper-a",
        skippedSteps: ["s2", "s3"],
      }),
    ],
    NOW,
  );
  assert.deepEqual(summary.substitutionCandidates, [{ stepId: "s2", skips: 2 }]);
});

test("latest logged values win — progressive overload reads what actually happened", () => {
  const summary = summarizeRecords(
    plan(),
    [
      // Passed newest-first, exactly as loadSessionRecords returns them.
      record("r2", "2026-08-12T13:00:00.000Z", { loggedValues: { s1: "62.5 kilos" } }),
      record("r1", "2026-08-05T13:00:00.000Z", {
        loggedValues: { s1: "60 kilos", s3: "8 reps" },
      }),
    ],
    NOW,
  );
  assert.deepEqual(summary.latestLoggedValues, { s1: "62.5 kilos", s3: "8 reps" });
});

test("the upload schema carries the spec's exact shape", () => {
  const parsed = SessionRecordUpload.safeParse({
    sessionId: "lower-a",
    scheduledDate: "2026-08-18T17:00:00.000Z",
    startedAt: "2026-08-18T17:01:00.000Z",
    completedAt: "2026-08-18T17:46:00.000Z",
    completedSteps: ["s1"],
    skippedSteps: [],
    loggedValues: { s1: "135 pounds" },
    durationSec: 2700,
    endedEarly: false,
  });
  assert.ok(parsed.success);
  assert.ok(!SessionRecordUpload.safeParse({ sessionId: "x" }).success);
});

test("adaptation sees what actually happened", () => {
  const message = buildAdaptMessage(
    plan(),
    "left shoulder is bothering them",
    NOW,
    [
      record("r1", "2026-08-12T13:00:00.000Z", {
        sessionId: "upper-a",
        skippedSteps: ["s2"],
        loggedValues: { s3: "20 kilos" },
      }),
    ],
  );
  assert.ok(message.includes("RECENT SESSIONS (newest first"));
  assert.ok(message.includes('"skippedSteps":["s2"]'));
  assert.ok(message.includes('"s3":"20 kilos"'));
  // Without records the section disappears entirely.
  const bare = buildAdaptMessage(plan(), "same", NOW, []);
  assert.ok(!bare.includes("RECENT SESSIONS"));
});
