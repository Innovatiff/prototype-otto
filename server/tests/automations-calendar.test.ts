/**
 * The calendar-view boundary and the sync's rearm plan: window clamping
 * with normalization, staleness, event-filter matching, the strictly-after
 * semantics of event-derived fires, and what a sync may — and may NOT —
 * touch on the owner's automations.
 */
import { strict as assert } from "node:assert";
import { test } from "node:test";

import type { Automation, CalendarSyncEvent } from "@otto/shared";

import { clampToWindow, isViewStale } from "../src/automations/calendarView.js";
import { rearmUpdates } from "../src/automations/rearm.js";
import { matchesEventFilter, nextEventRun } from "../src/automations/schedule.js";

const NOW = new Date("2026-08-19T12:00:00.000Z");

function event(id: string, overrides: Partial<CalendarSyncEvent> = {}): CalendarSyncEvent {
  return {
    id,
    title: "Henderson review",
    startsAt: "2026-08-19T14:00:00.000Z",
    endsAt: "2026-08-19T15:00:00.000Z",
    attendeeCount: 3,
    ...overrides,
  };
}

// ── clampToWindow ───────────────────────────────────────────────────

test("the window keeps only events still ahead and inside 48 hours, sorted, capped", () => {
  const kept = clampToWindow(
    [
      event("late", { startsAt: "2026-08-19T16:00:00.000Z", endsAt: "2026-08-19T17:00:00.000Z" }),
      event("over", { startsAt: "2026-08-19T09:00:00.000Z", endsAt: "2026-08-19T10:00:00.000Z" }),
      event("early", { startsAt: "2026-08-19T13:00:00.000Z", endsAt: "2026-08-19T13:30:00.000Z" }),
      event("beyond", { startsAt: "2026-08-22T12:00:01.000Z", endsAt: "2026-08-22T13:00:00.000Z" }),
      event("running", { startsAt: "2026-08-19T11:30:00.000Z", endsAt: "2026-08-19T12:30:00.000Z" }),
    ],
    NOW,
  );
  // "over" ended before now, "beyond" starts past the 48h horizon; a
  // meeting currently RUNNING stays (its end is ahead).
  assert.deepEqual(kept.map((entry) => entry.id), ["running", "early", "late"]);
});

test("offset-form timestamps are normalized to canonical UTC at the boundary", () => {
  const kept = clampToWindow(
    [event("offset", { startsAt: "2026-08-19T10:00:00-04:00", endsAt: "2026-08-19T11:00:00-04:00" })],
    NOW,
  );
  assert.equal(kept[0]?.startsAt, "2026-08-19T14:00:00.000Z");
  assert.equal(kept[0]?.endsAt, "2026-08-19T15:00:00.000Z");
});

test("the cap holds", () => {
  const many = Array.from({ length: 130 }, (_, i) =>
    event(`e${i}`, {
      startsAt: new Date(NOW.getTime() + (i + 1) * 60_000).toISOString(),
      endsAt: new Date(NOW.getTime() + (i + 2) * 60_000).toISOString(),
    }),
  );
  assert.equal(clampToWindow(many, NOW).length, 100);
});

// ── staleness ───────────────────────────────────────────────────────

test("a view is stale after 24 hours, and garbage is always stale", () => {
  assert.equal(isViewStale("2026-08-19T11:00:00.000Z", NOW), false);
  assert.equal(isViewStale("2026-08-18T12:00:00.001Z", NOW), false);
  assert.equal(isViewStale("2026-08-18T11:59:59.000Z", NOW), true);
  assert.equal(isViewStale("nonsense", NOW), true);
});

// ── event filters ───────────────────────────────────────────────────

test("filters: empty matches everything; attendee floor and keywords narrow", () => {
  assert.equal(matchesEventFilter(event("e"), {}), true);
  assert.equal(matchesEventFilter(event("e", { attendeeCount: 1 }), { minAttendees: 2 }), false);
  assert.equal(matchesEventFilter(event("e", { attendeeCount: 2 }), { minAttendees: 2 }), true);
  assert.equal(matchesEventFilter(event("e"), { keywords: ["henderson"] }), true);
  assert.equal(matchesEventFilter(event("e"), { keywords: ["standup", "1:1"] }), false);
  assert.equal(
    matchesEventFilter(event("e", { attendeeCount: 5 }), { minAttendees: 2, keywords: ["review"] }),
    true,
  );
});

// ── nextEventRun: strictly-after, earliest-match ────────────────────

test("the earliest matching fire strictly after `after` wins", () => {
  const at = nextEventRun(
    30,
    { minAttendees: 2 },
    [
      event("solo", { startsAt: "2026-08-19T13:00:00.000Z", attendeeCount: 1 }),
      event("second", { startsAt: "2026-08-19T16:00:00.000Z" }),
      event("first", { startsAt: "2026-08-19T14:00:00.000Z" }),
    ],
    NOW,
  );
  // "solo" fails the filter; "first" fires at 13:30, before "second"'s 15:30.
  assert.equal(at?.toISOString(), "2026-08-19T13:30:00.000Z");
});

