/**
 * The tick choreography, driven through injected deps — claim races,
 * handler failure posture, stale-fire suppression, schedule advancement —
 * plus the pure claim predicate and the scheduler-invoker auth checks.
 */
import { strict as assert } from "node:assert";
import { test } from "node:test";

import type { Automation } from "@otto/shared";

import type { CalendarView } from "../src/automations/calendarView.js";
import type { AutomationDelivery, DeliveryRecord } from "../src/automations/deliver.js";
import { evaluateClaim, type RunCompletion } from "../src/automations/store.js";
import {
  MAX_PER_TICK,
  completionFor,
  isStaleFire,
  runTick,
  type TickDeps,
  type TickSummary,
} from "../src/automations/tick.js";
import { isAuthorizedInvoker, schedulerConfig } from "../src/routes/automations.js";

const NOW = new Date("2026-08-19T11:02:00.000Z"); // 07:02 in New York

function automation(id: string, overrides: Partial<Automation> = {}): Automation {
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
    nextRunAt: "2026-08-19T11:00:00.000Z", // today's 07:00, two minutes ago
    lastResult: null,
    createdAt: "2026-08-01T00:00:00.000Z",
    ...overrides,
  };
}

interface Journal {
  executed: string[];
  completed: Map<string, RunCompletion>;
  notices: { automationId: string; delivery: AutomationDelivery }[];
  disabled: string[];
}

function makeDeps(
  due: Automation[],
  options: {
    claimDenied?: Set<string>;
    execute?: TickDeps["execute"];
    view?: CalendarView | null;
    quiet?: { start: string; end: string };
    ownerDeliveries?: DeliveryRecord[];
    automationDeliveries?: Map<string, DeliveryRecord[]>;
  } = {},
): { deps: TickDeps; journal: Journal } {
  const journal: Journal = { executed: [], completed: new Map(), notices: [], disabled: [] };
  const deps: TickDeps = {
    now: () => NOW,
    loadDue: (_now, limit) => {
      assert.equal(limit, MAX_PER_TICK);
      return Promise.resolve(due);
    },
    claim: (id) =>
      Promise.resolve(
        options.claimDenied?.has(id) === true
          ? null
          : (due.find((entry) => entry.id === id) ?? null),
      ),
    complete: (id, completion) => {
      journal.completed.set(id, completion);
      return Promise.resolve();
    },
    execute:
      options.execute ??
      ((candidate) => {
        journal.executed.push(candidate.id);
        return Promise.resolve("delivered" as const);
      }),
    loadView: () => Promise.resolve(options.view ?? null),
    purgeViews: () => Promise.resolve(0),
    loadQuietHours: () => Promise.resolve(options.quiet ?? { start: "22:00", end: "07:00" }),
    loadOwnerDeliveries: () => Promise.resolve(options.ownerDeliveries ?? []),
    loadAutomationDeliveries: (_ownerId, automationId) =>
      Promise.resolve(options.automationDeliveries?.get(automationId) ?? []),
    notify: (_uid, automation, delivery) => {
      journal.notices.push({ automationId: automation.id, delivery });
      return Promise.resolve();
    },
    disable: (id) => {
      journal.disabled.push(id);
      return Promise.resolve();
    },
  };
  return { deps, journal };
}

function summaryOf(overrides: Partial<TickSummary>): TickSummary {
  return {
    due: 0,
    claimed: 0,
    delivered: 0,
    suppressed: 0,
    failed: 0,
    stale: 0,
    noCalendar: 0,
    quietHours: 0,
    alreadyDelivered: 0,
    rateLimited: 0,
    autoDisabled: 0,
    purgedViews: 0,
    ...overrides,
  };
}

