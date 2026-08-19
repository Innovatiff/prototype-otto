/**
 * When does an automation fire next?
 *
 * All wall-clock math goes through luxon — never UTC-offset arithmetic — and
 * the next instant is recomputed from the rule IN THE USER'S IANA ZONE on
 * every run, so a DST transition (or the user flying to Tokyo) can never
 * drift a 07:00 brief off 07:00.
 *
 * The recurrence grammar is a deliberately strict RRULE subset:
 *
 *     FREQ=DAILY
 *     FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR
 *
 * That covers every built-in and everything Step 4 parses from voice
 * ("every Friday" -> FREQ=WEEKLY;BYDAY=FR). The rrule npm package is
 * deliberately NOT used: its timezone support layers a tzid option over
 * UTC-internal math with documented DST pitfalls — the exact bug class this
 * module exists to make impossible. Anything outside the subset (MONTHLY,
 * INTERVAL>1, UNTIL, COUNT) is rejected loudly at parse time rather than
 * silently misfiring for months.
 */
import type {
  AutomationEventFilter,
  AutomationSchedule,
  CalendarSyncEvent,
} from "@otto/shared";
import { DateTime, IANAZone } from "luxon";

/** luxon weekday numbers: 1 = Monday ... 7 = Sunday. */
const BYDAY_TO_WEEKDAY: Readonly<Record<string, number>> = {
  MO: 1,
  TU: 2,
  WE: 3,
  TH: 4,
  FR: 5,
  SA: 6,
  SU: 7,
};

export type Recurrence =
  | { readonly freq: "daily" }
  | { readonly freq: "weekly"; readonly weekdays: ReadonlySet<number> };

/**
 * Parses the supported RRULE subset, or null for anything outside it —
 * including params this module would otherwise silently ignore. Creation
 * paths must treat null as a hard validation error.
 */
export function parseRecurrence(rrule: string): Recurrence | null {
  const params = new Map<string, string>();
  for (const part of rrule.trim().split(";")) {
    if (part.length === 0) {
      return null;
    }
    const eq = part.indexOf("=");
    if (eq <= 0) {
      return null;
    }
    const key = part.slice(0, eq).toUpperCase();
    if (params.has(key)) {
      return null;
    }
    params.set(key, part.slice(eq + 1));
  }

  const freq = params.get("FREQ");
  if (freq === undefined) {
    return null;
  }
  // INTERVAL=1 is the only interval; anything else changes the meaning of
  // the rule and must not be accepted-but-ignored.
  const interval = params.get("INTERVAL");
  if (interval !== undefined && interval !== "1") {
    return null;
  }
  const known = new Set(["FREQ", "INTERVAL", "BYDAY"]);
  for (const key of params.keys()) {
    if (!known.has(key)) {
      return null;
    }
  }

  if (freq.toUpperCase() === "DAILY") {
    if (params.has("BYDAY")) {
      return null;
    }
    return { freq: "daily" };
  }

  if (freq.toUpperCase() === "WEEKLY") {
    const byday = params.get("BYDAY");
    if (byday === undefined || byday.length === 0) {
      return null;
    }
    const weekdays = new Set<number>();
    for (const token of byday.split(",")) {
      const weekday = BYDAY_TO_WEEKDAY[token.toUpperCase()];
      if (weekday === undefined) {
        return null;
      }
      weekdays.add(weekday);
    }
    return { freq: "weekly", weekdays };
  }

  return null;
}

export function isValidTimezone(timezone: string): boolean {
  return IANAZone.isValidZone(timezone);
}

/** "HH:mm" -> {hour, minute}, or null. Mirrors the shared schema's regex. */
function parseTimeOfDay(timeOfDay: string): { hour: number; minute: number } | null {
  const match = /^([01]\d|2[0-3]):([0-5]\d)$/.exec(timeOfDay);
  if (match === null) {
    return null;
  }
  return { hour: Number(match[1]), minute: Number(match[2]) };
}