test("a meeting learned of mid-window never fires — its moment predates the knowledge", () => {
  // Meeting at 12:20, prep 30 minutes before = 11:50, already past NOW.
  const at = nextEventRun(30, {}, [event("soon", { startsAt: "2026-08-19T12:20:00.000Z" })], NOW);
  assert.equal(at, null);
});

test("a just-prepped meeting cannot re-arm itself", () => {
  // Fire instant was 13:30; recomputing right after running at 13:31 must
  // land on nothing, not the same meeting.
  const after = new Date("2026-08-19T13:31:00.000Z");
  const at = nextEventRun(30, {}, [event("done", { startsAt: "2026-08-19T14:00:00.000Z" })], after);
  assert.equal(at, null);
});

// ── rearmUpdates: what a sync may touch ─────────────────────────────

function fixedAutomation(id: string, overrides: Partial<Automation> = {}): Automation {
  return {
    id,
    ownerId: "u1",
    type: "morning_brief",
    label: "Morning brief",
    enabled: true,
    schedule: { kind: "fixed", rrule: "FREQ=DAILY", timeOfDay: "07:00" },
    timezone: "America/New_York",
    action: { kind: "morning_brief", params: {} },
    lastRunAt: null,
    nextRunAt: "2026-08-20T11:00:00.000Z",
    lastResult: null,
    createdAt: "2026-08-01T00:00:00.000Z",
    ...overrides,
  };
}

function relativeAutomation(id: string, overrides: Partial<Automation> = {}): Automation {
  return fixedAutomation(id, {
    type: "meeting_prep",
    schedule: { kind: "relative_to_event", minutesBefore: 30, eventFilter: { minAttendees: 2 } },
    action: { kind: "meeting_prep", params: {} },
    nextRunAt: null,
    ...overrides,
  });
}

test("same zone, no matching events: nothing to update", () => {
  assert.deepEqual(
    rearmUpdates([fixedAutomation("f1"), relativeAutomation("r1")], "America/New_York", [], NOW),
    [],
  );
});

test("fresh events arm a dormant relative automation", () => {
  const updates = rearmUpdates(
    [relativeAutomation("r1")],
    "America/New_York",
    [event("e1", { startsAt: "2026-08-19T14:00:00.000Z" })],
    NOW,
  );
  assert.deepEqual(updates, [{ id: "r1", fields: { nextRunAt: "2026-08-19T13:30:00.000Z" } }]);
});

test("a moved meeting re-arms; an unchanged one writes nothing", () => {
  const armed = relativeAutomation("r1", { nextRunAt: "2026-08-19T13:30:00.000Z" });
  const unchanged = rearmUpdates(
    [armed],
    "America/New_York",
    [event("e1", { startsAt: "2026-08-19T14:00:00.000Z" })],
    NOW,
  );
  assert.deepEqual(unchanged, []);
  const moved = rearmUpdates(
    [armed],
    "America/New_York",
    [event("e1", { startsAt: "2026-08-19T16:00:00.000Z" })],
    NOW,
  );
  assert.deepEqual(moved, [{ id: "r1", fields: { nextRunAt: "2026-08-19T15:30:00.000Z" } }]);
});

test("ACCEPTANCE #5 mechanism: a timezone change re-anchors fixed automations", () => {
  const updates = rearmUpdates([fixedAutomation("f1")], "Asia/Tokyo", [], NOW);
  // 07:00 Tokyo, next occurrence after 12:00Z Aug 19 = Aug 19 22:00Z.
  assert.deepEqual(updates, [
    { id: "f1", fields: { timezone: "Asia/Tokyo", nextRunAt: "2026-08-19T22:00:00.000Z" } },
  ]);
});

test("a disabled automation keeps its zone fresh but stays parked", () => {
  const updates = rearmUpdates(
    [fixedAutomation("f1", { enabled: false, nextRunAt: null })],
    "Asia/Tokyo",
    [],
    NOW,
  );
  assert.deepEqual(updates, [{ id: "f1", fields: { timezone: "Asia/Tokyo" } }]);
});

test("a due-but-unrun fire belongs to the tick — the sync must not move or clear it", () => {
  // Prep due at 11:50, tick hasn't claimed it yet, user unlocks phone at
  // 12:00 triggering a sync whose recompute would say null. Hands off.
  const pending = relativeAutomation("r1", { nextRunAt: "2026-08-19T11:50:00.000Z" });
  assert.deepEqual(rearmUpdates([pending], "America/New_York", [], NOW), []);
  // Even with a timezone change, only the zone moves.
  assert.deepEqual(rearmUpdates([pending], "Asia/Tokyo", [], NOW), [
    { id: "r1", fields: { timezone: "Asia/Tokyo" } },
  ]);
});

test("an invalid device zone never overwrites a good one", () => {
  const updates = rearmUpdates([fixedAutomation("f1")], "Starship/Bridge", [], NOW);
  assert.deepEqual(updates, []);
});
