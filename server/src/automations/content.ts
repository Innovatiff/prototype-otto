/**
 * The deterministic halves of the built-in handlers: fact extraction and
 * every suppress/send DECISION. Models phrase; they never decide. Anything
 * that decides whether Otto speaks at all lives here, pure and tested.
 */
import type {
  CalendarSyncEvent,
  Plan,
  PlanProgressSummary,
  SessionRecord,
  Task,
} from "@otto/shared";

import { fireInstant } from "../brief/gather.js";
import { wallDate, wallTime } from "../util/time.js";

// ── Small shared pieces ─────────────────────────────────────────────

const NUMBER_WORDS = [
  "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
];

/** "three" for 3; digits beyond ten. */
export function numberWord(n: number): string {
  return NUMBER_WORDS[n] ?? String(n);
}

function capitalize(text: string): string {
  return text.length === 0 ? text : text.charAt(0).toUpperCase() + text.slice(1);
}

/** "9 degrees." / "-3 degrees and likely rain." — never "-0". */
export function weatherLine(weather: {
  temperatureC: number;
  precipitationProbability: number;
}): string {
  const rounded = Math.round(weather.temperatureC);
  const degrees = rounded === 0 ? 0 : rounded;
  const rain = weather.precipitationProbability >= 50 ? " and likely rain." : ".";
  return `${degrees} degrees${rain}`;
}

/** Active reminders whose fire instant has already passed — "slipped". */
export function slippedReminders(tasks: readonly Task[], now: Date): Task[] {
  const nowIso = now.toISOString();
  return tasks.filter((task) => {
    if (task.status !== "active") {
      return false;
    }
    const at = fireInstant(task);
    return at !== null && at < nowIso;
  });
}

/** Only the events whose start falls on `date` (a wall date in `timezone`). */
export function eventsOnDate(
  events: readonly CalendarSyncEvent[],
  timezone: string,
  date: string,
): CalendarSyncEvent[] {
  return events.filter((event) => wallDate(new Date(event.startsAt), timezone) === date);
}

// ── Morning brief: overlap detection + the deterministic push body ──

export interface SyncOverlap {
  readonly a: CalendarSyncEvent;
  readonly b: CalendarSyncEvent;
  readonly minutes: number;
}

/**
 * Timed events sharing time, adjacent-or-not — the same overlap rule the
 * iOS conflict detector applies, over the synced view.
 */
export function overlapsIn(events: readonly CalendarSyncEvent[]): SyncOverlap[] {
  const timed = [...events]
    .filter((event) => Date.parse(event.endsAt) > Date.parse(event.startsAt))
    .sort((a, b) => a.startsAt.localeCompare(b.startsAt));
  const found: SyncOverlap[] = [];
  for (let i = 0; i < timed.length; i += 1) {
    for (let j = i + 1; j < timed.length; j += 1) {
      const a = timed[i]!;
      const b = timed[j]!;
      if (a.startsAt < b.endsAt && b.startsAt < a.endsAt) {
        const overlapMs =
          Math.min(Date.parse(a.endsAt), Date.parse(b.endsAt)) -
          Math.max(Date.parse(a.startsAt), Date.parse(b.startsAt));
        found.push({ a, b, minutes: Math.max(1, Math.ceil(overlapMs / 60_000)) });
      }
    }
  }
  return found;
}

export interface BriefPushFacts {
  readonly weatherLine: string | null;
  readonly todayEvents: readonly CalendarSyncEvent[];
  readonly overlaps: readonly SyncOverlap[];
  readonly dueCount: number;
  readonly timezone: string;
}

/**
 * The push body, deterministic: weather, the first problem, the first
 * commitment, the reminder count. Useful with the phone still locked.
 * Empty when the morning genuinely holds nothing.
 */
export function briefPushBody(facts: BriefPushFacts, now: Date): string {
  const parts: string[] = [];
  if (facts.weatherLine !== null) {
    parts.push(facts.weatherLine);
  }
  const overlap = facts.overlaps[0];
  if (overlap !== undefined) {
    parts.push(
      `${overlap.a.title} at ${wallTime(overlap.a.startsAt, facts.timezone)} overlaps ` +
        `${overlap.b.title} at ${wallTime(overlap.b.startsAt, facts.timezone)}.`,
    );
  }
  const nowIso = now.toISOString();
  const nextEvent = facts.todayEvents.find(
    (event) => event.startsAt > nowIso && !involvedInOverlap(event, overlap),
  );
  if (nextEvent !== undefined) {
    parts.push(`First up: ${nextEvent.title} at ${wallTime(nextEvent.startsAt, facts.timezone)}.`);
  }
  if (facts.dueCount > 0) {
    const plural = facts.dueCount === 1 ? "reminder" : "reminders";
    parts.push(`${capitalize(numberWord(facts.dueCount))} ${plural} due today.`);
  }
  return parts.join(" ");
}