/**
 * The first instant strictly after `after` matching a fixed schedule, or
 * null when the rule, time, or zone is invalid (an automation that cannot
 * be scheduled goes dormant instead of firing at a wrong time).
 *
 * Each candidate day is materialized with `DateTime.fromObject` in the
 * zone, so luxon owns the DST edges: a nonexistent wall time (spring
 * forward) lands on the adjusted valid instant, an ambiguous one (fall
 * back) resolves to its first occurrence, and on every ordinary day the
 * wall clock stays exactly `timeOfDay` while the UTC offset moves.
 */
export function nextFixedRun(
  rrule: string,
  timeOfDay: string,
  timezone: string,
  after: Date,
): Date | null {
  const recurrence = parseRecurrence(rrule);
  const time = parseTimeOfDay(timeOfDay);
  if (recurrence === null || time === null || !isValidTimezone(timezone)) {
    return null;
  }

  const start = DateTime.fromJSDate(after, { zone: timezone });
  if (!start.isValid) {
    return null;
  }

  // Today plus at most a week always contains the next occurrence; 9 days
  // of headroom keeps the loop obviously bounded across DST shifts.
  for (let offset = 0; offset <= 9; offset += 1) {
    const day = start.plus({ days: offset });
    if (recurrence.freq === "weekly" && !recurrence.weekdays.has(day.weekday)) {
      continue;
    }
    const candidate = DateTime.fromObject(
      {
        year: day.year,
        month: day.month,
        day: day.day,
        hour: time.hour,
        minute: time.minute,
      },
      { zone: timezone },
    );
    if (!candidate.isValid) {
      continue;
    }
    if (candidate.toMillis() > after.getTime()) {
      return candidate.toJSDate();
    }
  }
  return null;
}

/** Whether a synced event qualifies for a relative schedule's filter. */
export function matchesEventFilter(
  event: CalendarSyncEvent,
  filter: AutomationEventFilter,
): boolean {
  if (filter.minAttendees !== undefined && event.attendeeCount < filter.minAttendees) {
    return false;
  }
  if (filter.keywords !== undefined && filter.keywords.length > 0) {
    const title = event.title.toLowerCase();
    return filter.keywords.some((keyword) => title.includes(keyword.toLowerCase()));
  }
  return true;
}

/**
 * The earliest `event.start - minutesBefore` that is STRICTLY after
 * `after`, across matching synced events. Strictness is load-bearing twice
 * over: a meeting learned of mid-window (20 minutes out, prep set to 30)
 * never fires — its moment predates our knowing about it — and a meeting
 * just prepped can't re-arm itself, because its fire instant is now in the
 * past. No state, no double-prep.
 */
export function nextEventRun(
  minutesBefore: number,
  filter: AutomationEventFilter,
  events: readonly CalendarSyncEvent[],
  after: Date,
): Date | null {
  let earliest: number | null = null;
  for (const event of events) {
    if (!matchesEventFilter(event, filter)) {
      continue;
    }
    const startMs = Date.parse(event.startsAt);
    if (Number.isNaN(startMs)) {
      continue;
    }
    const fireMs = startMs - minutesBefore * 60_000;
    if (fireMs > after.getTime() && (earliest === null || fireMs < earliest)) {
      earliest = fireMs;
    }
  }
  return earliest === null ? null : new Date(earliest);
}

/**
 * The next fire instant for any schedule, strictly after `after`.
 *
 * relative_to_event schedules are derived from the synced 48-hour calendar
 * view — with no view, or no matching event ahead, they return null and the
 * automation is dormant until the next sync (or run) re-arms it.
 */
export function nextRunAt(
  schedule: AutomationSchedule,
  timezone: string,
  after: Date,
  events: readonly CalendarSyncEvent[] = [],
): Date | null {
  if (schedule.kind === "fixed") {
    return nextFixedRun(schedule.rrule, schedule.timeOfDay, timezone, after);
  }
  return nextEventRun(schedule.minutesBefore, schedule.eventFilter, events, after);
}
