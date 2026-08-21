import { strict as assert } from "node:assert";
import { test } from "node:test";

import type { CurrentWeather, Plan, SessionRecord, Task } from "@otto/shared";

import type { BriefContext } from "../src/brief/gather.js";
import {
  dueToday,
  fireInstant,
  listCounts,
  planSessionsToday,
  wallDate,
} from "../src/brief/gather.js";
import { isServableBrief } from "../src/brief/store.js";
import {
  BRIEF_SYSTEM_PROMPT,
  BRIEF_TOOL,
  EVENING_SYSTEM_PROMPT,
  joinChapters,
  parseChapters,
  serializeContext,
  WEEKLY_SYSTEM_PROMPT,
} from "../src/brief/synthesize.js";
import { weeklyFactsText } from "../src/brief/weekly.js";

const TS = "2026-08-18T12:00:00.000Z";

function task(partial: Partial<Task> & { id: string }): Task {
  return {
    ownerId: "u1",
    intent: "reminder",
    title: partial.id,
    items: [],
    trigger: { type: "none" },
    verification: "inline",
    status: "active",
    createdAt: TS,
    ...partial,
  };
}

// ── Wall-date math ──────────────────────────────────────────────────

test("wallDate answers in the user's timezone, not UTC", () => {
  // 02:30 UTC on the 19th is still the evening of the 18th in Toronto.
  const lateNight = new Date("2026-08-19T02:30:00.000Z");
  assert.equal(wallDate(lateNight, "America/Toronto"), "2026-08-18");
  assert.equal(wallDate(lateNight, "UTC"), "2026-08-19");
  // Garbage timezone falls back to UTC instead of throwing.
  assert.equal(wallDate(lateNight, "Not/AZone"), "2026-08-19");
});

// ── Due-today filtering ─────────────────────────────────────────────

test("dueToday keeps only fire instants on today's wall date, sorted", () => {
  const now = new Date("2026-08-18T14:00:00.000Z"); // 10:00 in Toronto
  const tasks = [
    task({ id: "tonight", trigger: { type: "time", at: "2026-08-19T00:30:00.000Z" } }), // 20:30 Toronto = today
    task({ id: "tomorrow", trigger: { type: "time", at: "2026-08-19T14:00:00.000Z" } }),
    task({ id: "earlier", trigger: { type: "time", at: "2026-08-18T13:00:00.000Z" } }),
    task({ id: "recurring", trigger: { type: "recurring", rrule: "FREQ=DAILY", nextFire: "2026-08-18T22:00:00.000Z" } }),
    task({ id: "listy", intent: "list" }),
  ];
  const due = dueToday(tasks, now, "America/Toronto");
  assert.deepEqual(
    due.map((entry) => entry.taskId),
    ["earlier", "recurring", "tonight"],
  );
});

test("fireInstant reads time and recurring triggers, none for none", () => {
  assert.equal(fireInstant(task({ id: "a" })), null);
  assert.equal(
    fireInstant(task({ id: "b", trigger: { type: "time", at: TS } })),
    TS,
  );
});

// ── List counts ─────────────────────────────────────────────────────

test("lists are counted, never enumerated, and finished lists drop", () => {
  const item = (id: string, checked: boolean) => ({ id, text: id, checked, addedAt: TS });
  const lists = listCounts([
    task({
      id: "walmart",
      intent: "list",
      title: "Walmart list",
      context: "Walmart",
      items: [item("a", false), item("b", false), item("c", true)],
    }),
    task({ id: "done", intent: "list", items: [item("d", true)] }),
    task({ id: "reminder", trigger: { type: "time", at: TS } }),
  ]);
  assert.deepEqual(lists, [
    { taskId: "walmart", title: "Walmart list", context: "Walmart", openCount: 2 },
  ]);
});

// ── Today's plan sessions ───────────────────────────────────────────

