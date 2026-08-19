/**
 * Pins the scheduler's wall-clock math across the edges that break
 * hand-rolled offset arithmetic: both DST transitions, nonexistent and
 * ambiguous local times, weekday wrap, and timezone changes.
 *
 * America/New_York in 2026: spring forward Mar 8 (02:00 EST -> 03:00 EDT),
 * fall back Nov 1 (02:00 EDT -> 01:00 EST).
 */
import { strict as assert } from "node:assert";
import { test } from "node:test";

import { nextFixedRun, nextRunAt, parseRecurrence } from "../src/automations/schedule.js";

const NY = "America/New_York";

function next(rrule: string, timeOfDay: string, zone: string, afterIso: string): string | null {
  const result = nextFixedRun(rrule, timeOfDay, zone, new Date(afterIso));
  return result === null ? null : result.toISOString();
}

test("a daily 07:00 stays 07:00 local across spring forward — the UTC offset moves instead", () => {
  // Mar 7, 08:00 EST (13:00Z): today's 07:00 already passed. Naive +24h
  // arithmetic would say 12:00Z tomorrow; the correct answer is 11:00Z,
  // because tomorrow is EDT.
  assert.equal(next("FREQ=DAILY", "07:00", NY, "2026-03-07T13:00:00.000Z"), "2026-03-08T11:00:00.000Z");
});

test("a daily 07:00 stays 07:00 local across fall back", () => {
  // Oct 31, 08:00 EDT (12:00Z) -> Nov 1 is EST, so 07:00 local is 12:00Z.
  assert.equal(next("FREQ=DAILY", "07:00", NY, "2026-10-31T12:00:00.000Z"), "2026-11-01T12:00:00.000Z");
});

test("a nonexistent wall time (inside the spring-forward gap) fires at the adjusted instant", () => {
  // 02:30 does not exist on Mar 8; luxon shifts it forward through the gap
  // to 03:30 EDT (07:30Z). The automation runs once, slightly late — it
  // does not vanish and does not double-fire.
  assert.equal(next("FREQ=DAILY", "02:30", NY, "2026-03-08T00:00:00.000Z"), "2026-03-08T07:30:00.000Z");
});

test("an ambiguous wall time (fall back) resolves to its first occurrence", () => {
  // 01:30 happens twice on Nov 1: 05:30Z (EDT) then 06:30Z (EST). The
  // earlier one wins — one fire, not two.
  assert.equal(next("FREQ=DAILY", "01:30", NY, "2026-11-01T00:00:00.000Z"), "2026-11-01T05:30:00.000Z");
});

test("weekly BYDAY wraps to the next matching weekday", () => {
  // Friday Aug 21 2026, 16:00 ET (20:00Z): 15:30 already passed, so
  // FREQ=WEEKLY;BYDAY=FR lands next Friday.
  assert.equal(
    next("FREQ=WEEKLY;BYDAY=FR", "15:30", NY, "2026-08-21T20:00:00.000Z"),
    "2026-08-28T19:30:00.000Z",
  );
  // The same instant with a weekday rule lands Monday morning.
  assert.equal(
    next("FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR", "07:10", NY, "2026-08-21T20:00:00.000Z"),
    "2026-08-24T11:10:00.000Z",
  );
});

test("the next run is strictly after `after` — an exact hit advances to the following occurrence", () => {
  // Exactly 07:00 EDT on Aug 19 -> tomorrow, never "now" (which would
  // re-fire the run that just happened).
  assert.equal(next("FREQ=DAILY", "07:00", NY, "2026-08-19T11:00:00.000Z"), "2026-08-20T11:00:00.000Z");
});

test("changing the timezone recomputes the instant, not the wall clock", () => {
  const after = "2026-08-19T00:00:00.000Z";
  // At that instant it is 20:00 Aug 18 in New York (07:00 tomorrow = 11:00Z)
  // but already 09:00 Aug 19 in Tokyo — today's 07:00 has passed, so the
  // next fire is Aug 20 07:00 JST = Aug 19 22:00Z.
  assert.equal(next("FREQ=DAILY", "07:00", NY, after), "2026-08-19T11:00:00.000Z");
  assert.equal(next("FREQ=DAILY", "07:00", "Asia/Tokyo", after), "2026-08-19T22:00:00.000Z");
});

test("the recurrence parser accepts exactly the supported subset", () => {
  assert.deepEqual(parseRecurrence("FREQ=DAILY"), { freq: "daily" });
  assert.deepEqual(parseRecurrence("freq=daily"), { freq: "daily" });
  assert.deepEqual(parseRecurrence("FREQ=DAILY;INTERVAL=1"), { freq: "daily" });
  const weekly = parseRecurrence("FREQ=WEEKLY;BYDAY=MO,WE,fr");
  assert.ok(weekly !== null && weekly.freq === "weekly");
  if (weekly !== null && weekly.freq === "weekly") {
    assert.deepEqual([...weekly.weekdays].sort(), [1, 3, 5]);
  }
});

test("everything outside the subset is rejected, never accepted-but-ignored", () => {
  const rejected = [
    "",
    "FREQ=MONTHLY",
    "FREQ=YEARLY",
    "FREQ=WEEKLY", // weekly requires BYDAY
    "FREQ=DAILY;BYDAY=MO", // daily must not carry BYDAY
    "FREQ=DAILY;INTERVAL=2",
    "FREQ=WEEKLY;BYDAY=FR;UNTIL=20261231T000000Z",
    "FREQ=WEEKLY;BYDAY=FR;COUNT=10",
    "FREQ=WEEKLY;BYDAY=FRIDAY",
    "FREQ=DAILY;FREQ=DAILY",
    "BYDAY=FR",
    "every friday",
  ];
  for (const rrule of rejected) {
    assert.equal(parseRecurrence(rrule), null, rrule);
  }
});

test("an unschedulable automation goes dormant (null), never fires at a wrong time", () => {
  const after = new Date("2026-08-19T00:00:00.000Z");
  assert.equal(nextFixedRun("FREQ=MONTHLY", "07:00", NY, after), null);
  assert.equal(nextFixedRun("FREQ=DAILY", "7:00", NY, after), null);
  assert.equal(nextFixedRun("FREQ=DAILY", "07:00", "Mars/Olympus_Mons", after), null);
});

test("relative_to_event schedules have no rule-derived next run — the calendar drives them", () => {
  const at = nextRunAt(
    { kind: "relative_to_event", minutesBefore: 30, eventFilter: {} },
    NY,
    new Date("2026-08-19T00:00:00.000Z"),
  );
  assert.equal(at, null);
  const fixed = nextRunAt(
    { kind: "fixed", rrule: "FREQ=DAILY", timeOfDay: "07:00" },
    NY,
    new Date("2026-08-19T00:00:00.000Z"),
  );
  assert.equal(fixed?.toISOString(), "2026-08-19T11:00:00.000Z");
});
