/**
 * Custom automations — the ones the user invents by voice.
 *
 * The MODEL parses speech into {label, rrule, timeOfDay, instruction}; this
 * module is the deterministic other half: validate against the strict
 * recurrence subset, build the document, humanize the schedule for the
 * one-line confirmation ("Done. Every Friday at 3:30."), match spoken
 * labels for enable/disable/delete, and run the stored instruction at fire
 * time with the owner's real data.
 */
import type { Automation, AutomationSchedule } from "@otto/shared";
import { z } from "zod";

import { loadActiveTasks } from "../brief/gather.js";
import { retrieveMemories } from "../memory/retrieve.js";
import { wallTime } from "../util/time.js";
import { composeAutomationText } from "./compose.js";
import { serializeEveningFacts, eveningFacts } from "./content.js";
import { storeDeliverer, type Deliverer } from "./deliver.js";
import type { AutomationHandler } from "./handlers.js";
import { isValidTimezone, nextRunAt, parseRecurrence } from "./schedule.js";

/** A sane runaway bound; tier enforcement (Lite: 3) is Phase 7's. */
export const MAX_CUSTOM_AUTOMATIONS = 20;

export const CustomAutomationInput = z.object({
  label: z.string().min(1).max(120),
  rrule: z.string().min(1).max(200),
  timeOfDay: z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/),
  instruction: z.string().min(1).max(1000),
});
export type CustomAutomationInput = z.infer<typeof CustomAutomationInput>;

// ── Humanizing schedules ────────────────────────────────────────────

const DAY_NAMES = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"];

/** "15:30" -> "3:30 PM". */
export function formatTimeOfDay(timeOfDay: string): string {
  const match = /^(\d{2}):(\d{2})$/.exec(timeOfDay);
  if (match === null) {
    return timeOfDay;
  }
  const hour = Number(match[1]);
  const suffix = hour >= 12 ? "PM" : "AM";
  const twelve = hour % 12 === 0 ? 12 : hour % 12;
  return `${twelve}:${match[2]} ${suffix}`;
}

/**
 * The spoken description of a schedule — exactly what the confirmation
 * line and the management list say.
 */
export function describeSchedule(schedule: AutomationSchedule): string {
  if (schedule.kind === "relative_to_event") {
    const filter = schedule.eventFilter;
    let what = "events";
    if (filter.minAttendees !== undefined && filter.minAttendees >= 2) {
      what = "meetings";
    }
    const keyword = filter.keywords?.[0];
    const matching = keyword !== undefined ? ` matching "${keyword}"` : "";
    return `${schedule.minutesBefore} minutes before ${what}${matching}`;
  }
  const recurrence = parseRecurrence(schedule.rrule);
  const time = formatTimeOfDay(schedule.timeOfDay);
  if (recurrence === null) {
    return `at ${time}`;
  }
  if (recurrence.freq === "daily") {
    return `Every day at ${time}`;
  }
  const days = [...recurrence.weekdays].sort((a, b) => a - b);
  const key = days.join(",");
  if (key === "1,2,3,4,5") {
    return `Weekdays at ${time}`;
  }
  if (key === "6,7") {
    return `Weekends at ${time}`;
  }
  if (days.length === 7) {
    return `Every day at ${time}`;
  }
  const names = days.map((day) => DAY_NAMES[day - 1] ?? "?");
  const joined =
    names.length === 1
      ? names[0]
      : `${names.slice(0, -1).join(", ")} and ${names[names.length - 1]}`;
  return `Every ${joined} at ${time}`;
}

// ── Building ────────────────────────────────────────────────────────

export type BuildResult = { ok: true; automation: Automation } | { ok: false; error: string };

/**
 * Everything deterministic about creation. The recurrence must sit inside
 * the supported subset — an rrule the scheduler cannot compute is rejected
 * HERE, at creation, never discovered as a silent no-fire later.
 */
