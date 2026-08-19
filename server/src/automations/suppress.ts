/**
 * The suppression gate — the layer that decides whether people keep Otto
 * installed. Every proactive delivery passes through here between the
 * claim and the handler, and the bias is ALWAYS silence:
 *
 *   - Quiet hours swallow pushes, unless the automation itself was
 *     explicitly scheduled inside them (a 22:30 automation the user asked
 *     for delivers at 22:30; meeting prep drifting into quiet hours does
 *     not).
 *   - One fire per occurrence: a fixed automation that already delivered
 *     on today's wall date stays quiet — except the re-fire the user
 *     explicitly asked for by snoozing.
 *   - At most four proactive pushes a day, per user. When several contend
 *     in one pass, priority orders them: what expires first, then what the
 *     user explicitly created.
 *   - Five consecutive unengaged deliveries disable the automation
 *     entirely, with ONE final notice saying so. An assistant that keeps
 *     talking to someone who never answers is a nag.
 *
 * Handler-level silence (nothing to say, vanished meetings) and the
 * failure rule (a throw delivers NOTHING) live in their own layers; this
 * module never overrides them in the loud direction.
 */
import type { Automation } from "@otto/shared";
import { DateTime } from "luxon";

import { wallDate } from "../util/time.js";
import type { DeliveryRecord } from "./deliver.js";

/** Visible pushes per user per day. The fifth stays silent. */
export const DAILY_PUSH_CAP = 4;

/** Unengaged deliveries in a row before an automation disables itself. */
export const IGNORED_STREAK_LIMIT = 5;

export interface QuietHours {
  readonly start: string;
  readonly end: string;
}

export const DEFAULT_QUIET_HOURS: QuietHours = { start: "22:00", end: "07:00" };

const HHMM = /^([01]\d|2[0-3]):[0-5]\d$/;

/** Quiet hours off the raw user document, defaults applied. */
export function readQuietHours(data: Record<string, unknown> | undefined): QuietHours {
  const start = data?.["quietHoursStart"];
  const end = data?.["quietHoursEnd"];
  if (typeof start === "string" && HHMM.test(start) && typeof end === "string" && HHMM.test(end)) {
    return { start, end };
  }
  return DEFAULT_QUIET_HOURS;
}

/**
 * Whether a wall-clock "HH:mm" falls inside the window. start === end
 * means quiet hours are off; a window wrapping midnight (22:00–07:00)
 * covers both sides of it.
 */
export function isInQuietHours(localTime: string, quiet: QuietHours): boolean {
  if (quiet.start === quiet.end) {
    return false;
  }
  if (quiet.start > quiet.end) {
    return localTime >= quiet.start || localTime < quiet.end;
  }
  return localTime >= quiet.start && localTime < quiet.end;
}

/** The automation's own wall clock right now, "HH:mm". */
export function localClock(now: Date, timezone: string): string {
  const local = DateTime.fromJSDate(now, { zone: timezone });
  return local.isValid ? local.toFormat("HH:mm") : now.toISOString().slice(11, 16);
}

/**
 * The explicit-schedule exemption: the user put this automation's fire
 * time inside their quiet hours on purpose (a 22:30 custom automation, a
 * 06:30 brief for a 06:35 wake). Event-relative schedules never qualify.
 */
export function scheduledInsideQuiet(automation: Automation, quiet: QuietHours): boolean {
  if (automation.schedule.kind !== "fixed") {
    return false;
  }
  return isInQuietHours(automation.schedule.timeOfDay, quiet);
}

/**
 * Contention order within a pass: what expires first wins, then what the
 * user explicitly asked for. Lower is more important.
 */
const PRIORITY: Readonly<Record<string, number>> = {
  meeting_prep: 0,
  custom: 1,
  morning_brief: 2,
  plan_checkin: 3,
  evening_shutdown: 4,
  weekly_review: 5,
};

export function deliveryPriority(automation: Automation): number {
  return PRIORITY[automation.type] ?? 9;
}

function isEngaged(delivery: DeliveryRecord): boolean {
  return delivery.openedAt !== null || delivery.action !== null;
}

