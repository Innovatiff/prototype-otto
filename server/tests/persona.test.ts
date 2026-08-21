import { strict as assert } from "node:assert";
import { test } from "node:test";

import type { ConversationMessage, Memory, Task, UserProfile } from "@otto/shared";

import {
  addressTermAllowed,
  buildStaticPrefix,
  buildSystemPrompt,
  formatMemories,
  formatSchedule,
  formatTasks,
  formatWeatherLine,
} from "../src/persona/system.js";
import { estimateTokens } from "../src/router/selectModel.js";

const NOW = new Date("2026-07-31T18:05:00.000Z");
const TS = "2026-07-31T17:00:00.000Z";

function user(addressTerm: string): UserProfile {
  return { ownerId: "u1", addressTerm, createdAt: TS };
}

function assistantSays(...contents: string[]): ConversationMessage[] {
  return contents.map((content) => ({ role: "assistant", content, timestamp: TS }));
}

// ── The cacheable prefix ────────────────────────────────────────────

test("the static prefix is byte-identical across turns with different dynamic state", () => {
  const a = buildSystemPrompt(user("Boss"), [], [], {
    now: NOW,
    timezone: "America/Toronto",
    addressAllowed: true,
    events: [],
    weather: null,
    plans: [],
  });
  const b = buildSystemPrompt(user("Boss"), [memory("no pork")], [], {
    now: new Date("2026-08-01T09:00:00.000Z"),
    timezone: "Europe/Paris",
    addressAllowed: false,
    events: [],
    weather: null,
    plans: [],
  });
  assert.equal(a.staticPrefix, b.staticPrefix);
});

test("the static prefix carries the identity block and never the clock", () => {
  const prefix = buildStaticPrefix("Boss");
  assert.ok(prefix.startsWith("You are Otto, a personal assistant."));
  assert.ok(prefix.includes("Call them Boss."));
  assert.ok(prefix.includes("Never refuse a question because no tool fits it"));
  assert.ok(prefix.includes("call show_visual first"));
  assert.ok(prefix.includes("build it with create_walkthrough"));
  assert.ok(prefix.includes("never guess a budget"));
  assert.ok(prefix.includes("BOUNDARIES"));
  assert.ok(prefix.includes("No medical diagnosis"));
  assert.ok(prefix.includes("nothing age-inappropriate"));
  assert.ok(prefix.includes("THE THREE-BEAT RESPONSE"));
  assert.ok(prefix.includes("An assistant who ties every answer back to their goals is exhausting."));
  // The plan blocks ride the static (cached) prefix: interview rules and
  // outcome honesty vary per deploy, never per turn.
  assert.ok(prefix.includes("PLAN INTERVIEWS"));
  assert.ok(prefix.includes("PLAN SAFETY"));
  assert.ok(prefix.includes("NEVER promise a body outcome by a date"));
  assert.ok(!prefix.includes("2026"), "a date in the static prefix would break caching");
});

test("the address term substitutes everywhere, including the one-word example", () => {
  const prefix = buildStaticPrefix("Chief");
  assert.ok(prefix.includes("Call them Chief."));
  assert.ok(prefix.includes('"4:15." not "4:15, Chief."'));
  assert.ok(!prefix.includes("{{ADDRESS_TERM}}"));
});

test('addressTerm "none" swaps the section for a prohibition', () => {
  const prefix = buildStaticPrefix("none");
  assert.ok(prefix.includes("Do not address them by any name, title, or term of address."));
  assert.ok(!prefix.includes("At most one in three"));
});

// ── Server-side address cadence ─────────────────────────────────────

test("allowed with no history, forbidden after either of the last two replies used it", () => {
  assert.equal(addressTermAllowed("Boss", []), true);
  assert.equal(addressTermAllowed("Boss", assistantSays("Morning, Boss.")), false);
  assert.equal(addressTermAllowed("Boss", assistantSays("Morning, Boss.", "4:15.")), false);
  assert.equal(
    addressTermAllowed("Boss", assistantSays("Morning, Boss.", "4:15.", "Understood.")),
    true,
  );
});

