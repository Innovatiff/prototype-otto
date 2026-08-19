/**
 * Custom automations by voice — the deterministic half: the humanized
 * schedule (the one-line confirmation's content), creation validation
 * against the strict subset, fuzzy label matching for enable/disable/
 * delete, toggle field math, and the NOTHING_TO_SAY escape.
 */
import { strict as assert } from "node:assert";
import { test } from "node:test";

import type { Automation } from "@otto/shared";

import {
  buildCustomAutomation,
  describeSchedule,
  enabledUpdateFields,
  formatTimeOfDay,
  isNothingToSay,
  matchAutomation,
  MAX_CUSTOM_AUTOMATIONS,
} from "../src/automations/custom.js";

const NOW = new Date("2026-08-19T11:02:00.000Z"); // Wednesday, 07:02 New York
const TZ = "America/New_York";

function input(overrides: Partial<Parameters<typeof buildCustomAutomation>[2]> = {}) {
  return {
    label: "Text Rachel gym check",
    rrule: "FREQ=WEEKLY;BYDAY=FR",
    timeOfDay: "15:30",
    instruction: "Check my calendar, then draft a text to Rachel asking if she's coming to the gym.",
    ...overrides,
  };
}

// ── The confirmation line's content ─────────────────────────────────

test("describeSchedule speaks the way Otto confirms", () => {
  assert.equal(
    describeSchedule({ kind: "fixed", rrule: "FREQ=WEEKLY;BYDAY=FR", timeOfDay: "15:30" }),
    "Every Friday at 3:30 PM",
  );
  assert.equal(
    describeSchedule({ kind: "fixed", rrule: "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR", timeOfDay: "07:25" }),
    "Weekdays at 7:25 AM",
  );
  assert.equal(
    describeSchedule({ kind: "fixed", rrule: "FREQ=WEEKLY;BYDAY=SA,SU", timeOfDay: "09:00" }),
    "Weekends at 9:00 AM",
  );
  assert.equal(
    describeSchedule({ kind: "fixed", rrule: "FREQ=DAILY", timeOfDay: "21:00" }),
    "Every day at 9:00 PM",
  );
  assert.equal(
    describeSchedule({ kind: "fixed", rrule: "FREQ=WEEKLY;BYDAY=MO,WE,FR", timeOfDay: "12:00" }),
    "Every Monday, Wednesday and Friday at 12:00 PM",
  );
  assert.equal(
    describeSchedule({
      kind: "relative_to_event",
      minutesBefore: 30,
      eventFilter: { minAttendees: 2 },
    }),
    "30 minutes before meetings",
  );
});

test("formatTimeOfDay handles the clock edges", () => {
  assert.equal(formatTimeOfDay("00:05"), "12:05 AM");
  assert.equal(formatTimeOfDay("12:00"), "12:00 PM");
  assert.equal(formatTimeOfDay("23:59"), "11:59 PM");
});

// ── Creation ────────────────────────────────────────────────────────

test("ACCEPTANCE #3 shape: 'every Friday afternoon' builds an armed Friday 15:30 automation", () => {
  const built = buildCustomAutomation("u1", TZ, input(), 0, NOW, () => "auto-1");
  assert.ok(built.ok);
  if (built.ok) {
    assert.equal(built.automation.type, "custom");
    assert.equal(built.automation.enabled, true);
    assert.equal(built.automation.action.kind, "custom");
    assert.match(String(built.automation.action.params["instruction"]), /Rachel/);
    // Wednesday 07:02 NY -> this Friday 15:30 NY = 19:30Z Aug 21.
    assert.equal(built.automation.nextRunAt, "2026-08-21T19:30:00.000Z");
  }
});

test("creation rejects what the scheduler could never fire", () => {
  const monthly = buildCustomAutomation("u1", TZ, input({ rrule: "FREQ=MONTHLY" }), 0, NOW, () => "x");
  assert.ok(!monthly.ok);
  const badTz = buildCustomAutomation("u1", "Nowhere/Void", input(), 0, NOW, () => "x");
  assert.ok(!badTz.ok);
  const capped = buildCustomAutomation("u1", TZ, input(), MAX_CUSTOM_AUTOMATIONS, NOW, () => "x");
  assert.ok(!capped.ok && /limit/i.test(capped.ok === false ? capped.error : ""));
});

// ── Matching spoken labels ──────────────────────────────────────────

function automation(id: string, overrides: Partial<Automation> = {}): Automation {
  return {
    id,
    ownerId: "u1",
    type: "custom",
    label: "Text Rachel gym check",
    enabled: true,
    schedule: { kind: "fixed", rrule: "FREQ=WEEKLY;BYDAY=FR", timeOfDay: "15:30" },
    timezone: TZ,
    action: { kind: "custom", params: {} },
    lastRunAt: null,
    nextRunAt: null,
    lastResult: null,
    createdAt: "2026-08-01T00:00:00.000Z",
    ...overrides,
  };
}

test("matchAutomation: exact, containment, then type words — never a wild guess", () => {
  const rachel = automation("a1");
  const brief = automation("a2", { type: "morning_brief", label: "Morning brief" });
  const prep = automation("a3", { type: "meeting_prep", label: "Meeting prep" });
  const all = [rachel, brief, prep];
  assert.equal(matchAutomation(all, "text rachel gym check")?.id, "a1");
  assert.equal(matchAutomation(all, "rachel gym")?.id, "a1", "substring of the label");
  assert.equal(matchAutomation(all, "Text Rachel gym check please")?.id, "a1", "label inside the query");
  assert.equal(matchAutomation(all, "the rachel one"), null, "no containment either way");
  assert.equal(matchAutomation(all, "morning brief")?.id, "a2");
  assert.equal(matchAutomation(all, "the meeting prep")?.id, "a3");
  assert.equal(matchAutomation(all, "quarterly taxes"), null);
  assert.equal(matchAutomation(all, ""), null);
});

// ── Toggling ────────────────────────────────────────────────────────

test("disable parks; enable re-arms fixed now and leaves relative to the next sync", () => {
  const fixed = automation("a1");
  assert.deepEqual(enabledUpdateFields(fixed, false, NOW), { enabled: false, nextRunAt: null });
  const rearmed = enabledUpdateFields(fixed, true, NOW);
  assert.equal(rearmed.enabled, true);
  assert.equal(rearmed.nextRunAt, "2026-08-21T19:30:00.000Z");
  const relative = automation("a2", {
    type: "meeting_prep",
    schedule: { kind: "relative_to_event", minutesBefore: 30, eventFilter: { minAttendees: 2 } },
  });
  assert.deepEqual(enabledUpdateFields(relative, true, NOW), { enabled: true, nextRunAt: null });
});

// ── The silence escape ──────────────────────────────────────────────

test("isNothingToSay tolerates model punctuation, nothing else", () => {
  assert.ok(isNothingToSay("NOTHING_TO_SAY"));
  assert.ok(isNothingToSay("nothing_to_say."));
  assert.ok(isNothingToSay(' "NOTHING_TO_SAY" '));
  assert.ok(!isNothingToSay("There is nothing to say about your calendar."));
  assert.ok(!isNothingToSay("NOTHING_TO_SAY, except one thing"));
});