function pastDelivery(
  id: string,
  automationId: string,
  overrides: Partial<DeliveryRecord> = {},
): DeliveryRecord {
  return {
    id,
    ownerId: "u1",
    automationId,
    automationType: "morning_brief",
    title: "…",
    body: "…",
    deepLink: "otto://brief",
    channel: "push",
    titleKey: null,
    openedAt: null,
    action: null,
    actionAt: null,
    createdAt: "2026-08-18T11:00:00.000Z", // yesterday — no daily-cap effect
    ...overrides,
  };
}

test("a due automation is claimed, executed, and advanced to tomorrow's occurrence", async () => {
  const { deps, journal } = makeDeps([automation("a1")]);
  const summary = await runTick(deps);
  assert.deepEqual(summary, summaryOf({ due: 1, claimed: 1, delivered: 1 }));
  assert.deepEqual(journal.executed, ["a1"]);
  const completion = journal.completed.get("a1");
  assert.equal(completion?.lastResult, "delivered");
  assert.equal(completion?.lastRunAt, NOW.toISOString());
  // Recomputed in the owner's zone strictly after now: tomorrow 07:00 EDT.
  assert.equal(completion?.nextRunAt, "2026-08-20T11:00:00.000Z");
});

test("losing the claim race skips the automation entirely — no execute, no write", async () => {
  const { deps, journal } = makeDeps([automation("a1"), automation("a2")], {
    claimDenied: new Set(["a1"]),
  });
  const summary = await runTick(deps);
  assert.equal(summary.claimed, 1);
  assert.deepEqual(journal.executed, ["a2"]);
  assert.equal(journal.completed.has("a1"), false);
});

test("a handler throw records 'failed', delivers nothing, and still advances the schedule", async () => {
  const { deps, journal } = makeDeps([automation("a1")], {
    execute: () => Promise.reject(new Error("model exploded")),
  });
  const summary = await runTick(deps);
  assert.deepEqual(summary, summaryOf({ due: 1, claimed: 1, failed: 1 }));
  const completion = journal.completed.get("a1");
  assert.equal(completion?.lastResult, "failed");
  // Failure must not spin: the next attempt is the next occurrence, not
  // the next tick.
  assert.equal(completion?.nextRunAt, "2026-08-20T11:00:00.000Z");
});

test("a fire more than an hour past its moment is suppressed WITHOUT running the handler", async () => {
  const { deps, journal } = makeDeps([
    automation("a1", { nextRunAt: "2026-08-19T05:00:00.000Z" }), // six hours late
  ]);
  const summary = await runTick(deps);
  assert.deepEqual(summary, summaryOf({ due: 1, claimed: 1, suppressed: 1, stale: 1 }));
  assert.deepEqual(journal.executed, []);
  assert.equal(journal.completed.get("a1")?.lastResult, "suppressed");
});

test("a slightly late fire (inside the grace window) runs normally", async () => {
  const { deps, journal } = makeDeps([
    automation("a1", { nextRunAt: "2026-08-19T10:30:00.000Z" }), // 32 minutes late
  ]);
  const summary = await runTick(deps);
  assert.equal(summary.delivered, 1);
  assert.deepEqual(journal.executed, ["a1"]);
});

test("a relative_to_event automation parks with nextRunAt null until the calendar re-arms it", async () => {
  const { deps, journal } = makeDeps([
    automation("a1", {
      type: "meeting_prep",
      schedule: { kind: "relative_to_event", minutesBefore: 30, eventFilter: { minAttendees: 2 } },
      action: { kind: "meeting_prep", params: {} },
    }),
  ]);
  await runTick(deps);
  assert.equal(journal.completed.get("a1")?.nextRunAt, null);
});

test("a completion-write failure abandons that automation but not the rest of the pass", async () => {
  const first = automation("a1");
  const second = automation("a2");
  const { deps, journal } = makeDeps([first, second]);
  const complete = deps.complete;
  deps.complete = (id, completion) =>
    id === "a1" ? Promise.reject(new Error("firestore hiccup")) : complete(id, completion);
  const summary = await runTick(deps);
  assert.equal(summary.claimed, 2);
  assert.deepEqual(journal.executed, ["a1", "a2"]);
  assert.ok(journal.completed.has("a2"));
});