function planFixture(): Plan {
  return {
    id: "p1",
    ownerId: "u1",
    meta: { domain: "fitness", goal: "Get stronger", horizonDays: 28, version: 1 },
    constraints: {},
    schedule: [
      { sessionId: "s1", dayOffset: 0, timeOfDay: "08:00" },
      { sessionId: "s2", dayOffset: 9, timeOfDay: "18:00" },
      { sessionId: "s3", dayOffset: 9 },
      { sessionId: "s1", dayOffset: 10 },
    ],
    sessions: [
      { id: "s1", title: "Push Day", estimatedMinutes: 40, steps: [] },
      { id: "s2", title: "Pull Day", estimatedMinutes: 45, steps: [] },
    ],
    status: "active",
    createdAt: "2026-08-09T12:00:00.000Z",
  };
}

function recordFixture(sessionId: string, completedAt: string): SessionRecord {
  return {
    id: `r-${sessionId}`,
    ownerId: "u1",
    planId: "p1",
    sessionId,
    startedAt: completedAt,
    completedAt,
    completedSteps: [],
    skippedSteps: [],
    loggedValues: {},
    durationSec: 1800,
    endedEarly: false,
  };
}

test("planSessionsToday keeps today's occurrences, sorted, weeks computed", () => {
  // 10:00 in Toronto on Aug 18; the plan started Aug 9, so dayOffset 9
  // lands today (week 2), 0 was last week, 10 is tomorrow.
  const now = new Date("2026-08-18T14:00:00.000Z");
  const sessions = planSessionsToday(
    [planFixture()],
    new Map(),
    now,
    "America/Toronto",
  );
  assert.deepEqual(
    sessions.map((s) => [s.sessionTitle, s.week, s.timeOfDay ?? null, s.completed]),
    [
      ["Pull Day", 2, "18:00", false],
      // No template with id s3 — falls back to the plan's goal, sorts last.
      ["Get stronger", 2, null, false],
    ],
  );
});

test("planSessionsToday marks completed only for records filed today", () => {
  const now = new Date("2026-08-18T23:00:00.000Z"); // 19:00 Toronto
  const records = new Map<string, readonly SessionRecord[]>([
    [
      "p1",
      [
        recordFixture("s2", "2026-08-18T21:30:00.000Z"), // today: banked
        recordFixture("s3", "2026-08-17T21:30:00.000Z"), // yesterday: not
      ],
    ],
  ]);
  const sessions = planSessionsToday([planFixture()], records, now, "America/Toronto");
  assert.deepEqual(
    sessions.map((s) => [s.sessionId, s.completed]),
    [
      ["s2", true],
      ["s3", false],
    ],
  );
});

// ── Serialization for the model ─────────────────────────────────────

function contextFixture(): BriefContext {
  const weather: CurrentWeather = {
    temperatureC: 9.2,
    apparentC: 7.1,
    precipitationMm: 0.4,
    precipitationProbability: 62,
    windKmh: 18,
    weatherCode: 61,
    advice: ["rain"],
  };
  return {
    date: "2026-08-18",
    weather,
    request: {
      timezone: "America/Toronto",
      events: [
        {
          id: "e1",
          title: "Dentist",
          startsAt: "2026-08-18T18:00:00.000Z",
          endsAt: "2026-08-18T19:00:00.000Z",
          isAllDay: false,
          location: "Mississauga",
        },
        {
          id: "e2",
          title: "Team sync",
          startsAt: "2026-08-18T18:30:00.000Z",
          endsAt: "2026-08-18T19:30:00.000Z",
          isAllDay: false,
          location: "Toronto",
        },
      ],
      conflicts: [
        {
          eventA: {
            id: "e1",
            title: "Dentist",
            startsAt: "2026-08-18T18:00:00.000Z",
            endsAt: "2026-08-18T19:00:00.000Z",
            isAllDay: false,
          },
          eventB: {
            id: "e2",
            title: "Team sync",
            startsAt: "2026-08-18T18:30:00.000Z",
            endsAt: "2026-08-18T19:30:00.000Z",
            isAllDay: false,
          },
          kind: "overlap",
          minutesShort: 30,
        },
      ],
    },
    dueTasks: [{ taskId: "t1", title: "Call the pharmacy", at: "2026-08-18T19:00:00.000Z" }],
    lists: [{ taskId: "w1", title: "Walmart list", context: "Walmart", openCount: 19 }],
    planSessions: [
      {
        planId: "p1",
        sessionId: "s1",
        sessionTitle: "Push Day",
        domain: "fitness",
        week: 2,
        timeOfDay: "08:00",
        completed: false,
      },
    ],
    hasActivePlans: true,
    carried: [],
    yesterdaySummary: "Flagged the passport renewal; prioritized the deck review.",
  };
}

