import { strict as assert } from "node:assert";
import { test } from "node:test";

import type { Plan, Step } from "@otto/shared";

import {
  ADAPT_SYSTEM_PROMPT,
  applyPatch,
  PatchPayload,
  PLAN_ADAPT_TOOL,
} from "../src/plans/adapt.js";
import { formatPlans } from "../src/persona/system.js";

const NOW = new Date("2026-08-18T12:00:00.000Z");

function step(id: string, title: string, cue: string): Step {
  return {
    id,
    type: "counted",
    title,
    cue,
    target: { sets: 3, reps: 8, load: 20 },
    completion: "manual",
  };
}

/** 8-week dumbbell plan, two templates, deliberately WITHOUT a deload week —
 *  any successful patch proves adaptation skips the deload rule. */
function basePlan(): Plan {
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
    constraints: {
      domain: "fitness",
      goal: "get stronger",
      equipment: ["dumbbells", "bench"],
      minutesPerSession: 45,
    },
    sessions: [
      {
        id: "lower-a",
        title: "Lower A",
        estimatedMinutes: 45,
        steps: [step("s1", "Goblet squat", "Dumbbell at your chest. Sit between your heels.")],
      },
      {
        id: "upper-a",
        title: "Upper A",
        estimatedMinutes: 45,
        steps: [
          step("s2", "Overhead press", "Dumbbells at your shoulders. Brace, press straight up."),
          step("s3", "One-arm row", "Knee on the bench. Pull the dumbbell to your hip."),
        ],
      },
    ],
    schedule,
    status: "active",
    createdAt: "2026-08-04T12:00:00.000Z",
  };
}

function apply(patch: PatchPayload, plan = basePlan()) {
  return applyPatch({ plan, patch, newId: "plan-2", now: NOW });
}

// ── The shoulder case: swap a movement, everything else stands ──────

test("a step replacement swaps only the affected movement and mints a new version", () => {
  const plan = basePlan();
  const result = apply(
    {
      summary: "Swapped overhead pressing out for two weeks. Everything else stands.",
      replaceSteps: [
        {
          sessionId: "upper-a",
          stepId: "s2",
          newStep: step("s2b", "Landmine-style floor press", "Lie back. Dumbbells over your chest, elbows at forty-five."),
        },
      ],
    },
    plan,
  );
  assert.ok(result.ok);
  if (result.ok) {
    const upper = result.plan.sessions.find((s) => s.id === "upper-a");
    assert.deepEqual(upper?.steps.map((s) => s.title), [
      "Landmine-style floor press",
      "One-arm row",
    ]);
    // Untouched template, schedule, constraints all stand.
    assert.deepEqual(
      result.plan.sessions.find((s) => s.id === "lower-a"),
      plan.sessions[0],
    );
    assert.deepEqual(result.plan.schedule, plan.schedule);
    // Immutability contract: new id, version bumped, supersedes set, and
    // the input plan object untouched.
    assert.equal(result.plan.id, "plan-2");
    assert.equal(result.plan.meta.version, 2);
    assert.equal(result.plan.supersedes, "plan-1");
    assert.equal(result.plan.status, "active");
    assert.equal(plan.meta.version, 1);
    assert.equal(plan.sessions[1]?.steps[0]?.title, "Overhead press");
  }
});

// ── Missed days: reshape the remaining schedule ─────────────────────

test("remove and shift ops address entries by their original coordinates", () => {
  const result = apply({
    summary: "Moved this week around the missed days.",
    removeSessions: [{ sessionId: "lower-a", dayOffset: 14 }],
    shiftSessions: [{ sessionId: "upper-a", dayOffset: 16, newDayOffset: 18 }],
    modifySessions: [
      // Addresses the SAME entry post-shift by its ORIGINAL dayOffset.
      { sessionId: "upper-a", dayOffset: 16, progression: { loadMultiplier: 0.9, note: "easy return" } },
    ],
  });
  assert.ok(result.ok);
  if (result.ok) {
    assert.equal(result.plan.schedule.length, 16 - 1);
    assert.ok(!result.plan.schedule.some((e) => e.sessionId === "lower-a" && e.dayOffset === 14));
    const shifted = result.plan.schedule.find((e) => e.dayOffset === 18);
    assert.equal(shifted?.sessionId, "upper-a");
    assert.equal(shifted?.progression?.loadMultiplier, 0.9);
    // Schedule comes back sorted.
    const offsets = result.plan.schedule.map((e) => e.dayOffset);
    assert.deepEqual(offsets, [...offsets].sort((a, b) => a - b));
  }
});

