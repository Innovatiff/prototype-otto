import { strict as assert } from "node:assert";
import { test } from "node:test";

import { domainGuidance } from "../src/plans/domains/index.js";
import { FITNESS_GUIDANCE } from "../src/plans/domains/fitness.js";
import { LEARNING_GUIDANCE } from "../src/plans/domains/learning.js";
import { PRODUCTIVITY_GUIDANCE } from "../src/plans/domains/productivity.js";

// These pins are deliberate: the guidance blocks are the quality surface of
// plan generation, and these are their load-bearing rules. If an edit trips
// one, the rule was removed or reworded — make sure that was intentional.

test("the registry returns the matching block for every domain", () => {
  assert.equal(domainGuidance("fitness"), FITNESS_GUIDANCE);
  assert.equal(domainGuidance("productivity"), PRODUCTIVITY_GUIDANCE);
  assert.equal(domainGuidance("learning"), LEARNING_GUIDANCE);
  for (const block of [FITNESS_GUIDANCE, PRODUCTIVITY_GUIDANCE, LEARNING_GUIDANCE]) {
    assert.ok(block.startsWith("DOMAIN GUIDANCE — "));
  }
});

test("fitness guidance carries the hard programming rules", () => {
  // Progression is data on the schedule, never new sessions — and bounded.
  assert.ok(FITNESS_GUIDANCE.includes("schedule[].progression, NEVER in new"));
  assert.ok(FITNESS_GUIDANCE.includes("2.5-5% maximum"));
  // Deload is mandatory and concrete enough for the safety checks to expect.
  assert.ok(FITNESS_GUIDANCE.includes("DELOAD WEEK every 4-6 weeks, mandatory"));
  assert.ok(FITNESS_GUIDANCE.includes("An 8-week plan deloads in week 5."));
  // Equipment and time are constraints, not suggestions.
  assert.ok(FITNESS_GUIDANCE.includes("Equipment is absolute."));
  assert.ok(FITNESS_GUIDANCE.includes("INCLUDING rest"));
  // Injuries shape movement selection, not disclaimers.
  assert.ok(FITNESS_GUIDANCE.includes("by movement selection, not by a\n  warning note"));
  // Session shape and spacing.
  assert.ok(FITNESS_GUIDANCE.includes("Compound movements FIRST"));
  assert.ok(FITNESS_GUIDANCE.includes("never two heavy lower days back to back"));
  // Cues are finished spoken lines with real form content.
  assert.ok(FITNESS_GUIDANCE.includes("form reminder"));
  assert.ok(FITNESS_GUIDANCE.includes("Leave two clean reps in the tank."));
});

test("productivity guidance carries the day-structure rules", () => {
  assert.ok(PRODUCTIVITY_GUIDANCE.includes("FULL DAYS, wake to wind-down, all seven days"));
  assert.ok(PRODUCTIVITY_GUIDANCE.includes("STATED peak hours"));
  assert.ok(
    PRODUCTIVITY_GUIDANCE.includes("Never schedule email,\n  meetings, or admin inside a peak window"),
  );
  assert.ok(PRODUCTIVITY_GUIDANCE.includes("DEFINED WINDOWS"));
  // Slack is a design requirement, not a nicety.
  assert.ok(PRODUCTIVITY_GUIDANCE.includes("A schedule with no slack fails\n  by Tuesday"));
  assert.ok(PRODUCTIVITY_GUIDANCE.includes("SHUTDOWN block"));
  assert.ok(PRODUCTIVITY_GUIDANCE.includes("reproduce them EXACTLY"));
  // Templates are archetypes, keeping the template rule workable for days.
  assert.ok(PRODUCTIVITY_GUIDANCE.includes("DAY ARCHETYPES"));
});

test("learning guidance carries the retrieval-practice rules", () => {
  assert.ok(LEARNING_GUIDANCE.includes("SPACED REPETITION"));
  assert.ok(LEARNING_GUIDANCE.includes("1 day, 3 days, 7 days, 16 days"));
  assert.ok(LEARNING_GUIDANCE.includes("INTERLEAVED IN EVERY SESSION"));
  assert.ok(LEARNING_GUIDANCE.includes("RECALL, not recognition"));
  assert.ok(LEARNING_GUIDANCE.includes("front-load the backlog"));
  // Time honesty, same spirit as fitness's estimatedMinutes rule.
  assert.ok(LEARNING_GUIDANCE.includes("A 30-minute plan with\n  50-minute sessions is a broken plan."));
  // The one allowed non-interleaved session is the weekly checkpoint.
  assert.ok(LEARNING_GUIDANCE.includes("weekly checkpoint is\n  the one exception"));
});