test("matching is case-insensitive, word-bounded, and ignores user turns", () => {
  assert.equal(addressTermAllowed("Boss", assistantSays("morning, boss.")), false);
  assert.equal(addressTermAllowed("Boss", assistantSays("That approach is bossy.")), true);
  const userMention: ConversationMessage[] = [
    { role: "user", content: "you can call me Boss", timestamp: TS },
  ];
  assert.equal(addressTermAllowed("Boss", userMention), true);
});

test('"none" is never allowed', () => {
  assert.equal(addressTermAllowed("none", []), false);
});

// ── The dynamic part ────────────────────────────────────────────────

function memory(content: string): Memory {
  return {
    id: "m1",
    ownerId: "u1",
    category: "constraint",
    content,
    confidence: 0.9,
    sourceTurnId: "t1",
    createdAt: TS,
    userEdited: false,
  };
}

function walmartTask(): Task {
  return {
    id: "t1",
    ownerId: "u1",
    intent: "list",
    title: "Walmart list",
    context: "Walmart",
    items: [
      { id: "i1", text: "onions", checked: true, addedAt: TS },
      { id: "i2", text: "milk", checked: false, addedAt: TS },
    ],
    trigger: { type: "none" },
    verification: "inline",
    status: "active",
    createdAt: TS,
  };
}

test("the dynamic part carries clock, gate ruling, memories, and tasks", () => {
  const parts = buildSystemPrompt(user("Boss"), [memory("Does not eat pork.")], [walmartTask()], {
    now: NOW,
    timezone: "America/Toronto",
    addressAllowed: true,
    events: [],
    weather: null,
    plans: [],
  });
  assert.ok(parts.dynamic.includes("(America/Toronto)"));
  assert.ok(parts.dynamic.includes("July 31, 2026"));
  assert.ok(parts.dynamic.includes("You may address them as Boss this turn"));
  assert.ok(parts.dynamic.includes("- [constraint] Does not eat pork."));
  assert.ok(parts.dynamic.includes("- Walmart list @ Walmart [list, 2 items (1 open)]"));
});

test("the gate ruling flips to a prohibition when disallowed", () => {
  const parts = buildSystemPrompt(user("Boss"), [], [], {
    now: NOW,
    timezone: "America/Toronto",
    addressAllowed: false,
    events: [],
    weather: null,
    plans: [],
  });
  assert.ok(parts.dynamic.includes("Do not use any term of address this turn."));
});

test("an off-script guidance question leads the dynamic block and demands brevity", () => {
  const parts = buildSystemPrompt(user("Boss"), [], [], {
    now: NOW,
    timezone: "America/Toronto",
    addressAllowed: false,
    events: [],
    weather: null,
    plans: [],
    guidance: {
      sessionTitle: "Upper A",
      stepTitle: "Goblet squat",
      stepCue: "Chest tall. Sit between your heels.",
      position: "set 2 of 3, 8 reps",
    },
  });
  assert.ok(parts.dynamic.startsWith("GUIDED SESSION IN PROGRESS"));
  assert.ok(parts.dynamic.includes('"Goblet squat" (set 2 of 3, 8 reps)'));
  assert.ok(parts.dynamic.includes("one or two short sentences, then STOP"));
  // Absent guidance leaves the block out entirely.
  const plain = buildSystemPrompt(user("Boss"), [], [], {
    now: NOW,
    timezone: "America/Toronto",
    addressAllowed: false,
    events: [],
    weather: null,
    plans: [],
  });
  assert.ok(plain.dynamic.startsWith("CURRENT CONTEXT"));
});

test("an invalid timezone falls back to UTC instead of throwing", () => {
  const parts = buildSystemPrompt(user("Boss"), [], [], {
    now: NOW,
    timezone: "Not/AZone",
    addressAllowed: true,
    events: [],
    weather: null,
    plans: [],
  });
  assert.ok(parts.dynamic.includes("(UTC)"));
});