test("isStaleFire: null is never stale, garbage is always stale", () => {
  assert.equal(isStaleFire(null, NOW), false);
  assert.equal(isStaleFire("not a date", NOW), true);
  assert.equal(isStaleFire("2026-08-19T10:30:00.000Z", NOW), false);
  assert.equal(isStaleFire("2026-08-19T09:00:00.000Z", NOW), true);
});

test("completionFor stamps the run and recomputes from the rule in-zone", () => {
  const completion = completionFor(automation("a1"), "suppressed", NOW);
  assert.deepEqual(completion, {
    lastRunAt: "2026-08-19T11:02:00.000Z",
    lastResult: "suppressed",
    nextRunAt: "2026-08-20T11:00:00.000Z",
  });
});

function meetingPrep(id: string, overrides: Partial<Automation> = {}): Automation {
  return automation(id, {
    type: "meeting_prep",
    schedule: { kind: "relative_to_event", minutesBefore: 30, eventFilter: { minAttendees: 2 } },
    action: { kind: "meeting_prep", params: {} },
    ...overrides,
  });
}

const FRESH_VIEW: CalendarView = {
  events: [
    {
      id: "evt-1",
      title: "Henderson review",
      startsAt: "2026-08-19T11:30:00.000Z", // fires again at 11:00 — in the past now
      endsAt: "2026-08-19T12:00:00.000Z",
      attendeeCount: 3,
    },
    {
      id: "evt-2",
      title: "Design sync",
      startsAt: "2026-08-19T15:00:00.000Z",
      endsAt: "2026-08-19T16:00:00.000Z",
      attendeeCount: 4,
    },
  ],
  syncedAt: "2026-08-19T10:00:00.000Z",
  timezone: "America/New_York",
  stale: false,
};

test("a calendar-dependent automation with NO synced view is suppressed without executing", async () => {
  const { deps, journal } = makeDeps([meetingPrep("m1")], { view: null });
  const summary = await runTick(deps);
  assert.deepEqual(summary, summaryOf({ due: 1, claimed: 1, suppressed: 1, noCalendar: 1 }));
  assert.deepEqual(journal.executed, []);
});

test("a calendar-dependent automation with a STALE view (>24h) is suppressed without executing", async () => {
  const { deps, journal } = makeDeps([meetingPrep("m1")], {
    view: { ...FRESH_VIEW, stale: true },
  });
  const summary = await runTick(deps);
  assert.equal(summary.noCalendar, 1);
  assert.deepEqual(journal.executed, []);
});

test("with a fresh view the prep runs, sees the calendar, and re-arms on the NEXT meeting only", async () => {
  let seenEvents = 0;
  const { deps, journal } = makeDeps([meetingPrep("m1")], {
    view: FRESH_VIEW,
    execute: (_automation, ctx) => {
      seenEvents = ctx.calendar?.events.length ?? 0;
      return Promise.resolve("delivered" as const);
    },
  });
  const summary = await runTick(deps);
  assert.equal(summary.delivered, 1);
  assert.equal(seenEvents, 2);
  // The 11:30 meeting's fire instant (11:00) is behind us — strictly-after
  // re-arms on the 15:00 meeting (14:30), never re-prepping the same one.
  assert.equal(journal.completed.get("m1")?.nextRunAt, "2026-08-19T14:30:00.000Z");
});

test("a fixed automation runs fine with no calendar at all — only relative ones depend on it", async () => {
  const { deps, journal } = makeDeps([automation("a1")], { view: null });
  const summary = await runTick(deps);
  assert.equal(summary.delivered, 1);
  assert.deepEqual(journal.executed, ["a1"]);
});

// ── The suppression gate at tick level ──────────────────────────────

