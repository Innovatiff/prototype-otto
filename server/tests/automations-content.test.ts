/**
 * The built-in handlers' DECISIONS, pure: when Otto speaks, when it stays
 * silent, and the exact deterministic bodies. Acceptance #4 (empty evening
 * -> nothing) and #7 (missed sessions -> reshape-or-reset) live here.
 */
import { strict as assert } from "node:assert";
import { test } from "node:test";

import type { CalendarSyncEvent, Plan, SessionRecord, Task } from "@otto/shared";

import {
  briefPushBody,
  cleanWeekStreak,
  eveningFacts,
  eventsOnDate,
  hasEveningContent,
  overlapsIn,
  planCheckinMessage,
  resolveUpcomingMeeting,
  slippedReminders,
  tasksMatchingTitle,
  weatherLine,
} from "../src/automations/content.js";
import {
  sanitizeBody,
  shouldSuppressIgnoredTitle,
  titleKey,
  type DeliveryRecord,
} from "../src/automations/deliver.js";
import { missingBuiltIns } from "../src/automations/defaults.js";

const NOW = new Date("2026-08-19T11:02:00.000Z"); // 07:02 New York
const TZ = "America/New_York";

function event(id: string, overrides: Partial<CalendarSyncEvent> = {}): CalendarSyncEvent {
  return {
    id,
    title: "Henderson review",
    startsAt: "2026-08-19T13:30:00.000Z",
    endsAt: "2026-08-19T14:00:00.000Z",
    attendeeCount: 3,
    ...overrides,
  };
}

function task(id: string, overrides: Partial<Task> = {}): Task {
  return {
    id,
    ownerId: "u1",
    intent: "reminder",
    title: "Call the dentist",
    items: [],
    trigger: { type: "time", at: "2026-08-19T15:00:00.000Z" },
    verification: "none",
    status: "active",
    createdAt: "2026-08-18T00:00:00.000Z",
    ...overrides,
  };
}

// ── The persona choke point ─────────────────────────────────────────

test("sanitizeBody removes exclamation marks and caps at a sentence boundary", () => {
  assert.equal(sanitizeBody("Great work! Keep going!"), "Great work. Keep going.");
  const long = Array.from({ length: 12 }, (_, i) => `Sentence number ${i} has six words.`).join(" ");
  const capped = sanitizeBody(long);
  const words = capped.split(/\s+/).length;
  assert.ok(words <= 60, `capped body has ${words} words`);
  assert.ok(capped.endsWith("."), "trimmed at a sentence boundary");
  const unbroken = `${Array.from({ length: 80 }, (_, i) => `w${i}`).join(" ")}`;
  assert.equal(sanitizeBody(unbroken).split(/\s+/).length, 60);
});

// ── Morning brief push body ─────────────────────────────────────────

test("the brief push body is useful on its own: weather, the problem, the first thing", () => {
  const nine = event("a", {
    title: "Henderson review",
    startsAt: "2026-08-19T13:30:00.000Z",
    endsAt: "2026-08-19T14:00:00.000Z",
  });
  const dentist = event("b", {
    title: "Dentist",
    startsAt: "2026-08-19T13:45:00.000Z",
    endsAt: "2026-08-19T14:15:00.000Z",
  });
  const lunch = event("c", {
    title: "Lunch with Sam",
    startsAt: "2026-08-19T16:00:00.000Z",
    endsAt: "2026-08-19T17:00:00.000Z",
  });
  const body = briefPushBody(
    {
      weatherLine: "9 degrees and likely rain.",
      todayEvents: [nine, dentist, lunch],
      overlaps: overlapsIn([nine, dentist, lunch]),
      dueCount: 3,
      timezone: TZ,
    },
    NOW,
  );
  assert.match(body, /9 degrees and likely rain\./);
  assert.match(body, /Henderson review at 9:30 AM overlaps Dentist at 9:45 AM\./);
  assert.match(body, /First up: Lunch with Sam at 12:00 PM\./);
  assert.match(body, /Three reminders due today\./);
});