test("serialized context is compact, timezone-correct, and carries the digested facts", () => {
  const text = serializeContext(contextFixture());
  assert.ok(text.includes("advice: rain"));
  assert.ok(text.includes("2:00 PM-3:00 PM Dentist @ Mississauga"));
  assert.ok(text.includes("CONFLICTS (detected in code, trust them):"));
  assert.ok(text.includes("overlap by 30min"));
  assert.ok(text.includes("Walmart list @ Walmart: 19 open"));
  assert.ok(text.includes("PLAN SESSIONS TODAY (1):"));
  assert.ok(text.includes("- Push Day (fitness, week 2) at 08:00"));
  assert.ok(text.includes("YESTERDAY'S BRIEF: Flagged the passport renewal"));
  // Item contents never ride along — counts only.
  assert.ok(!text.includes("onions"));
});

test("no active plans serializes as an explicit omit instruction", () => {
  const context = { ...contextFixture(), planSessions: [], hasActivePlans: false };
  const text = serializeContext(context);
  assert.ok(text.includes("ACTIVE PLANS: none (omit the plans chapter)"));
  assert.ok(!text.includes("PLAN SESSIONS TODAY"));
});

test("plans exist but nothing falls today — the rest-day line rides along", () => {
  const context = { ...contextFixture(), planSessions: [] };
  const text = serializeContext(context);
  assert.ok(text.includes("PLAN SESSIONS TODAY (0):"));
  assert.ok(text.includes("- none scheduled today"));
});

test("the brief prompt carries the spec's load-bearing rules", () => {
  assert.ok(BRIEF_SYSTEM_PROMPT.includes("You are writing Otto's morning brief."));
  assert.ok(BRIEF_SYSTEM_PROMPT.includes("Weather as ADVICE not data"));
  assert.ok(BRIEF_SYSTEM_PROMPT.includes("Under 150 words TOTAL"));
  assert.ok(BRIEF_SYSTEM_PROMPT.includes("never the items"));
  assert.ok(BRIEF_SYSTEM_PROMPT.includes("start with the first real thing"));
});

// ── Chapters: the contract the synced visual tour rides on ──────────

test("the chapter contract: core visuals always present, empties said kindly", () => {
  assert.ok(BRIEF_SYSTEM_PROMPT.includes('"weather" — ALWAYS present'));
  assert.ok(BRIEF_SYSTEM_PROMPT.includes('"calendar" — ALWAYS present'));
  assert.ok(BRIEF_SYSTEM_PROMPT.includes('"reminders" — ALWAYS present'));
  assert.ok(BRIEF_SYSTEM_PROMPT.includes('"plans" — include whenever the user has ANY active plan'));
  assert.ok(BRIEF_SYSTEM_PROMPT.includes("OMIT this"));
  assert.ok(BRIEF_SYSTEM_PROMPT.includes("Calendar's clear"));
  assert.equal(BRIEF_TOOL.name, "emit_brief");
});