test("ACCEPTANCE #6: six due automations, only four deliver — priority decides which", async () => {
  const due = [
    automation("weekly", { type: "weekly_review", action: { kind: "weekly_review", params: {} } }),
    automation("evening", { type: "evening_shutdown", action: { kind: "evening_shutdown", params: {} } }),
    automation("brief", { type: "morning_brief", action: { kind: "morning_brief", params: {} } }),
    automation("checkin", { type: "plan_checkin", action: { kind: "plan_checkin", params: {} } }),
    automation("custom", { type: "custom", action: { kind: "custom", params: {} } }),
    meetingPrep("prep"),
  ];
  const { deps, journal } = makeDeps(due, { view: FRESH_VIEW });
  const summary = await runTick(deps);
  assert.equal(summary.delivered, 4);
  assert.equal(summary.rateLimited, 2);
  // Priority order: what expires first, then what the user created.
  assert.deepEqual(journal.executed, ["prep", "custom", "brief", "checkin"]);
});

test("pushes already delivered TODAY count against the cap; yesterday's do not", async () => {
  const todays = [1, 2, 3].map((n) =>
    pastDelivery(`t${n}`, "other", { createdAt: "2026-08-19T10:0" + String(n) + ":00.000Z" }),
  );
  const { deps } = makeDeps([automation("a1"), automation("a2", { type: "evening_shutdown" })], {
    ownerDeliveries: [...todays, pastDelivery("old", "other")],
  });
  const summary = await runTick(deps);
  // 3 already today + 1 delivered this pass = 4; the second due automation
  // hits the cap.
  assert.equal(summary.delivered, 1);
  assert.equal(summary.rateLimited, 1);
});

test("quiet hours swallow the push — unless the automation was scheduled inside them", async () => {
  // NOW is 07:02 New York; this user's quiet hours run 06:00–08:00.
  // Meeting prep is event-driven — never "explicitly scheduled inside" —
  // so it stays silent; the 07:00 fixed schedule was put there by the
  // user and delivers.
  const prep = meetingPrep("prep");
  const scheduledInside = automation("a2");
  const { deps, journal } = makeDeps([prep, scheduledInside], {
    quiet: { start: "06:00", end: "08:00" },
    view: FRESH_VIEW,
  });
  const summary = await runTick(deps);
  assert.equal(summary.quietHours, 1);
  assert.deepEqual(journal.executed, ["a2"], "the explicitly-inside schedule delivers");
});

test("a fixed automation that already delivered today stays quiet — except after a snooze", async () => {
  const deliveredToday = pastDelivery("d1", "a1", { createdAt: "2026-08-19T10:30:00.000Z" });
  const first = makeDeps([automation("a1")], {
    automationDeliveries: new Map([["a1", [deliveredToday]]]),
  });
  const firstSummary = await runTick(first.deps);
  assert.equal(firstSummary.alreadyDelivered, 1);
  assert.deepEqual(first.journal.executed, []);

  const snoozed = { ...deliveredToday, action: "snoozed", actionAt: "2026-08-19T10:35:00.000Z" };
  const second = makeDeps([automation("a1")], {
    automationDeliveries: new Map([["a1", [snoozed]]]),
  });
  const secondSummary = await runTick(second.deps);
  assert.equal(secondSummary.delivered, 1, "the snoozed re-fire is the user's own request");
});

test("five unengaged deliveries in a row: one farewell notice, then the automation turns off", async () => {
  const ignored = [1, 2, 3, 4, 5].map((n) => pastDelivery(`d${n}`, "a1"));
  const { deps, journal } = makeDeps([automation("a1")], {
    automationDeliveries: new Map([["a1", ignored]]),
  });
  const summary = await runTick(deps);
  assert.equal(summary.autoDisabled, 1);
  assert.deepEqual(journal.executed, [], "the handler never runs");
  assert.deepEqual(journal.disabled, ["a1"]);
  assert.equal(journal.notices.length, 1);
  assert.match(journal.notices[0]?.delivery.body ?? "", /paused/);
  assert.match(journal.notices[0]?.delivery.body ?? "", /unanswered/);
  // The completion still records the run; the disable happens after it.
  assert.equal(journal.completed.get("a1")?.lastResult, "suppressed");
});