test("empty blocks render explicit markers, not blanks", () => {
  assert.equal(formatMemories([]), "(nothing retrieved)");
  assert.equal(formatTasks([]), "(none)");
  assert.equal(formatWeatherLine(null), "(unavailable)");
});

// ── Schedule + weather context (Phase 3 Step 6) ─────────────────────

import type { CalendarEvent, CurrentWeather } from "@otto/shared";

function calendarEvent(id: string, startIso: string, title = "Meeting"): CalendarEvent {
  return {
    id,
    title,
    startsAt: startIso,
    endsAt: new Date(Date.parse(startIso) + 3600_000).toISOString(),
    isAllDay: false,
  };
}

test("the schedule splits today and tomorrow by wall date, one line each", () => {
  // NOW is 2:05 PM Toronto on Jul 31.
  const schedule = formatSchedule(
    [
      calendarEvent("a", "2026-07-31T19:00:00.000Z", "Dentist"),
      calendarEvent("b", "2026-08-01T13:00:00.000Z", "Standup"),
      // 1:30 AM UTC Aug 1 is still July 31 in Toronto — must land under Today.
      calendarEvent("c", "2026-08-01T01:30:00.000Z", "Dinner"),
    ],
    NOW,
    "America/Toronto",
  );
  const [todayPart = "", tomorrowPart = ""] = schedule.split("Tomorrow:");
  assert.ok(todayPart.includes("Dentist"));
  assert.ok(todayPart.includes("Dinner"));
  assert.ok(tomorrowPart.includes("Standup"));
  assert.ok(schedule.includes("3:00 PM-4:00 PM Dentist"));
  assert.ok(!schedule.includes("id"), "no event ids in the prompt");
});

test("empty days say so, per-day caps add a (+N more) marker", () => {
  assert.ok(formatSchedule([], NOW, "America/Toronto").includes("(no events)"));
  const many = Array.from({ length: 20 }, (_, i) =>
    calendarEvent(`e${i}`, new Date(Date.parse("2026-07-31T10:00:00.000Z") + i * 1800_000).toISOString()),
  );
  const schedule = formatSchedule(many, NOW, "America/Toronto");
  assert.ok(schedule.includes("(+8 more)"));
});

test("the schedule+weather block stays under the 400-token budget", () => {
  const longTitle = "Quarterly planning session with the extended leadership group";
  const events = Array.from({ length: 60 }, (_, i) =>
    calendarEvent(
      `e${i}`,
      new Date(Date.parse("2026-07-31T04:00:00.000Z") + i * 3600_000).toISOString(),
      `${longTitle} ${i}`,
    ),
  );
  const weather: CurrentWeather = {
    temperatureC: 9,
    apparentC: 7,
    precipitationMm: 0,
    precipitationProbability: 62,
    windKmh: 44,
    weatherCode: 61,
    advice: ["rain", "wind"],
  };
  const block = formatSchedule(events, NOW, "America/Toronto");
  const total = estimateTokens(block) + estimateTokens(formatWeatherLine(weather));
  assert.ok(total < 400, `schedule+weather ≈${total} tokens`);
  assert.ok(formatWeatherLine(weather).includes("[advice: rain+wind]"));
});

test("the dynamic part carries the schedule and weather sections", () => {
  const parts = buildSystemPrompt(user("Boss"), [], [], {
    now: NOW,
    timezone: "America/Toronto",
    addressAllowed: true,
    events: [calendarEvent("a", "2026-07-31T19:00:00.000Z", "Dentist")],
    weather: {
      temperatureC: 12,
      apparentC: 10,
      precipitationMm: 0,
      precipitationProbability: 10,
      windKmh: 8,
      weatherCode: 1,
      advice: [],
    },
    plans: [],
  });
  assert.ok(parts.dynamic.includes("SCHEDULE (from the device calendar"));
  assert.ok(parts.dynamic.includes("Dentist"));
  assert.ok(parts.dynamic.includes("WEATHER NOW"));
  assert.ok(parts.dynamic.includes("12C feels 10C"));
});