export function buildCustomAutomation(
  uid: string,
  timezone: string,
  input: CustomAutomationInput,
  existingCustomCount: number,
  now: Date,
  mintId: () => string,
): BuildResult {
  if (!isValidTimezone(timezone)) {
    return { ok: false, error: "Unknown timezone." };
  }
  if (parseRecurrence(input.rrule) === null) {
    return {
      ok: false,
      error:
        "Unsupported recurrence. Use FREQ=DAILY or FREQ=WEEKLY;BYDAY=… " +
        "(e.g. FREQ=WEEKLY;BYDAY=FR).",
    };
  }
  if (existingCustomCount >= MAX_CUSTOM_AUTOMATIONS) {
    return { ok: false, error: "Automation limit reached. Delete one first." };
  }
  const schedule: AutomationSchedule = {
    kind: "fixed",
    rrule: input.rrule,
    timeOfDay: input.timeOfDay,
  };
  const next = nextRunAt(schedule, timezone, now);
  if (next === null) {
    return { ok: false, error: "That schedule never fires." };
  }
  return {
    ok: true,
    automation: {
      id: mintId(),
      ownerId: uid,
      type: "custom",
      label: input.label,
      enabled: true,
      schedule,
      timezone,
      action: { kind: "custom", params: { instruction: input.instruction } },
      lastRunAt: null,
      nextRunAt: next.toISOString(),
      lastResult: null,
      createdAt: now.toISOString(),
    },
  };
}

// ── Matching spoken labels ──────────────────────────────────────────

