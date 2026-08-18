import { strict as assert } from "node:assert";
import { test } from "node:test";

import { GeneratedPlanPayload } from "../src/plans/generate.js";
import type { PlanConstraints } from "../src/plans/interview.js";
import {
  checkPlanSafety,
  constraintsRiskText,
  detectRiskSignals,
  PERFORMANCE_FRAMING,
  SAFETY_GUIDANCE,
} from "../src/plans/safety.js";

const CONSTRAINTS: PlanConstraints = {
  domain: "fitness",
  goal: "get stronger",
  minutesPerSession: 45,
  equipment: ["dumbbells", "adjustable bench"],
};

function step(id: string, cue: string) {
  return {
    id,
    type: "counted",
    title: "Movement",
    cue,
    target: { sets: 3, reps: 8 },
    completion: "manual",
  };
}

const DUMBBELL_CUE = "Dumbbells at your sides. Brace, sit between your heels.";

/** An 8-week, 2-template plan with a compliant week-5 deload. */
function payload(overrides: Record<string, unknown> = {}): GeneratedPlanPayload {
  const schedule: Record<string, unknown>[] = [];
  for (let week = 0; week < 8; week += 1) {
    const progression =
      week === 4
        ? { loadMultiplier: 0.6, note: "deload week — keep it light" }
        : { loadMultiplier: Math.min(1.15, 1 + week * 0.025) };
    schedule.push(
      { sessionId: "lower-a", dayOffset: week * 7, progression },
      { sessionId: "upper-a", dayOffset: week * 7 + 2, progression },
    );
  }
  return GeneratedPlanPayload.parse({
    meta: { domain: "fitness", goal: "strength", horizonDays: 56 },
    sessions: [
      { id: "lower-a", title: "Lower A", estimatedMinutes: 45, steps: [step("s1", DUMBBELL_CUE)] },
      { id: "upper-a", title: "Upper A", estimatedMinutes: 45, steps: [step("s2", DUMBBELL_CUE)] },
    ],
    schedule,
    ...overrides,
  });
}

function rules(violations: { rule: string }[]): string[] {
  return violations.map((v) => v.rule);
}

function kinds(signals: { kind: string }[]): string[] {
  return signals.map((s) => s.kind);
}

// ── Deterministic checks ────────────────────────────────────────────

test("a compliant plan passes every check", () => {
  assert.deepEqual(checkPlanSafety(payload(), CONSTRAINTS), []);
});

test("a plan longer than 5 weeks without a deload week is rejected", () => {
  const noDeload = payload({
    schedule: Array.from({ length: 8 }, (_, week) => ({
      sessionId: week % 2 === 0 ? "lower-a" : "upper-a",
      dayOffset: week * 7,
      progression: { loadMultiplier: 1.0 },
    })).concat([
      { sessionId: "lower-a", dayOffset: 1, progression: { loadMultiplier: 1.0 } },
      { sessionId: "upper-a", dayOffset: 3, progression: { loadMultiplier: 1.0 } },
    ]),
  });
  assert.ok(rules(checkPlanSafety(noDeload, CONSTRAINTS)).includes("missing-deload"));

  // A mixed week — one light entry next to a full-load one — is not a deload.
  const halfDeload = payload({
    schedule: Array.from({ length: 8 }, (_, week) => [
      {
        sessionId: "lower-a",
        dayOffset: week * 7,
        progression: { loadMultiplier: week === 4 ? 0.6 : 1.0 },
      },
      { sessionId: "upper-a", dayOffset: week * 7 + 2, progression: { loadMultiplier: 1.0 } },
    ]).flat(),
  });
  assert.ok(rules(checkPlanSafety(halfDeload, CONSTRAINTS)).includes("missing-deload"));
});

test("a 4-week plan needs no deload", () => {
  const short = payload({
    meta: { domain: "fitness", goal: "strength", horizonDays: 28 },
    schedule: [
      { sessionId: "lower-a", dayOffset: 0 },
      { sessionId: "upper-a", dayOffset: 2 },
    ],
  });
  assert.deepEqual(checkPlanSafety(short, CONSTRAINTS), []);
});

