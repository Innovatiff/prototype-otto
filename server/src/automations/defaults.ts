/**
 * The five built-ins, seeded once per user.
 *
 * ensureBuiltInAutomations runs on every calendar sync (which already
 * loaded the owner's automations, so the check is free) and creates only
 * what's missing — a user who deleted nothing has all five; Step 7's
 * settings edit these in place, never re-create them.
 *
 * The morning brief's timeOfDay is wake time MINUS FIVE MINUTES: the spec
 * generates before delivery, and with a five-minute tick cadence this puts
 * the finished brief on the phone at wake, not five minutes late.
 */
import type { Automation, AutomationType } from "@otto/shared";

import { COLLECTIONS, db } from "../firestore.js";
import { logInfo } from "../log.js";
import { nextRunAt } from "./schedule.js";
import { mintAutomationId } from "./store.js";

const WEEKDAYS = "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR";
const SUNDAY = "FREQ=WEEKLY;BYDAY=SU";

interface BuiltInSpec {
  readonly type: AutomationType;
  readonly label: string;
  readonly schedule: Automation["schedule"];
}

/** Default times; Step 7's wake/workday settings move them per user. */
export const BUILT_IN_SPECS: readonly BuiltInSpec[] = [
  {
    type: "morning_brief",
    label: "Morning brief",
    // Default wake 07:30 -> generate at 07:25.
    schedule: { kind: "fixed", rrule: WEEKDAYS, timeOfDay: "07:25" },
  },
  {
    type: "evening_shutdown",
    label: "Evening shutdown",
    schedule: { kind: "fixed", rrule: WEEKDAYS, timeOfDay: "17:30" },
  },
  {
    type: "meeting_prep",
    label: "Meeting prep",
    schedule: { kind: "relative_to_event", minutesBefore: 30, eventFilter: { minAttendees: 2 } },
  },
  {
    type: "plan_checkin",
    label: "Plan check-in",
    schedule: { kind: "fixed", rrule: SUNDAY, timeOfDay: "17:00" },
  },
  {
    type: "weekly_review",
    label: "Weekly review",
    schedule: { kind: "fixed", rrule: SUNDAY, timeOfDay: "18:30" },
  },
];

/** The missing built-ins as full documents, armed for their first fire. */
export function missingBuiltIns(
  existing: readonly Automation[],
  uid: string,
  timezone: string,
  now: Date,
  mintId: () => string,
): Automation[] {
  const present = new Set(existing.map((automation) => automation.type));
  return BUILT_IN_SPECS.filter((spec) => !present.has(spec.type)).map((spec) => {
    const next = nextRunAt(spec.schedule, timezone, now);
    return {
      id: mintId(),
      ownerId: uid,
      type: spec.type,
      label: spec.label,
      enabled: true,
      schedule: spec.schedule,
      timezone,
      action: { kind: spec.type, params: {} },
      lastRunAt: null,
      nextRunAt: next === null ? null : next.toISOString(),
      lastResult: null,
      createdAt: now.toISOString(),
    };
  });
}

/** Creates whatever is missing; returns how many. Idempotent. */
export async function ensureBuiltInAutomations(
  existing: readonly Automation[],
  uid: string,
  timezone: string,
  now: Date,
): Promise<number> {
  const created = missingBuiltIns(existing, uid, timezone, now, mintAutomationId);
  if (created.length === 0) {
    return 0;
  }
  const batch = db().batch();
  for (const automation of created) {
    batch.set(db().collection(COLLECTIONS.automations).doc(automation.id), automation);
  }
  await batch.commit();
  logInfo("built_in_automations_seeded", {
    userId: uid,
    created: created.map((automation) => automation.type),
  });
  return created.length;
}