test("a morning with genuinely nothing produces an empty body — the handler suppresses", () => {
  const body = briefPushBody(
    { weatherLine: null, todayEvents: [], overlaps: [], dueCount: 0, timezone: TZ },
    NOW,
  );
  assert.equal(body, "");
});

test("the brief sees only TODAY — tomorrow's meetings are not 'First up'", () => {
  const todays = event("today", { startsAt: "2026-08-19T16:00:00.000Z", endsAt: "2026-08-19T17:00:00.000Z" });
  const tomorrows = event("tomorrow", {
    startsAt: "2026-08-20T13:30:00.000Z",
    endsAt: "2026-08-20T14:00:00.000Z",
  });
  // 03:00Z Aug 20 is still 23:00 Aug 19 in New York — wall dates, not UTC.
  const lateTonight = event("late", {
    startsAt: "2026-08-20T03:00:00.000Z",
    endsAt: "2026-08-20T03:30:00.000Z",
  });
  assert.deepEqual(
    eventsOnDate([todays, tomorrows, lateTonight], TZ, "2026-08-19").map((e) => e.id),
    ["today", "late"],
  );
});

test("weatherLine rounds honestly — never '-0 degrees'", () => {
  assert.equal(weatherLine({ temperatureC: 9.4, precipitationProbability: 80 }), "9 degrees and likely rain.");
  assert.equal(weatherLine({ temperatureC: -0.4, precipitationProbability: 10 }), "0 degrees.");
  assert.equal(weatherLine({ temperatureC: -3.6, precipitationProbability: 50 }), "-4 degrees and likely rain.");
});

test("overlapsIn finds the shared minutes", () => {
  const overlaps = overlapsIn([
    event("a", { startsAt: "2026-08-19T13:30:00.000Z", endsAt: "2026-08-19T14:00:00.000Z" }),
    event("b", { startsAt: "2026-08-19T13:45:00.000Z", endsAt: "2026-08-19T14:15:00.000Z" }),
    event("c", { startsAt: "2026-08-19T15:00:00.000Z", endsAt: "2026-08-19T16:00:00.000Z" }),
  ]);
  assert.equal(overlaps.length, 1);
  assert.equal(overlaps[0]?.minutes, 15);
});

// ── Evening shutdown: ACCEPTANCE #4's decision ──────────────────────

test("ACCEPTANCE #4 core: an empty evening has no content — nothing is composed or sent", () => {
  const facts = eveningFacts([], [], NOW, TZ);
  assert.equal(hasEveningContent(facts), false);
});

test("tomorrow's events, slipped reminders, and due-tomorrow all count as content", () => {
  const tomorrowMeeting = event("t", { startsAt: "2026-08-20T14:00:00.000Z", endsAt: "2026-08-20T15:00:00.000Z" });
  withEvents: {
    const facts = eveningFacts([tomorrowMeeting], [], NOW, TZ);
    assert.equal(hasEveningContent(facts), true);
    assert.equal(facts.tomorrowEvents[0]?.time, "10:00 AM");
  }
  const slipped = task("s", { trigger: { type: "time", at: "2026-08-19T10:00:00.000Z" } });
  assert.equal(hasEveningContent(eveningFacts([], [slipped], NOW, TZ)), true);
  // Today's remaining events are NOT tomorrow's content.
  assert.equal(hasEveningContent(eveningFacts([event("today")], [], NOW, TZ)), false);
});

test("slippedReminders: past-due actives only", () => {
  const past = task("p", { trigger: { type: "time", at: "2026-08-19T10:00:00.000Z" } });
  const future = task("f", { trigger: { type: "time", at: "2026-08-19T15:00:00.000Z" } });
  const done = task("d", {
    status: "completed",
    trigger: { type: "time", at: "2026-08-19T10:00:00.000Z" },
  });
  const list = task("l", { intent: "list", trigger: { type: "none" } });
  assert.deepEqual(slippedReminders([past, future, done, list], NOW).map((t) => t.id), ["p"]);
});

// ── Meeting prep ────────────────────────────────────────────────────