test("week-over-week load jumps beyond 10% are rejected", () => {
  const jump = payload({
    schedule: [
      { sessionId: "lower-a", dayOffset: 0 },
      { sessionId: "lower-a", dayOffset: 7, progression: { loadMultiplier: 1.25 } },
      { sessionId: "upper-a", dayOffset: 2 },
    ],
    meta: { domain: "fitness", goal: "strength", horizonDays: 14 },
  });
  const violations = checkPlanSafety(jump, CONSTRAINTS);
  assert.ok(rules(violations).includes("progression-too-fast"));
  assert.ok(violations.some((v) => v.detail.includes('"lower-a"')));
});

test("post-deload return to a prior peak is not a progression violation", () => {
  // 1.0 → 1.05 → 1.10 → deload 0.6 → back to 1.10: the 0.6→1.10 step is an
  // 83% jump but returns to the established peak. Must pass.
  const recovery = payload({
    schedule: [
      { sessionId: "lower-a", dayOffset: 0 },
      { sessionId: "lower-a", dayOffset: 7, progression: { loadMultiplier: 1.05 } },
      { sessionId: "lower-a", dayOffset: 14, progression: { loadMultiplier: 1.1 } },
      { sessionId: "lower-a", dayOffset: 21, progression: { loadMultiplier: 0.6, note: "deload" } },
      { sessionId: "lower-a", dayOffset: 28, progression: { loadMultiplier: 1.1 } },
      { sessionId: "upper-a", dayOffset: 2, progression: { loadMultiplier: 0.6 } },
      { sessionId: "upper-a", dayOffset: 23, progression: { loadMultiplier: 0.6 } },
    ],
    meta: { domain: "fitness", goal: "strength", horizonDays: 35 },
  });
  assert.deepEqual(rules(checkPlanSafety(recovery, CONSTRAINTS)), []);
});

test("the 10% allowance compounds across skipped weeks", () => {
  const gap = payload({
    schedule: [
      { sessionId: "lower-a", dayOffset: 0 },
      { sessionId: "lower-a", dayOffset: 14, progression: { loadMultiplier: 1.15 } },
      { sessionId: "upper-a", dayOffset: 2 },
    ],
    meta: { domain: "fitness", goal: "strength", horizonDays: 21 },
  });
  // Two weeks elapsed: allowed 1.21, so 1.15 passes.
  assert.deepEqual(rules(checkPlanSafety(gap, CONSTRAINTS)), []);
});

test("sessions exceeding stated time by more than 15% are rejected", () => {
  const bloated = payload({
    sessions: [
      { id: "lower-a", title: "Lower A", estimatedMinutes: 60, steps: [step("s1", DUMBBELL_CUE)] },
      { id: "upper-a", title: "Upper A", estimatedMinutes: 51, steps: [step("s2", DUMBBELL_CUE)] },
    ],
  });
  const violations = checkPlanSafety(bloated, CONSTRAINTS);
  // 45 min stated → 51.75 cap: 60 fails, 51 passes.
  assert.equal(rules(violations).filter((r) => r === "session-too-long").length, 1);
  assert.ok(violations.some((v) => v.detail.includes('"lower-a"')));

  const unstated = { ...CONSTRAINTS, minutesPerSession: undefined };
  assert.deepEqual(checkPlanSafety(bloated, unstated), []);
});

test("equipment the user does not have is rejected wherever it is mentioned", () => {
  const barbell = payload({
    sessions: [
      {
        id: "lower-a",
        title: "Lower A",
        estimatedMinutes: 45,
        steps: [step("s1", "Barbell on your back. Brace before you unrack.")],
      },
      { id: "upper-a", title: "Upper A", estimatedMinutes: 45, steps: [step("s2", DUMBBELL_CUE)] },
    ],
  });
  const violations = checkPlanSafety(barbell, CONSTRAINTS);
  assert.ok(rules(violations).includes("equipment-violation"));
  assert.ok(violations.some((v) => v.detail.includes("barbell") && v.detail.includes('"lower-a"')));

  // The stated bench is fine; a full gym clears everything; unstated skips.
  assert.deepEqual(
    checkPlanSafety(barbell, { ...CONSTRAINTS, equipment: ["full gym"] }),
    [],
  );
  assert.deepEqual(checkPlanSafety(barbell, { ...CONSTRAINTS, equipment: undefined }), []);

  const bench = payload({
    sessions: [
      {
        id: "lower-a",
        title: "Lower A",
        estimatedMinutes: 45,
        steps: [step("s1", "Dumbbell bench press. Feet planted, slight arch.")],
      },
      { id: "upper-a", title: "Upper A", estimatedMinutes: 45, steps: [step("s2", DUMBBELL_CUE)] },
    ],
  });
  assert.deepEqual(checkPlanSafety(bench, CONSTRAINTS), []);

  // "none" means bodyweight only — any equipment mention fails.
  const bodyweight = { ...CONSTRAINTS, equipment: ["none"] };
  assert.ok(rules(checkPlanSafety(payload(), bodyweight)).includes("equipment-violation"));
});