function normalized(text: string): string {
  return text
    .toLowerCase()
    .replace(/[^a-z0-9\s]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

/**
 * "turn off the morning brief" -> the morning_brief automation. Exact
 * label first, then containment either way, then the type's own words.
 * Null when nothing plausibly matches — the model asks, never guesses.
 */
export function matchAutomation(
  automations: readonly Automation[],
  query: string,
): Automation | null {
  const needle = normalized(query);
  if (needle.length === 0) {
    return null;
  }
  const exact = automations.find((automation) => normalized(automation.label) === needle);
  if (exact !== undefined) {
    return exact;
  }
  const contains = automations.find((automation) => {
    const label = normalized(automation.label);
    return label.includes(needle) || needle.includes(label);
  });
  if (contains !== undefined) {
    return contains;
  }
  return (
    automations.find((automation) => {
      const typeWords = normalized(automation.type.replace(/_/g, " "));
      return needle.includes(typeWords) || typeWords === needle;
    }) ?? null
  );
}

// ── Enable / disable ────────────────────────────────────────────────

/**
 * The targeted fields a toggle writes. Disabling parks the automation
 * (nextRunAt null keeps it out of the due query's range); enabling re-arms
 * fixed schedules from the rule now, and leaves event-relative ones null
 * for the next calendar sync to arm.
 */
export function enabledUpdateFields(
  automation: Automation,
  enabled: boolean,
  now: Date,
): { enabled: boolean; nextRunAt: string | null } {
  if (!enabled) {
    return { enabled: false, nextRunAt: null };
  }
  const next = nextRunAt(automation.schedule, automation.timezone, now);
  return { enabled: true, nextRunAt: next === null ? null : next.toISOString() };
}

// ── Management edits (Step 7's screen) ──────────────────────────────

export type UpdateOutcome =
  | {
      readonly ok: true;
      readonly fields: {
        enabled?: boolean;
        schedule?: AutomationSchedule;
        nextRunAt: string | null;
      };
    }
  | { readonly ok: false; readonly error: string };

/**
 * The targeted fields one management edit writes. Retiming applies only
 * to fixed schedules; every accepted edit recomputes nextRunAt from the
 * final state (disabled parks it; an event-relative enable waits for the
 * next calendar sync). The user just touched this automation, so moving
 * even a due-pending fire is their explicit intent.
 */
export function applyAutomationUpdate(
  automation: Automation,
  request: { enabled?: boolean; timeOfDay?: string },
  now: Date,
): UpdateOutcome {
  if (request.enabled === undefined && request.timeOfDay === undefined) {
    return { ok: false, error: "Nothing to update." };
  }
  let schedule = automation.schedule;
  if (request.timeOfDay !== undefined) {
    if (schedule.kind !== "fixed") {
      return { ok: false, error: "Only fixed-time automations have a time to edit." };
    }
    schedule = { ...schedule, timeOfDay: request.timeOfDay };
  }
  const enabled = request.enabled ?? automation.enabled;
  const next = enabled ? nextRunAt(schedule, automation.timezone, now) : null;
  return {
    ok: true,
    fields: {
      ...(request.enabled !== undefined ? { enabled } : {}),
      ...(request.timeOfDay !== undefined ? { schedule } : {}),
      nextRunAt: next === null ? null : next.toISOString(),
    },
  };
}

/** Built-ins in their canonical order, then customs by label. */
export function sortForManagement(automations: readonly Automation[]): Automation[] {
  const builtInOrder: Readonly<Record<string, number>> = {
    morning_brief: 0,
    evening_shutdown: 1,
    meeting_prep: 2,
    plan_checkin: 3,
    weekly_review: 4,
  };
  return [...automations].sort((a, b) => {
    const rankA = builtInOrder[a.type] ?? 100;
    const rankB = builtInOrder[b.type] ?? 100;
    return rankA - rankB || a.label.localeCompare(b.label);
  });
}

// ── The fire-time handler ───────────────────────────────────────────

/**
 * The exact escape hatch the composer is told to use when the data holds
 * nothing worth a notification.
 */
export const NOTHING_TO_SAY = "NOTHING_TO_SAY";

export function isNothingToSay(text: string): boolean {
  return text.trim().replace(/[."']/g, "").toUpperCase() === NOTHING_TO_SAY;
}

/** Swappable for tests; production stores (Step 5: FCM on top). */
let deliver: Deliverer = storeDeliverer;

export function setCustomDeliverer(next: Deliverer): void {
  deliver = next;
}

/**
 * Runs the stored instruction against the owner's REAL data: the synced
 * calendar (fresh only), open tasks, and memories the instruction itself
 * retrieves. Composite instructions ("check my calendar AND my task list,
 * then text me a summary") work because the model sees all sources at
 * once. Texting is drafting: Otto writes the text, the owner sends it.
 */
export const customPromptHandler: AutomationHandler = async (automation, ctx) => {
  const instruction = automation.action.params["instruction"];
  if (typeof instruction !== "string" || instruction.trim().length === 0) {
    throw new Error("Custom automation has no instruction.");
  }
  const events = ctx.calendar !== null && !ctx.calendar.stale ? ctx.calendar.events : [];
  const [tasks, memories] = await Promise.all([
    loadActiveTasks(automation.ownerId),
    retrieveMemories(automation.ownerId, instruction, ctx.now),
  ]);

  const lines: string[] = [`STANDING INSTRUCTION: ${instruction}`];
  lines.push(`NOW: ${ctx.now.toISOString()} (${automation.timezone})`);
  if (events.length > 0) {
    lines.push("CALENDAR (next 48h, compressed):");
    for (const event of events.slice(0, 20)) {
      const where = event.location !== undefined ? ` @ ${event.location}` : "";
      lines.push(
        `- ${wallTime(event.startsAt, automation.timezone)} ${event.title}${where} ` +
          `(${event.attendeeCount} attendees)`,
      );
    }
  } else {
    lines.push("CALENDAR: nothing in the synced 48-hour window.");
  }
  const openTasks = tasks.filter((task) => task.status === "active").slice(0, 15);
  if (openTasks.length > 0) {
    lines.push("OPEN TASKS:");
    for (const task of openTasks) {
      lines.push(`- ${task.title}`);
    }
  }
  if (memories.length > 0) {
    lines.push("RELEVANT MEMORY:");
    for (const memory of memories.slice(0, 5)) {
      lines.push(`- [${memory.category}] ${memory.content}`);
    }
  }
  // Today's shape, pre-digested, so "summarize my evening" style
  // instructions have tomorrow/slipped facts without recomputing.
  lines.push(serializeEveningFacts(eveningFacts(events, tasks, ctx.now, automation.timezone)));

  const body = await composeAutomationText({
    uid: automation.ownerId,
    turnId: `auto-${automation.id}-${ctx.now.toISOString().slice(0, 10)}`,
    system:
      "Execute the owner's STANDING INSTRUCTION using only the data " +
      "provided. If it asks to text or message someone, WRITE the message " +
      "ready to send (Otto drafts; the owner taps send). If, given the " +
      `data, there is genuinely nothing worth saying, reply exactly ` +
      `${NOTHING_TO_SAY} and nothing else.`,
    facts: lines.join("\n"),
  });
  if (isNothingToSay(body)) {
    return "suppressed";
  }
  await deliver(automation.ownerId, automation, {
    title: automation.label,
    body,
    deepLink: "otto://today",
    channel: "push",
  });
  return "delivered";
};