test("resolveUpcomingMeeting finds the meeting this fire is for — and only that window", () => {
  const at1330 = event("m", { startsAt: "2026-08-19T11:30:00.000Z", attendeeCount: 3 });
  const found = resolveUpcomingMeeting([at1330], { minAttendees: 2 }, 30, NOW);
  assert.equal(found?.id, "m");
  // Vanished / moved beyond the window / already started / solo — silence.
  assert.equal(resolveUpcomingMeeting([], { minAttendees: 2 }, 30, NOW), null);
  assert.equal(
    resolveUpcomingMeeting(
      [event("far", { startsAt: "2026-08-19T13:00:00.000Z" })],
      {},
      30,
      NOW,
    ),
    null,
    "an hour out is beyond the 30-minute prep window",
  );
  assert.equal(
    resolveUpcomingMeeting(
      [event("started", { startsAt: "2026-08-19T11:00:00.000Z" })],
      {},
      30,
      NOW,
    ),
    null,
  );
  assert.equal(
    resolveUpcomingMeeting([event("solo", { startsAt: "2026-08-19T11:30:00.000Z", attendeeCount: 1 })], { minAttendees: 2 }, 30, NOW),
    null,
  );
});

test("the ignored-recurring-meeting rule: three unopened preps end the prepping", () => {
  const delivery = (id: string, key: string, openedAt: string | null): DeliveryRecord => ({
    id,
    ownerId: "u1",
    automationId: "a1",
    automationType: "meeting_prep",
    title: "Weekly Sync",
    body: "…",
    deepLink: "otto://calendar",
    channel: "push",
    titleKey: key,
    openedAt,
    action: null,
    actionAt: null,
    sendOutcome: "sent",
    createdAt: "2026-08-01T00:00:00.000Z",
  });
  const key = titleKey("Weekly Sync (Q3)");
  assert.equal(key, "weekly_sync_q3");
  assert.equal(titleKey("weekly sync Q3"), key, "same meeting, same key");
  const twoIgnored = [delivery("1", key, null), delivery("2", key, null)];
  assert.equal(shouldSuppressIgnoredTitle(twoIgnored, key), false);
  const threeIgnored = [...twoIgnored, delivery("3", key, null)];
  assert.equal(shouldSuppressIgnoredTitle(threeIgnored, key), true);
  const oneOpened = [...twoIgnored, delivery("3", key, "2026-08-10T00:00:00.000Z")];
  assert.equal(shouldSuppressIgnoredTitle(oneOpened, key), false);
  // Other meetings' deliveries don't count against this title.
  assert.equal(shouldSuppressIgnoredTitle(threeIgnored, titleKey("Design review")), false);
});

test("tasksMatchingTitle shares meaty words only", () => {
  const tasks = [
    task("1", { title: "Prep numbers for Henderson" }),
    task("2", { title: "Buy milk" }),
    task("3", { title: "Henderson follow-up", status: "completed" }),
  ];
  assert.deepEqual(
    tasksMatchingTitle(tasks, "Henderson review").map((t) => t.id),
    ["1"],
  );
});

// ── Plan check-in: ACCEPTANCE #7's decision ─────────────────────────

function plan(createdAt: string): Plan {
  const schedule = [];
  for (let week = 0; week < 8; week += 1) {
    schedule.push(
      { sessionId: "lower-a", dayOffset: week * 7 },
      { sessionId: "upper-a", dayOffset: week * 7 + 3 },
    );
  }
  return {
    id: "plan-1",
    ownerId: "u1",
    meta: { domain: "fitness", goal: "strength", horizonDays: 56, version: 1 },
    constraints: { domain: "fitness" },
    sessions: [],
    schedule,
    status: "active",
    createdAt,
  };
}

function record(id: string, completedAt: string): SessionRecord {
  return {
    id,
    ownerId: "u1",
    planId: "plan-1",
    sessionId: "lower-a",
    startedAt: completedAt,
    completedAt,
    completedSteps: [],
    skippedSteps: [],
    loggedValues: {},
    durationSec: 1800,
    endedEarly: false,
  };
}

function summaryWith(missedThisWeek: number) {
  return {
    planId: "plan-1",
    records: 6,
    scheduledToDate: 6,
    missedToDate: 0,
    missedThisWeek,
    substitutionCandidates: [],
    latestLoggedValues: {},
  };
}