test("checks are gated on the requested domain, and mismatches are flagged", () => {
  const learning: PlanConstraints = { domain: "learning", goal: "learn spanish" };
  const learningPayload = payload({
    meta: { domain: "learning", goal: "learn spanish", horizonDays: 56 },
    schedule: [
      { sessionId: "lower-a", dayOffset: 0 },
      { sessionId: "upper-a", dayOffset: 2 },
    ],
  });
  // No deload, no equipment scan — fitness rules don't apply to learning.
  assert.deepEqual(checkPlanSafety(learningPayload, learning), []);

  // An emission whose domain disagrees with the interview can't dodge checks.
  const mislabeled = payload({
    meta: { domain: "learning", goal: "strength", horizonDays: 56 },
  });
  assert.ok(rules(checkPlanSafety(mislabeled, CONSTRAINTS)).includes("domain-mismatch"));
});

// ── Risk signals ────────────────────────────────────────────────────

test("rapid-loss framing is detected", () => {
  assert.deepEqual(kinds(detectRiskSignals("I want to lose 8kg in 3 weeks")), ["rapid-loss"]);
  assert.ok(kinds(detectRiskSignals("basically a crash diet plus training")).includes("rapid-loss"));
  assert.deepEqual(detectRiskSignals("I want to lose some weight over the next year"), []);
});

test("extreme deficits are detected; workout calorie burn is not", () => {
  assert.deepEqual(kinds(detectRiskSignals("I'll be eating 800 calories a day")), [
    "extreme-deficit",
  ]);
  assert.deepEqual(kinds(detectRiskSignals("on 900 kcal until the weigh-in... just kidding, 900 calories daily")), [
    "extreme-deficit",
  ]);
  assert.deepEqual(detectRiskSignals("workouts that burn 500 calories a day"), []);
  assert.deepEqual(detectRiskSignals("I eat around 2200 calories"), []);
});

test("restriction language is detected", () => {
  assert.deepEqual(kinds(detectRiskSignals("I've been skipping meals to speed things up")), [
    "restriction",
  ]);
  assert.ok(kinds(detectRiskSignals("thinking OMAD might help")).includes("restriction"));
});

test("a body target tied to an event is detected", () => {
  assert.deepEqual(kinds(detectRiskSignals("visible abs for my wedding in June")), [
    "event-body-target",
  ]);
  // An event without a body goal, or a body word without an event: no signal.
  assert.deepEqual(detectRiskSignals("I want to be fit for my wedding dance"), []);
  assert.deepEqual(detectRiskSignals("build lean muscle over the year"), []);
});

test("a clean strength goal carries no signals", () => {
  assert.deepEqual(
    detectRiskSignals("get stronger and add 20kg to my squat over six months"),
    [],
  );
});

test("constraintsRiskText gathers the free-text intent fields", () => {
  const text = constraintsRiskText({
    domain: "fitness",
    goal: "lose weight",
    notes: "wedding in August",
    motivation: "look great in photos",
  });
  assert.ok(text.includes("lose weight"));
  assert.ok(text.includes("wedding in August"));
  assert.ok(text.includes("look great in photos"));
});

// ── Prompt blocks ───────────────────────────────────────────────────

test("the refuse-and-reframe guidance carries the reference tone verbatim", () => {
  const flat = SAFETY_GUIDANCE.replace(/\s+/g, " ");
  assert.ok(
    flat.includes(
      "Eight weeks of solid training will make a real, visible difference in " +
        "how you look and how you carry yourself. Visible abs depend a lot on " +
        "where you're starting from, and I'd rather set you up to win than " +
        "promise you something I can't control.",
    ),
  );
  assert.ok(flat.includes("NEVER promise a body outcome by a date"));
});

test("performance framing bans appearance goals and calorie targets", () => {
  assert.ok(PERFORMANCE_FRAMING.includes("NO appearance goals"));
  assert.ok(PERFORMANCE_FRAMING.includes("NO calorie targets"));
  assert.ok(PERFORMANCE_FRAMING.includes("strength, capacity, and consistency"));
});
