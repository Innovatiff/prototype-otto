/**
 * The management screen's server half, pure: what one edit writes, and
 * the list order the screen renders.
 */
import { strict as assert } from "node:assert";
import { test } from "node:test";

import type { Automation } from "@otto/shared";

import { applyAutomationUpdate, sortForManagement } from "../src/automations/custom.js";

const NOW = new Date("2026-08-19T11:02:00.000Z"); // Wednesday, 07:02 New York

function automation(id: string, overrides: Partial<Automation> = {}): Automation {
  return {
    id,
    ownerId: "u1",
    type: "morning_brief",
    label: "Morning brief",
    enabled: true,
    schedule: { kind: "fixed", rrule: "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR", timeOfDay: "07:25" },
    timezone: "America/New_York",
    action: { kind: "morning_brief", params: {} },
    lastRunAt: null,
    nextRunAt: "2026-08-19T11:25:00.000Z",
    lastResult: null,
    createdAt: "2026-08-01T00:00:00.000Z",
    ...overrides,
  };
}

test("retiming a fixed built-in moves the schedule and recomputes the next fire", () => {
  const outcome = applyAutomationUpdate(automation("a1"), { timeOfDay: "06:45" }, NOW);
  assert.ok(outcome.ok);
  if (outcome.ok) {
    assert.deepEqual(outcome.fields.schedule, {
      kind: "fixed",
      rrule: "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR",
      timeOfDay: "06:45",
    });
    // 06:45 today already passed at 07:02 — tomorrow (Thursday) 06:45 EDT.
    assert.equal(outcome.fields.nextRunAt, "2026-08-20T10:45:00.000Z");
    assert.equal(outcome.fields.enabled, undefined, "untouched fields stay untouched");
  }
});

test("toggling recomputes; disabling parks; retime-while-disabled stays parked", () => {
  const off = applyAutomationUpdate(automation("a1"), { enabled: false }, NOW);
  assert.ok(off.ok && off.fields.enabled === false && off.fields.nextRunAt === null);

  const on = applyAutomationUpdate(automation("a1", { enabled: false, nextRunAt: null }), { enabled: true }, NOW);
  assert.ok(on.ok);
  if (on.ok) {
    assert.equal(on.fields.nextRunAt, "2026-08-19T11:25:00.000Z", "today's 07:25 is still ahead");
  }

  const retimeOff = applyAutomationUpdate(
    automation("a1", { enabled: false, nextRunAt: null }),
    { timeOfDay: "08:00" },
    NOW,
  );
  assert.ok(retimeOff.ok && retimeOff.fields.nextRunAt === null);
});

test("event-relative automations reject a time edit and re-arm via sync on enable", () => {
  const prep = automation("p1", {
    type: "meeting_prep",
    schedule: { kind: "relative_to_event", minutesBefore: 30, eventFilter: { minAttendees: 2 } },
    nextRunAt: null,
  });
  const retime = applyAutomationUpdate(prep, { timeOfDay: "08:00" }, NOW);
  assert.ok(!retime.ok);
  const enable = applyAutomationUpdate(prep, { enabled: true }, NOW);
  assert.ok(enable.ok && enable.fields.nextRunAt === null);
});

test("an empty update is rejected", () => {
  assert.ok(!applyAutomationUpdate(automation("a1"), {}, NOW).ok);
});

test("the list renders built-ins in canonical order, then customs by label", () => {
  const sorted = sortForManagement([
    automation("c2", { type: "custom", label: "Text Rachel" }),
    automation("w", { type: "weekly_review", label: "Weekly review" }),
    automation("c1", { type: "custom", label: "Friday numbers" }),
    automation("b", { type: "morning_brief" }),
    automation("p", { type: "meeting_prep", label: "Meeting prep" }),
    automation("e", { type: "evening_shutdown", label: "Evening shutdown" }),
  ]);
  assert.deepEqual(
    sorted.map((entry) => entry.id),
    ["b", "e", "p", "w", "c1", "c2"],
  );
});
