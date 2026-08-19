/**
 * The suppression gate, rule by rule — the pure half. Tick-level behavior
 * (priority contention, the farewell flow) is pinned in the tick suite.
 */
import { strict as assert } from "node:assert";
import { test } from "node:test";

import type { Automation } from "@otto/shared";

import type { DeliveryRecord } from "../src/automations/deliver.js";
import {
  DAILY_PUSH_CAP,
  deliveryPriority,
  disableNotice,
  isIgnoredStreak,
  isInQuietHours,
  localClock,
  readQuietHours,
  scheduledInsideQuiet,
  suppressionVerdict,
} from "../src/automations/suppress.js";

const NOW = new Date("2026-08-19T11:02:00.000Z"); // 07:02 New York
const TZ = "America/New_York";

function automation(overrides: Partial<Automation> = {}): Automation {
  return {
    id: "a1",
    ownerId: "u1",
    type: "morning_brief",
    label: "Morning brief",
    enabled: true,
    schedule: { kind: "fixed", rrule: "FREQ=DAILY", timeOfDay: "07:00" },
    timezone: TZ,
    action: { kind: "morning_brief", params: {} },
    lastRunAt: null,
    nextRunAt: "2026-08-19T11:00:00.000Z",
    lastResult: null,
    createdAt: "2026-08-01T00:00:00.000Z",
    ...overrides,
  };
}

function delivery(id: string, overrides: Partial<DeliveryRecord> = {}): DeliveryRecord {
  return {
    id,
    ownerId: "u1",
    automationId: "a1",
    automationType: "morning_brief",
    title: "…",
    body: "…",
    deepLink: "otto://brief",
    channel: "push",
    titleKey: null,
    openedAt: null,
    action: null,
    actionAt: null,
    createdAt: "2026-08-17T11:00:00.000Z", // two days ago: countable
    ...overrides,
  };
}

function verdictFor(
  overrides: Partial<Parameters<typeof suppressionVerdict>[0]> = {},
) {
  return suppressionVerdict({
    automation: automation(),
    now: NOW,
    quiet: { start: "22:00", end: "07:00" },
    automationDeliveries: [],
    ownerDeliveries: [],
    deliveredThisPass: 0,
    ...overrides,
  });
}

// ── Quiet hours ─────────────────────────────────────────────────────

test("quiet-hour windows: wrapping midnight, plain, and off", () => {
  const wrap = { start: "22:00", end: "07:00" };
  assert.ok(isInQuietHours("23:30", wrap));
  assert.ok(isInQuietHours("03:00", wrap));
  assert.ok(isInQuietHours("22:00", wrap), "start is inclusive");
  assert.ok(!isInQuietHours("07:00", wrap), "end is exclusive");
  assert.ok(!isInQuietHours("12:00", wrap));
  const plain = { start: "13:00", end: "14:00" };
  assert.ok(isInQuietHours("13:30", plain));
  assert.ok(!isInQuietHours("14:00", plain));
  assert.ok(!isInQuietHours("12:59", plain));
  assert.ok(!isInQuietHours("23:00", { start: "09:00", end: "09:00" }), "equal = disabled");
});

test("readQuietHours applies defaults for absent or malformed settings", () => {
  assert.deepEqual(readQuietHours(undefined), { start: "22:00", end: "07:00" });
  assert.deepEqual(readQuietHours({ quietHoursStart: "23:30", quietHoursEnd: "06:15" }), {
    start: "23:30",
    end: "06:15",
  });
  assert.deepEqual(readQuietHours({ quietHoursStart: "25:00", quietHoursEnd: "06:15" }), {
    start: "22:00",
    end: "07:00",
  });
  assert.deepEqual(readQuietHours({ quietHoursStart: "23:00" }), { start: "22:00", end: "07:00" });
});

test("localClock renders the automation's own wall time", () => {
  assert.equal(localClock(NOW, TZ), "07:02");
  assert.equal(localClock(NOW, "Asia/Tokyo"), "20:02");
});

test("only a FIXED schedule can be explicitly inside quiet hours", () => {
  const quiet = { start: "22:00", end: "07:30" };
  assert.ok(scheduledInsideQuiet(automation(), quiet), "07:00 sits inside 22:00–07:30");
  assert.ok(
    !scheduledInsideQuiet(
      automation({ schedule: { kind: "fixed", rrule: "FREQ=DAILY", timeOfDay: "08:00" } }),
      quiet,
    ),
  );
  assert.ok(
    !scheduledInsideQuiet(
      automation({
        schedule: { kind: "relative_to_event", minutesBefore: 30, eventFilter: {} },
      }),
      quiet,
    ),
  );
});

test("a quiet-hours fire suppresses even when the ignored streak is complete — no 2am farewells", () => {
  const ignored = [1, 2, 3, 4, 5].map((n) => delivery(`d${n}`));
  const verdict = verdictFor({
    quiet: { start: "06:00", end: "08:00" },
    automation: automation({
      schedule: { kind: "relative_to_event", minutesBefore: 30, eventFilter: {} },
    }),
    automationDeliveries: ignored,
  });
  assert.deepEqual(verdict, { kind: "suppress", reason: "quiet_hours" });
});