function involvedInOverlap(event: CalendarSyncEvent, overlap: SyncOverlap | undefined): boolean {
  return overlap !== undefined && (overlap.a.id === event.id || overlap.b.id === event.id);
}

// ── Evening shutdown ────────────────────────────────────────────────

export interface EveningFacts {
  readonly tomorrowEvents: readonly { title: string; time: string; location: string | null }[];
  readonly slipped: readonly string[];
  readonly dueTomorrow: readonly { title: string; time: string }[];
}

export function eveningFacts(
  events: readonly CalendarSyncEvent[],
  tasks: readonly Task[],
  now: Date,
  timezone: string,
): EveningFacts {
  const tomorrow = wallDate(new Date(now.getTime() + 24 * 3600 * 1000), timezone);
  const tomorrowEvents = events
    .filter((event) => wallDate(new Date(event.startsAt), timezone) === tomorrow)
    .sort((a, b) => a.startsAt.localeCompare(b.startsAt))
    .slice(0, 3)
    .map((event) => ({
      title: event.title,
      time: wallTime(event.startsAt, timezone),
      location: event.location ?? null,
    }));
  const dueTomorrow = tasks
    .flatMap((task) => {
      const at = fireInstant(task);
      if (task.status !== "active" || at === null) {
        return [];
      }
      return wallDate(new Date(at), timezone) === tomorrow
        ? [{ title: task.title, time: wallTime(at, timezone), at }]
        : [];
    })
    .sort((a, b) => a.at.localeCompare(b.at))
    .slice(0, 5)
    .map(({ title, time }) => ({ title, time }));
  return {
    tomorrowEvents,
    slipped: slippedReminders(tasks, now).map((task) => task.title).slice(0, 5),
    dueTomorrow,
  };
}

/** Nothing ahead, nothing slipped: say NOTHING (acceptance #4). */
export function hasEveningContent(facts: EveningFacts): boolean {
  return (
    facts.tomorrowEvents.length > 0 || facts.slipped.length > 0 || facts.dueTomorrow.length > 0
  );
}

export function serializeEveningFacts(facts: EveningFacts): string {
  const lines: string[] = [];
  lines.push("TOMORROW'S EVENTS:");
  if (facts.tomorrowEvents.length === 0) {
    lines.push("- (none)");
  }
  for (const event of facts.tomorrowEvents) {
    const where = event.location !== null ? ` @ ${event.location}` : "";
    lines.push(`- ${event.time} ${event.title}${where}`);
  }
  if (facts.dueTomorrow.length > 0) {
    lines.push("REMINDERS DUE TOMORROW:");
    for (const due of facts.dueTomorrow) {
      lines.push(`- ${due.title} at ${due.time}`);
    }
  }
  if (facts.slipped.length > 0) {
    lines.push("PAST DUE (still open):");
    for (const title of facts.slipped) {
      lines.push(`- ${title}`);
    }
  }
  return lines.join("\n");
}

// ── Meeting prep ────────────────────────────────────────────────────

/**
 * The meeting this fire is FOR: the earliest filter-matching event whose
 * start is still ahead but within the prep window (plus slop for tick
 * granularity). Null means it moved or vanished — silence, not a guess.
 */
export function resolveUpcomingMeeting(
  events: readonly CalendarSyncEvent[],
  filter: { minAttendees?: number; keywords?: string[] },
  minutesBefore: number,
  now: Date,
): CalendarSyncEvent | null {
  const nowMs = now.getTime();
  const horizonMs = nowMs + (minutesBefore + 10) * 60_000;
  const candidates = events
    .filter((event) => {
      if (filter.minAttendees !== undefined && event.attendeeCount < filter.minAttendees) {
        return false;
      }
      if (filter.keywords !== undefined && filter.keywords.length > 0) {
        const title = event.title.toLowerCase();
        if (!filter.keywords.some((keyword) => title.includes(keyword.toLowerCase()))) {
          return false;
        }
      }
      const startMs = Date.parse(event.startsAt);
      return startMs > nowMs && startMs <= horizonMs;
    })
    .sort((a, b) => a.startsAt.localeCompare(b.startsAt));
  return candidates[0] ?? null;
}

/** Open tasks that plausibly concern the meeting, by shared meaty words. */
export function tasksMatchingTitle(tasks: readonly Task[], title: string): Task[] {
  const meaty = new Set(
    title
      .toLowerCase()
      .split(/[^a-z0-9]+/)
      .filter((word) => word.length >= 4),
  );
  if (meaty.size === 0) {
    return [];
  }
  return tasks
    .filter((task) => task.status === "active")
    .filter((task) =>
      task.title
        .toLowerCase()
        .split(/[^a-z0-9]+/)
        .some((word) => meaty.has(word)),
    )
    .slice(0, 5);
}

// ── Weekly review ───────────────────────────────────────────────────

export interface WeeklyFacts {
  readonly planLines: readonly string[];
  readonly slipped: readonly string[];
  readonly aheadEvents: readonly { title: string; time: string }[];
}