test("one engaged delivery breaks the streak", async () => {
  const four = [1, 2, 3, 4].map((n) => pastDelivery(`d${n}`, "a1"));
  const engaged = pastDelivery("d5", "a1", { openedAt: "2026-08-18T12:00:00.000Z" });
  const { deps, journal } = makeDeps([automation("a1")], {
    automationDeliveries: new Map([["a1", [...four, engaged]]]),
  });
  const summary = await runTick(deps);
  assert.equal(summary.autoDisabled, 0);
  assert.deepEqual(journal.executed, ["a1"]);
});

// ── evaluateClaim: the transactional predicate, pure ────────────────

test("evaluateClaim accepts a due, enabled, unlocked automation", () => {
  assert.equal(evaluateClaim(automation("a1"), NOW)?.id, "a1");
  // An expired lock is no lock.
  assert.equal(
    evaluateClaim({ ...automation("a1"), lockedUntil: "2026-08-19T11:01:00.000Z" }, NOW)?.id,
    "a1",
  );
});

test("evaluateClaim rejects everything else", () => {
  assert.equal(evaluateClaim({ nonsense: true }, NOW), null);
  assert.equal(evaluateClaim(automation("a1", { enabled: false }), NOW), null);
  assert.equal(evaluateClaim(automation("a1", { nextRunAt: null }), NOW), null);
  assert.equal(
    evaluateClaim(automation("a1", { nextRunAt: "2026-08-19T11:05:00.000Z" }), NOW),
    null,
    "not due yet",
  );
  assert.equal(
    evaluateClaim({ ...automation("a1"), lockedUntil: "2026-08-19T11:03:30.000Z" }, NOW),
    null,
    "held by a live lock",
  );
});

// ── Scheduler invoker auth ──────────────────────────────────────────

test("schedulerConfig requires both env vars — half-configured fails closed", () => {
  assert.equal(schedulerConfig({}), null);
  assert.equal(schedulerConfig({ SCHEDULER_INVOKER: "sa@p.iam.gserviceaccount.com" }), null);
  assert.equal(schedulerConfig({ SCHEDULER_AUDIENCE: "https://api/automations/tick" }), null);
  assert.deepEqual(
    schedulerConfig({
      SCHEDULER_INVOKER: "sa@p.iam.gserviceaccount.com",
      SCHEDULER_AUDIENCE: "https://api/automations/tick",
    }),
    { invoker: "sa@p.iam.gserviceaccount.com", audience: "https://api/automations/tick" },
  );
});

test("only the configured invoker's VERIFIED email is authorized", () => {
  const config = {
    invoker: "sa@p.iam.gserviceaccount.com",
    audience: "https://api/automations/tick",
  };
  const payload = (overrides: Record<string, unknown>) =>
    ({
      iss: "https://accounts.google.com",
      sub: "123",
      aud: config.audience,
      iat: 0,
      exp: 0,
      ...overrides,
    }) as never;
  assert.equal(
    isAuthorizedInvoker(payload({ email: config.invoker, email_verified: true }), config),
    true,
  );
  assert.equal(
    isAuthorizedInvoker(payload({ email: "other@p.iam.gserviceaccount.com", email_verified: true }), config),
    false,
  );
  assert.equal(
    isAuthorizedInvoker(payload({ email: config.invoker, email_verified: false }), config),
    false,
  );
  assert.equal(isAuthorizedInvoker(payload({}), config), false);
  assert.equal(isAuthorizedInvoker(undefined, config), false);
});
