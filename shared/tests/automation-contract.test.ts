/**
 * Pins the Automation wire contract before any Phase 6 behavior exists.
 *
 * Two rules here are load-bearing and easy to regress:
 *   - Run-state fields (lastRunAt/nextRunAt/lastResult) accept BOTH explicit
 *     null and an absent key — Firestore stores explicit nulls until the
 *     first run, while the generated Swift omits nil keys on encode.
 *   - Schedule variant fields are all required: the generated Swift union
 *     decodes payloads with a plain `decode`, so an absent key inside a
 *     variant throws at runtime. `eventFilter: {}` is the "match everything"
 *     spelling, never a missing key.
 */
import { strict as assert } from "node:assert";
import { test } from "node:test";

import { Automation, AutomationSchedule } from "../schemas/index.js";

const CANONICAL_DATE = "2026-08-19T11:00:00.000Z";

const morningBrief = {
  id: "a1",
  ownerId: "u1",
  type: "morning_brief",
  label: "Morning brief",
  enabled: true,
  schedule: { kind: "fixed", rrule: "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR", timeOfDay: "07:10" },
  timezone: "America/New_York",
  action: { kind: "morning_brief", params: {} },
  lastRunAt: null,
  nextRunAt: CANONICAL_DATE,
  lastResult: null,
  createdAt: CANONICAL_DATE,
} as const;

test("a freshly created automation parses, with never-run state as explicit nulls", () => {
  const parsed = Automation.safeParse(morningBrief);
  assert.ok(parsed.success, JSON.stringify(parsed.success ? {} : parsed.error.issues));
});

test("run-state fields also accept an absent key — the Swift encoder omits nil", () => {
  const { lastRunAt, nextRunAt, lastResult, ...swiftEncoded } = morningBrief;
  assert.ok(Automation.safeParse(swiftEncoded).success);
});

test("lastResult admits exactly delivered / suppressed / failed", () => {
  for (const lastResult of ["delivered", "suppressed", "failed"]) {
    assert.ok(Automation.safeParse({ ...morningBrief, lastResult }).success, lastResult);
  }
  assert.ok(!Automation.safeParse({ ...morningBrief, lastResult: "skipped" }).success);
});

test("only the six automation types exist", () => {
  const types = [
    "morning_brief",
    "evening_shutdown",
    "weekly_review",
    "meeting_prep",
    "plan_checkin",
    "custom",
  ];
  for (const type of types) {
    assert.ok(Automation.safeParse({ ...morningBrief, type }).success, type);
  }
  assert.ok(!Automation.safeParse({ ...morningBrief, type: "nightly_digest" }).success);
});

test("timeOfDay is zero-padded 24-hour wall clock", () => {
  const at = (timeOfDay: string) =>
    AutomationSchedule.safeParse({ kind: "fixed", rrule: "FREQ=DAILY", timeOfDay }).success;
  assert.ok(at("00:00"));
  assert.ok(at("07:10"));
  assert.ok(at("23:59"));
  assert.ok(!at("24:00"), "24:00 is not a wall-clock time");
  assert.ok(!at("7:10"), "hours must be zero-padded");
  assert.ok(!at("19:5"), "minutes must be zero-padded");
  assert.ok(!at("09:10 AM"));
});

test("relative_to_event requires every variant field — eventFilter {} means match all", () => {
  assert.ok(
    AutomationSchedule.safeParse({
      kind: "relative_to_event",
      minutesBefore: 30,
      eventFilter: {},
    }).success,
  );
  assert.ok(
    AutomationSchedule.safeParse({
      kind: "relative_to_event",
      minutesBefore: 30,
      eventFilter: { minAttendees: 2, keywords: ["standup"] },
    }).success,
  );
  assert.ok(
    !AutomationSchedule.safeParse({ kind: "relative_to_event", minutesBefore: 30 }).success,
    "an absent eventFilter would throw inside the generated Swift union decoder",
  );
  assert.ok(
    !AutomationSchedule.safeParse({ kind: "wake_time", minutesBefore: 30, eventFilter: {} })
      .success,
  );
});

test("minutesBefore is bounded to a day and never zero", () => {
  const minutes = (minutesBefore: number) =>
    AutomationSchedule.safeParse({ kind: "relative_to_event", minutesBefore, eventFilter: {} })
      .success;
  assert.ok(minutes(1));
  assert.ok(minutes(1440));
  assert.ok(!minutes(0));
  assert.ok(!minutes(1441));
  assert.ok(!minutes(30.5));
});

test("action params default to {} and carry arbitrary JSON for custom automations", () => {
  const { params: _dropped, ...action } = morningBrief.action;
  const parsed = Automation.safeParse({ ...morningBrief, action });
  assert.ok(parsed.success);
  if (parsed.success) {
    assert.deepEqual(parsed.data.action.params, {});
  }
  const custom = Automation.safeParse({
    ...morningBrief,
    type: "custom",
    label: "Text Rachel",
    action: {
      kind: "composite",
      params: { recipient: "Rachel", steps: ["check calendar", "draft text"], depth: 2 },
    },
  });
  assert.ok(custom.success);
});