export function weeklyFacts(
  plans: readonly { plan: Plan; summary: PlanProgressSummary }[],
  tasks: readonly Task[],
  events: readonly CalendarSyncEvent[],
  now: Date,
  timezone: string,
): WeeklyFacts {
  const planLines = plans.map(({ plan, summary }) => {
    const attended = summary.records;
    const scheduled = summary.scheduledToDate;
    const missedWeek = summary.missedThisWeek;
    return (
      `${plan.meta.domain}: ${attended} of ${scheduled} scheduled sessions done overall, ` +
      `${missedWeek} missed this week`
    );
  });
  const aheadEvents = events
    .filter((event) => event.startsAt > now.toISOString())
    .sort((a, b) => a.startsAt.localeCompare(b.startsAt))
    .slice(0, 3)
    .map((event) => ({
      title: event.title,
      time: `${wallDate(new Date(event.startsAt), timezone)} ${wallTime(event.startsAt, timezone)}`,
    }));
  return {
    planLines,
    slipped: slippedReminders(tasks, now).map((task) => task.title).slice(0, 5),
    aheadEvents,
  };
}

export function hasWeeklyContent(facts: WeeklyFacts): boolean {
  return facts.planLines.length > 0 || facts.slipped.length > 0 || facts.aheadEvents.length > 0;
}

export function serializeWeeklyFacts(facts: WeeklyFacts): string {
  const lines: string[] = [];
  if (facts.planLines.length > 0) {
    lines.push("PLAN ADHERENCE (from real session records):");
    for (const line of facts.planLines) {
      lines.push(`- ${line}`);
    }
  }
  if (facts.slipped.length > 0) {
    lines.push("SLIPPED (past due, still open):");
    for (const title of facts.slipped) {
      lines.push(`- ${title}`);
    }
  }
  if (facts.aheadEvents.length > 0) {
    lines.push("COMING UP (next 48h only — the synced window):");
    for (const event of facts.aheadEvents) {
      lines.push(`- ${event.time} ${event.title}`);
    }
  }
  return lines.join("\n");
}

// ── Plan check-in: fully deterministic ──────────────────────────────

/**
 * Consecutive COMPLETE weeks (ending at the most recent complete one) in
 * which every scheduled session has a record. Weeks with nothing scheduled
 * neither count nor break the streak.
 */
export function cleanWeekStreak(plan: Plan, records: readonly SessionRecord[], now: Date): number {
  const startMs = new Date(plan.createdAt).getTime();
  const elapsedDays = Math.floor((now.getTime() - startMs) / 86_400_000);
  const completeWeeks = Math.floor(elapsedDays / 7);
  let streak = 0;
  for (let week = completeWeeks - 1; week >= 0; week -= 1) {
    const scheduled = plan.schedule.filter(
      (entry) => entry.dayOffset >= week * 7 && entry.dayOffset < (week + 1) * 7,
    ).length;
    if (scheduled === 0) {
      continue;
    }
    const weekStartMs = startMs + week * 7 * 86_400_000;
    const weekEndMs = weekStartMs + 7 * 86_400_000;
    const attended = records.filter((record) => {
      const at = new Date(record.completedAt).getTime();
      return at >= weekStartMs && at < weekEndMs;
    }).length;
    if (attended >= scheduled) {
      streak += 1;
    } else {
      break;
    }
  }
  return streak;
}

export interface PlanCheckinInput {
  readonly plan: Plan;
  readonly summary: PlanProgressSummary;
  readonly streakWeeks: number;
}

export interface PlanCheckinMessage {
  readonly planId: string;
  readonly body: string;
}

/**
 * The whole check-in decision, deterministic:
 *   - 2+ missed this week -> offer a reshape or a clean Monday reset.
 *   - 3+ clean weeks -> praise with the SPECIFIC number, nothing generic.
 *   - anything else -> null. DO NOT SEND.
 * With several plans, the one that needs help outranks the one going well.
 */
export function planCheckinMessage(inputs: readonly PlanCheckinInput[]): PlanCheckinMessage | null {
  const struggling = [...inputs]
    .filter((input) => input.summary.missedThisWeek >= 2)
    .sort((a, b) => b.summary.missedThisWeek - a.summary.missedThisWeek)[0];
  if (struggling !== undefined) {
    const missed = struggling.summary.missedThisWeek;
    const domain = struggling.plan.meta.domain;
    return {
      planId: struggling.plan.id,
      body:
        `You've missed ${numberWord(missed)} ${domain} sessions this week. ` +
        "Want me to reshape the plan, or reset it clean starting Monday?",
    };
  }
  const thriving = [...inputs]
    .filter((input) => input.streakWeeks >= 3)
    .sort((a, b) => b.streakWeeks - a.streakWeeks)[0];
  if (thriving !== undefined) {
    const weeks = capitalize(numberWord(thriving.streakWeeks));
    return {
      planId: thriving.plan.id,
      body: `${weeks} weeks without missing a session. The ${thriving.plan.meta.domain} plan holds.`,
    };
  }
  return null;
}
