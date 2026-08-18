import { strict as assert } from "node:assert";
import { test } from "node:test";

import {
  GENERATION_SYSTEM_PROMPT,
  PLAN_GENERATION_TOOL,
  validateGeneratedPlan,
} from "../src/plans/generate.js";

const STEP = {
  id: "st1",
  type: "counted",
  title: "Goblet squat",
  cue: "Chest tall. Sit between your heels, drive up through the mid-foot.",
  target: { sets: 3, reps: 8, load: 20 },
  completion: "manual",
};

function payload(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    meta: { domain: "fitness", goal: "strength", horizonDays: 56 },
    sessions: [
      { id: "lower-a", title: "Lower A", estimatedMinutes: 45, steps: [STEP] },
      { id: "upper-a", title: "Upper A", estimatedMinutes: 45, steps: [{ ...STEP, id: "st2" }] },
    ],
    schedule: [
      { sessionId: "lower-a", dayOffset: 0 },
      { sessionId: "upper-a", dayOffset: 2, progression: { loadMultiplier: 1.05 } },
    ],
    ...overrides,
  };
}

// ── Structural validation ───────────────────────────────────────────

test("a template-style payload validates", () => {
  const result = validateGeneratedPlan(payload());
  assert.ok(result.ok);
});

test("schema failures come back as pathed, feedable errors", () => {
  const result = validateGeneratedPlan({ meta: { domain: "cooking" } });
  assert.ok(!result.ok);
  if (!result.ok) {
    assert.ok(result.errors.length > 0);
    assert.ok(result.errors.some((error) => error.startsWith("meta.domain")));
  }
});

test("referential integrity: unknown, unscheduled, and out-of-horizon are caught", () => {
  const unknown = validateGeneratedPlan(
    payload({ schedule: [{ sessionId: "ghost", dayOffset: 0 }] }),
  );
  assert.ok(!unknown.ok);
  if (!unknown.ok) {
    assert.ok(unknown.errors.some((e) => e.includes('unknown session "ghost"')));
    // Both real templates now unreferenced — flagged too.
    assert.ok(unknown.errors.some((e) => e.includes("never scheduled")));
  }

  const beyond = validateGeneratedPlan(
    payload({
      schedule: [
        { sessionId: "lower-a", dayOffset: 0 },
        { sessionId: "upper-a", dayOffset: 56 },
      ],
    }),
  );
  assert.ok(!beyond.ok);
  if (!beyond.ok) {
    assert.ok(beyond.errors.some((e) => e.includes("outside horizon")));
  }
});

test("duplicate ids and empty sessions are rejected", () => {
  const duplicated = validateGeneratedPlan(
    payload({
      sessions: [
        { id: "lower-a", title: "A", estimatedMinutes: 45, steps: [STEP] },
        { id: "lower-a", title: "B", estimatedMinutes: 45, steps: [{ ...STEP, id: "st2" }] },
      ],
      schedule: [{ sessionId: "lower-a", dayOffset: 0 }],
    }),
  );
  assert.ok(!duplicated.ok);
  if (!duplicated.ok) {
    assert.ok(duplicated.errors.some((e) => e.includes("duplicate session id")));
  }

  const empty = validateGeneratedPlan(
    payload({
      sessions: [{ id: "lower-a", title: "A", estimatedMinutes: 45, steps: [] }],
      schedule: [{ sessionId: "lower-a", dayOffset: 0 }],
    }),
  );
  assert.ok(!empty.ok);
});

test("session-expansion is structurally impossible past the caps", () => {
  const expanded = validateGeneratedPlan(
    payload({
      sessions: Array.from({ length: 32 }, (_, i) => ({
        id: `s${i}`,
        title: `Session ${i}`,
        estimatedMinutes: 45,
        steps: [{ ...STEP, id: `st${i}` }],
      })),
      schedule: Array.from({ length: 32 }, (_, i) => ({ sessionId: `s${i}`, dayOffset: i })),
    }),
  );
  assert.ok(!expanded.ok, "32 expanded sessions must fail the max-8 template cap");
});

// ── The tool and the prompt ─────────────────────────────────────────

test("the tool schema mirrors the shared enums and requireds", () => {
  const schema = PLAN_GENERATION_TOOL.input_schema as {
    required?: string[];
    properties?: Record<string, { items?: { properties?: Record<string, { enum?: string[] }> } }>;
  };
  assert.deepEqual(schema.required, ["meta", "sessions", "schedule"]);
  const stepProps =
    schema.properties?.sessions?.items?.properties?.steps as unknown as {
      items?: { properties?: Record<string, { enum?: string[] }> };
    };
  assert.deepEqual(stepProps.items?.properties?.type?.enum, [
    "timed",
    "counted",
    "checklist",
    "prompt",
  ]);
  assert.deepEqual(stepProps.items?.properties?.completion?.enum, ["auto", "manual", "voice"]);
});

test("the generation prompt carries the load-bearing rules", () => {
  assert.ok(GENERATION_SYSTEM_PROMPT.includes("COMPLETE and SELF-CONTAINED"));
  assert.ok(GENERATION_SYSTEM_PROMPT.includes("THE TEMPLATE RULE"));
  assert.ok(GENERATION_SYSTEM_PROMPT.includes("4-6 DISTINCT session templates"));
  assert.ok(GENERATION_SYSTEM_PROMPT.includes("NEVER write one session per occurrence"));
  assert.ok(GENERATION_SYSTEM_PROMPT.includes("Never promise a body outcome by a date"));
  assert.ok(GENERATION_SYSTEM_PROMPT.includes("Call emit_plan exactly once"));
});