test("removing every occurrence of a template prunes it from the new version", () => {
  const result = apply({
    summary: "Dropped the upper sessions.",
    removeSessions: Array.from({ length: 8 }, (_, week) => ({
      sessionId: "upper-a",
      dayOffset: week * 7 + 2,
    })),
  });
  assert.ok(result.ok);
  if (result.ok) {
    assert.deepEqual(result.plan.sessions.map((s) => s.id), ["lower-a"]);
    assert.ok(result.plan.schedule.every((e) => e.sessionId === "lower-a"));
  }
});

test("adding an occurrence keeps its template alive and validates", () => {
  const result = apply({
    summary: "Re-placed the missed session on Saturday.",
    removeSessions: [{ sessionId: "upper-a", dayOffset: 16 }],
    addSessions: [{ sessionId: "upper-a", dayOffset: 20 }],
  });
  assert.ok(result.ok);
  if (result.ok) {
    assert.ok(result.plan.schedule.some((e) => e.sessionId === "upper-a" && e.dayOffset === 20));
  }
});

// ── Bad patches are rejected with exact, feedable errors ────────────

test("unknown targets fail with named errors", () => {
  const result = apply({
    summary: "x",
    replaceSteps: [{ sessionId: "ghost", stepId: "s1", newStep: step("n", "t", "c") }],
    removeSessions: [{ sessionId: "lower-a", dayOffset: 3 }],
  });
  assert.ok(!result.ok);
  if (!result.ok) {
    assert.ok(result.errors.some((e) => e.includes('unknown session "ghost"')));
    assert.ok(result.errors.some((e) => e.includes('no schedule entry "lower-a" at day 3')));
  }
});

test("a shift outside the horizon fails structural validation", () => {
  const result = apply({
    summary: "x",
    shiftSessions: [{ sessionId: "lower-a", dayOffset: 0, newDayOffset: 56 }],
  });
  assert.ok(!result.ok);
  if (!result.ok) {
    assert.ok(result.errors.some((e) => e.includes("outside horizon")));
  }
});

test("a replacement that violates equipment is caught by the safety re-check", () => {
  const result = apply({
    summary: "x",
    replaceSteps: [
      {
        sessionId: "upper-a",
        stepId: "s2",
        newStep: step("s2b", "Barbell bench press", "Barbell over your chest. Unrack, lower to touch."),
      },
    ],
  });
  assert.ok(!result.ok);
  if (!result.ok) {
    assert.ok(result.errors.some((e) => e.includes("equipment-violation")));
  }
});

test("a progression jump introduced by a patch is caught; the deload rule is not applied", () => {
  const jump = apply({
    summary: "x",
    modifySessions: [
      { sessionId: "lower-a", dayOffset: 7, progression: { loadMultiplier: 2.0 } },
    ],
  });
  assert.ok(!jump.ok);
  if (!jump.ok) {
    assert.ok(jump.errors.some((e) => e.includes("progression-too-fast")));
  }
  // The base plan has NO deload week, yet a clean patch passes — the deload
  // rule governs how plans are written, not how they are repaired.
  const clean = apply({
    summary: "ok",
    removeSessions: [{ sessionId: "lower-a", dayOffset: 0 }],
  });
  assert.ok(clean.ok);
});

test("the patch schema requires a spoken one-sentence summary", () => {
  assert.ok(!PatchPayload.safeParse({ removeSessions: [] }).success);
  assert.ok(PatchPayload.safeParse({ summary: "Done." }).success);
});

// ── Prompt and tool pins ────────────────────────────────────────────

test("the adapt prompt carries the diff-not-rewrite rules", () => {
  assert.ok(ADAPT_SYSTEM_PROMPT.includes("never a rewrite"));
  assert.ok(ADAPT_SYSTEM_PROMPT.includes("Change the MINIMUM"));
  assert.ok(ADAPT_SYSTEM_PROMPT.includes("Never invent new session templates"));
  assert.ok(ADAPT_SYSTEM_PROMPT.includes("The past already happened"));
  assert.ok(
    ADAPT_SYSTEM_PROMPT.includes(
      '"Swapped overhead pressing out for two weeks. Everything else stands."',
    ),
  );
  assert.ok(ADAPT_SYSTEM_PROMPT.includes("Call emit_patch exactly once."));
  assert.equal(PLAN_ADAPT_TOOL.name, "emit_patch");
  const schema = PLAN_ADAPT_TOOL.input_schema as { required?: string[] };
  assert.deepEqual(schema.required, ["summary"]);
});

// ── The ACTIVE PLANS prompt block ───────────────────────────────────

test("formatPlans renders week-of lines and an explicit none marker", () => {
  assert.equal(formatPlans([], NOW), "(none)");
  const line = formatPlans([basePlan()], NOW);
  // Created Aug 4, now Aug 18 — day 14, week 3 of 8.
  assert.equal(line, '- fitness: "get stronger" — week 3 of 8');
});
