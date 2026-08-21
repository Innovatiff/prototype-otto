import { strict as assert } from "node:assert";
import { test } from "node:test";

import {
  buildWalkthrough,
  validateWalkthrough,
  WALKTHROUGH_SYSTEM_PROMPT,
  WALKTHROUGH_TOOL,
} from "../src/walkthrough/generate.js";

function step(id: string, partial: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    id,
    type: "prompt",
    title: `Step ${id}`,
    cue: "Do the thing carefully, and tell me when you're done.",
    completion: "voice",
    ...partial,
  };
}

function goodPayload(): Record<string, unknown> {
  return {
    domain: "cooking",
    title: "Chicken Alfredo for Two",
    estimatedMinutes: 45,
    steps: [
      step("gather", { type: "checklist", completion: "manual" }),
      step("boil", {
        type: "timed",
        target: { durationSec: 600 },
        completion: "auto",
        cue: "Salt the water and bring it to a rolling boil. Ten minutes.",
      }),
      step("plate"),
    ],
  };
}

// ── Validation ──────────────────────────────────────────────────────

test("a complete payload validates and builds a shared Walkthrough", () => {
  const result = validateWalkthrough(goodPayload());
  assert.equal(result.ok, "walkthrough");
  if (result.ok !== "walkthrough") return;
  const walkthrough = buildWalkthrough(result.payload, "wk-1");
  assert.equal(walkthrough.domain, "cooking");
  assert.equal(walkthrough.session.id, "wk-1");
  assert.equal(walkthrough.session.title, "Chicken Alfredo for Two");
  assert.equal(walkthrough.session.steps.length, 3);
});

test("a refusal short-circuits: reason out, no field requirements", () => {
  const result = validateWalkthrough({
    refused: "Brake hydraulics aren't a first-timer job — a shop should bleed them.",
  });
  assert.equal(result.ok, "refused");
  if (result.ok !== "refused") return;
  assert.match(result.reason, /shop/);
});

test("missing fields, duplicate ids, thin cues, and clockless timers are named", () => {
  const missing = validateWalkthrough({ domain: "cooking" });
  assert.equal(missing.ok, false);
  if (missing.ok !== false) return;
  assert.ok(missing.errors.some((error) => error.includes("title")));
  assert.ok(missing.errors.some((error) => error.includes("steps")));

  const payload = goodPayload();
  payload["steps"] = [
    step("a"),
    step("a"),
    step("thin", { cue: "Go." }),
    step("timer", { type: "timed", completion: "auto" }),
  ];
  const bad = validateWalkthrough(payload);
  assert.equal(bad.ok, false);
  if (bad.ok !== false) return;
  assert.ok(bad.errors.some((error) => error.includes('duplicate step id "a"')));
  assert.ok(bad.errors.some((error) => error.includes("cue too thin")));
  assert.ok(bad.errors.some((error) => error.includes("durationSec")));
});

test("step count is bounded: under 3 or over 30 fails schema", () => {
  const two = goodPayload();
  two["steps"] = [step("a"), step("b")];
  assert.equal(validateWalkthrough(two).ok, false);

  const many = goodPayload();
  many["steps"] = Array.from({ length: 31 }, (_, index) => step(`s${index}`));
  assert.equal(validateWalkthrough(many).ok, false);
});

// ── The contract the prompt and tool carry ──────────────────────────

test("the prompt carries the load-bearing rules", () => {
  assert.ok(WALKTHROUGH_SYSTEM_PROMPT.includes("COMPLETE and SELF-CONTAINED"));
  assert.ok(WALKTHROUGH_SYSTEM_PROMPT.includes("FRONT-LOAD one checklist step"));
  assert.ok(WALKTHROUGH_SYSTEM_PROMPT.includes("OPEN with the safety step"));
  assert.ok(WALKTHROUGH_SYSTEM_PROMPT.includes("ONLY refused"));
  assert.ok(WALKTHROUGH_SYSTEM_PROMPT.includes("honest first-timer wall-clock"));
});

test("the tool allows refusal-only or full-material calls", () => {
  assert.equal(WALKTHROUGH_TOOL.name, "emit_walkthrough");
  assert.deepEqual(WALKTHROUGH_TOOL.input_schema.required, []);
});