test("ACCEPTANCE #7 core: two missed sessions offer a reshape or a clean Monday reset", () => {
  const message = planCheckinMessage([
    { plan: plan("2026-08-04T12:00:00.000Z"), summary: summaryWith(2), streakWeeks: 0 },
  ]);
  assert.equal(
    message?.body,
    "You've missed two fitness sessions this week. Want me to reshape the plan, or reset it clean starting Monday?",
  );
});

test("a three-week clean streak is praised with the SPECIFIC number", () => {
  const message = planCheckinMessage([
    { plan: plan("2026-08-04T12:00:00.000Z"), summary: summaryWith(0), streakWeeks: 3 },
  ]);
  assert.equal(message?.body, "Three weeks without missing a session. The fitness plan holds.");
});

test("nothing notable means NO MESSAGE — and struggling outranks thriving", () => {
  assert.equal(
    planCheckinMessage([
      { plan: plan("2026-08-04T12:00:00.000Z"), summary: summaryWith(0), streakWeeks: 1 },
    ]),
    null,
  );
  assert.equal(planCheckinMessage([]), null);
  const both = planCheckinMessage([
    { plan: { ...plan("2026-08-04T12:00:00.000Z"), id: "ok" }, summary: { ...summaryWith(0), planId: "ok" }, streakWeeks: 4 },
    { plan: { ...plan("2026-08-04T12:00:00.000Z"), id: "bad" }, summary: { ...summaryWith(3), planId: "bad" }, streakWeeks: 0 },
  ]);
  assert.equal(both?.planId, "bad");
  assert.match(both?.body ?? "", /missed three/);
});

test("cleanWeekStreak counts complete weeks back from the latest, breaking on a miss", () => {
  // Plan started Jul 8 12:00; NOW is Aug 19 11:02 — 41 elapsed days, so
  // FIVE complete weeks (0-4); week 5 is still in progress and ignored.
  const p = plan("2026-07-08T12:00:00.000Z");
  const attendAll = (weeks: number[]): SessionRecord[] =>
    weeks.flatMap((week) => [
      record(`w${week}a`, new Date(Date.parse("2026-07-08T13:00:00.000Z") + week * 7 * 86_400_000).toISOString()),
      record(`w${week}b`, new Date(Date.parse("2026-07-08T13:00:00.000Z") + (week * 7 + 3) * 86_400_000).toISOString()),
    ]);
  assert.equal(cleanWeekStreak(p, attendAll([0, 1, 2, 3, 4, 5]), NOW), 5);
  assert.equal(cleanWeekStreak(p, attendAll([0, 1, 2, 4, 5]), NOW), 1, "the week-3 miss breaks it");
  assert.equal(cleanWeekStreak(p, attendAll([0, 1]), NOW), 0, "recent misses mean no streak");
  assert.equal(cleanWeekStreak(p, [], NOW), 0);
});

// ── Built-in seeding ────────────────────────────────────────────────

test("missingBuiltIns creates exactly what's absent, armed in the user's zone", () => {
  let n = 0;
  const mint = () => `auto-${(n += 1)}`;
  const created = missingBuiltIns([], "u1", TZ, NOW, mint);
  assert.deepEqual(
    created.map((automation) => automation.type).sort(),
    ["evening_shutdown", "meeting_prep", "morning_brief", "plan_checkin", "weekly_review"],
  );
  const brief = created.find((automation) => automation.type === "morning_brief");
  // 07:25 New York tomorrow (today's 07:25 passed at 07:02? No — 07:02 < 07:25: today).
  assert.equal(brief?.nextRunAt, "2026-08-19T11:25:00.000Z");
  const prep = created.find((automation) => automation.type === "meeting_prep");
  assert.equal(prep?.nextRunAt, null, "event-relative: armed by the calendar, not a rule");
  assert.ok(created.every((automation) => automation.enabled));
  assert.ok(created.every((automation) => automation.action.kind === automation.type));

  // Idempotence: everything present -> nothing created.
  assert.equal(missingBuiltIns(created, "u1", TZ, NOW, mint).length, 0);
});