test("parseChapters accepts well-formed tool input and rejects junk", () => {
  const good = parseChapters({
    chapters: [
      { kind: "weather", spoken: "Nine degrees and raining — take the car." },
      { kind: "calendar", spoken: "Calendar's clear — the day is yours." },
      { kind: "reminders", spoken: "Nothing due today." },
    ],
  });
  assert.ok(good !== null);
  assert.equal(good.length, 3);
  assert.equal(good[0]?.kind, "weather");

  assert.equal(parseChapters(null), null);
  assert.equal(parseChapters({}), null);
  assert.equal(parseChapters({ chapters: [] }), null);
  assert.equal(parseChapters({ chapters: [{ kind: "banana", spoken: "hi" }] }), null);
  assert.equal(parseChapters({ chapters: [{ kind: "weather", spoken: "" }] }), null);
  assert.equal(parseChapters({ chapters: [{ kind: "weather" }] }), null);
});

test("joinChapters flows the chapters into one clean spoken text", () => {
  const joined = joinChapters([
    { kind: "weather", spoken: "  Nine degrees and raining. " },
    { kind: "calendar", spoken: "   " },
    { kind: "reminders", spoken: "Nothing due today." },
  ]);
  assert.equal(joined, "Nine degrees and raining. Nothing due today.");
});

// ── The bookends: evening, weekly, and the instant path ─────────────

test("the evening and weekly prompts carry their load-bearing rules", () => {
  assert.ok(EVENING_SYSTEM_PROMPT.includes("Under 80 words TOTAL"));
  assert.ok(EVENING_SYSTEM_PROMPT.includes("Tomorrow's first commitment"));
  assert.ok(EVENING_SYSTEM_PROMPT.includes("marked (tomorrow)"));
  assert.ok(EVENING_SYSTEM_PROMPT.includes("No weather, no pep talk"));
  assert.ok(WEEKLY_SYSTEM_PROMPT.includes("THE WEEK'S FACTS"));
  assert.ok(WEEKLY_SYSTEM_PROMPT.includes("Under 100 words TOTAL"));
  assert.ok(WEEKLY_SYSTEM_PROMPT.includes("no scolding"));
});

test("events past today's wall date are tagged (tomorrow) in the context", () => {
  const context = contextFixture();
  context.request.events.push({
    id: "e3",
    title: "Standup",
    startsAt: "2026-08-19T13:00:00.000Z", // next wall day in Toronto
    endsAt: "2026-08-19T13:15:00.000Z",
    isAllDay: false,
  });
  const text = serializeContext(context);
  assert.ok(text.includes("Standup (tomorrow)"));
  assert.ok(!text.includes("Dentist @ Mississauga (tomorrow)"));
});

test("weekly facts serialize with counted numbers only", () => {
  const text = weeklyFactsText({
    sessionsDone: 3,
    tasksCleared: 7,
    voyagesPlanned: 1,
    bufferKept: 300,
    currency: "USD",
  });
  assert.ok(text.includes("guided sessions completed: 3"));
  assert.ok(text.includes("tasks completed: 7"));
  assert.ok(text.includes("kept 300 USD back under budget"));
  const none = weeklyFactsText({
    sessionsDone: 0,
    tasksCleared: 0,
    voyagesPlanned: 0,
    bufferKept: 0,
    currency: "USD",
  });
  assert.ok(!none.includes("kept"));
});

test("a stored brief is servable only when playable and fresh", () => {
  const record = {
    ownerId: "u1",
    date: "2026-08-18",
    spoken: "Morning.",
    summary: "s",
    createdAt: "2026-08-18T11:20:00.000Z",
    chapters: [{ kind: "weather" as const, spoken: "Nine and clear." }],
    card: {
      date: "2026-08-18",
      events: [],
      conflicts: [],
      dueTasks: [],
      lists: [],
    },
  };
  const now = new Date("2026-08-18T14:00:00.000Z");
  assert.equal(isServableBrief(record, now), true);
  // Playable halves are required…
  assert.equal(isServableBrief({ ...record, chapters: undefined }, now), false);
  assert.equal(isServableBrief({ ...record, card: undefined }, now), false);
  // …and yesterday's record is yesterday's news.
  assert.equal(
    isServableBrief(record, new Date("2026-08-19T09:00:00.000Z")),
    false,
  );
});
