import { strict as assert } from "node:assert";
import { test } from "node:test";

import type { CurrentWeather, Task } from "@otto/shared";

import type { BriefContext } from "../src/brief/gather.js";
import { dueToday, fireInstant, listCounts, wallDate } from "../src/brief/gather.js";
import { BRIEF_SYSTEM_PROMPT, serializeContext } from "../src/brief/synthesize.js";

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
  assert.ok(text.includes("YESTERDAY'S BRIEF: Flagged the passport renewal"));
  // Item contents never ride along — counts only.
  assert.ok(!text.includes("onions"));
});

test("the brief prompt carries the spec's load-bearing rules verbatim", () => {
  assert.ok(BRIEF_SYSTEM_PROMPT.includes("You are writing Otto's morning brief."));
  assert.ok(BRIEF_SYSTEM_PROMPT.includes("Weather, as ADVICE not data."));
  assert.ok(BRIEF_SYSTEM_PROMPT.includes("Under 150 words spoken."));
  assert.ok(BRIEF_SYSTEM_PROMPT.includes("Never read a full list aloud."));
  assert.ok(BRIEF_SYSTEM_PROMPT.includes("No preamble. Start with the first real thing."));
});