/** A delivery younger than this hasn't had a fair chance to be answered. */
export const ENGAGEMENT_WINDOW_MS = 12 * 60 * 60 * 1000;

/**
 * Five consecutive unengaged deliveries — counted over the automation's
 * own pushes that actually REACHED a device, newest first, ignoring
 * anything too recent to have been answered. A push that never arrived
 * (no tokens, notifications denied, FCM down) cannot be "ignored", so a
 * user Otto can't reach never gets their automations disabled for it.
 */
export function isIgnoredStreak(deliveries: readonly DeliveryRecord[], now: Date): boolean {
  const cutoff = new Date(now.getTime() - ENGAGEMENT_WINDOW_MS).toISOString();
  const pushes = deliveries.filter(
    (delivery) =>
      delivery.channel === "push" &&
      delivery.sendOutcome === "sent" &&
      delivery.createdAt <= cutoff,
  );
  if (pushes.length < IGNORED_STREAK_LIMIT) {
    return false;
  }
  return pushes.slice(0, IGNORED_STREAK_LIMIT).every((delivery) => !isEngaged(delivery));
}

/** The one message an auto-disabled automation is allowed to send. */
export function disableNotice(automation: Automation): string {
  return (
    `I've paused ${automation.label} — the last five went unanswered. ` +
    "Turn it back on in settings whenever you want it."
  );
}

export type SuppressionVerdict =
  | { readonly kind: "deliver" }
  | {
      readonly kind: "suppress";
      readonly reason: "quiet_hours" | "already_delivered" | "rate_limited";
    }
  | { readonly kind: "disable"; readonly notice: string };

export interface SuppressionInput {
  readonly automation: Automation;
  readonly now: Date;
  readonly quiet: QuietHours;
  /**
   * This AUTOMATION's own deliveries, newest first, deep enough for the
   * streak (a weekly automation's last five span five weeks — an
   * owner-wide window would under-count them).
   */
  readonly automationDeliveries: readonly DeliveryRecord[];
  /** Every recent delivery for this OWNER, newest first — the daily count. */
  readonly ownerDeliveries: readonly DeliveryRecord[];
  /** Pushes already delivered earlier in THIS tick pass, user-wide. */
  readonly deliveredThisPass: number;
}

/**
 * The whole gate, in rule order: does this automation still deserve a
 * voice at all, is the moment quiet, did this occurrence already happen,
 * is today's budget spent.
 */
export function suppressionVerdict(input: SuppressionInput): SuppressionVerdict {
  const { automation, now, quiet } = input;
  const own = input.automationDeliveries;

  // Quiet hours FIRST — even the farewell notice must not arrive at 2am.
  // The streak survives to the next fire at a civilized hour.
  if (
    isInQuietHours(localClock(now, automation.timezone), quiet) &&
    !scheduledInsideQuiet(automation, quiet)
  ) {
    return { kind: "suppress", reason: "quiet_hours" };
  }

  if (isIgnoredStreak(own, now)) {
    return { kind: "disable", notice: disableNotice(automation) };
  }

  // One fire per occurrence, fixed schedules only (several meeting preps a
  // day are legitimate). The snoozed re-fire is the user's own request.
  if (automation.schedule.kind === "fixed") {
    const today = wallDate(now, automation.timezone);
    const todaysOwn = own.filter(
      (delivery) => wallDate(new Date(delivery.createdAt), automation.timezone) === today,
    );
    const newest = todaysOwn[0];
    if (newest !== undefined && newest.action !== "snoozed") {
      return { kind: "suppress", reason: "already_delivered" };
    }
  }

  const todaysPushes = input.ownerDeliveries.filter(
    (delivery) =>
      delivery.channel === "push" &&
      wallDate(new Date(delivery.createdAt), automation.timezone) ===
        wallDate(now, automation.timezone),
  ).length;
  if (todaysPushes + input.deliveredThisPass >= DAILY_PUSH_CAP) {
    return { kind: "suppress", reason: "rate_limited" };
  }

  return { kind: "deliver" };
}