// ── The ignored streak ──────────────────────────────────────────────

test("five countable unengaged pushes disable; anything less does not", () => {
  const five = [1, 2, 3, 4, 5].map((n) => delivery(`d${n}`));
  assert.ok(isIgnoredStreak(five, NOW));
  assert.ok(!isIgnoredStreak(five.slice(1), NOW), "four is not five");
  const oneOpened = [delivery("d1", { openedAt: "2026-08-17T12:00:00.000Z" }), ...five.slice(1)];
  assert.ok(!isIgnoredStreak(oneOpened, NOW));
  const oneAnswered = [delivery("d1", { action: "dismissed" }), ...five.slice(1)];
  assert.ok(!isIgnoredStreak(oneAnswered, NOW), "'Not today' is an answer, not silence");
});

test("deliveries inside the 12-hour engagement window don't count yet", () => {
  const fresh = delivery("fresh", { createdAt: "2026-08-19T09:00:00.000Z" }); // 2h old
  const four = [1, 2, 3, 4].map((n) => delivery(`d${n}`));
  assert.ok(!isIgnoredStreak([fresh, ...four], NOW), "the fresh one is excluded, leaving four");
});

test("silent deliveries never count toward the streak", () => {
  const silent = [1, 2, 3, 4, 5].map((n) => delivery(`d${n}`, { channel: "silent" }));
  assert.ok(!isIgnoredStreak(silent, NOW));
});

test("the disable verdict carries the one farewell notice", () => {
  const ignored = [1, 2, 3, 4, 5].map((n) => delivery(`d${n}`));
  const verdict = verdictFor({ automationDeliveries: ignored });
  assert.equal(verdict.kind, "disable");
  if (verdict.kind === "disable") {
    assert.equal(verdict.notice, disableNotice(automation()));
    assert.ok(verdict.notice.split(/\s+/).length <= 60);
    assert.ok(!verdict.notice.includes("!"));
  }
});

// ── Already delivered today ─────────────────────────────────────────

test("one fire per occurrence, in the automation's own timezone", () => {
  const todayNY = delivery("d1", { createdAt: "2026-08-19T04:30:00.000Z" }); // 00:30 NY
  assert.deepEqual(verdictFor({ automationDeliveries: [todayNY] }), {
    kind: "suppress",
    reason: "already_delivered",
  });
  // The same instant is Aug 18 in New York terms? No — 04:30Z IS Aug 19
  // wall date 00:30. Yesterday's delivery does not block today.
  const yesterday = delivery("d1", { createdAt: "2026-08-19T03:59:00.000Z" }); // 23:59 Aug 18 NY
  assert.deepEqual(verdictFor({ automationDeliveries: [yesterday] }), { kind: "deliver" });
});

test("meeting prep is exempt from the daily dedupe — three meetings, three preps", () => {
  const prep = automation({
    id: "prep",
    type: "meeting_prep",
    schedule: { kind: "relative_to_event", minutesBefore: 30, eventFilter: { minAttendees: 2 } },
  });
  const earlier = delivery("d1", {
    automationId: "prep",
    automationType: "meeting_prep",
    createdAt: "2026-08-19T10:00:00.000Z",
  });
  assert.deepEqual(
    verdictFor({ automation: prep, automationDeliveries: [earlier] }),
    { kind: "deliver" },
  );
});

// ── Rate limit ──────────────────────────────────────────────────────

test("the daily cap counts today's pushes plus this pass's — silent ones are free", () => {
  const today = (id: string, channel: "push" | "silent" = "push") =>
    delivery(id, { automationId: "other", createdAt: "2026-08-19T09:00:00.000Z", channel });
  assert.deepEqual(
    verdictFor({ ownerDeliveries: [today("1"), today("2"), today("3"), today("4")] }),
    { kind: "suppress", reason: "rate_limited" },
  );
  assert.deepEqual(
    verdictFor({ ownerDeliveries: [today("1"), today("2"), today("3")], deliveredThisPass: 1 }),
    { kind: "suppress", reason: "rate_limited" },
  );
  assert.deepEqual(
    verdictFor({
      ownerDeliveries: [today("1"), today("2"), today("3"), today("4", "silent")],
    }),
    { kind: "deliver" },
  );
  assert.equal(DAILY_PUSH_CAP, 4);
});

// ── Priority ────────────────────────────────────────────────────────

test("priority: what expires first, then what the user explicitly created", () => {
  const order = [
    "meeting_prep",
    "custom",
    "morning_brief",
    "plan_checkin",
    "evening_shutdown",
    "weekly_review",
  ].map((type) => deliveryPriority(automation({ type: type as Automation["type"] })));
  assert.deepEqual([...order].sort((a, b) => a - b), order, "declared order is priority order");
  assert.equal(new Set(order).size, order.length);
});
