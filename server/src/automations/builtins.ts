/**
 * The five built-in handlers. Shape is uniform: load real data, let the
 * pure cores in content.ts DECIDE (send or stay silent), let sonnet PHRASE
 * where prose is needed (plan check-ins are fully deterministic), deliver
 * real content. Any throw anywhere lands in the tick frame as "failed"
 * with nothing delivered.
 */
import type { BriefRequest, CalendarEvent, Conflict } from "@otto/shared";

import { gatherBriefContext, loadActiveTasks } from "../brief/gather.js";
import { storeBrief } from "../brief/store.js";
import {
  BRIEF_MODEL,
  SUMMARY_MODEL,
  summarizeBrief,
  synthesizeBrief,
} from "../brief/synthesize.js";
import { errorFields, logWarning } from "../log.js";
import { retrieveMemories } from "../memory/retrieve.js";
import { loadActivePlans, loadSessionRecords } from "../plans/store.js";
import { summarizeRecords } from "../routes/plans.js";
import { recordCostEvent } from "../telemetry/cost.js";
import { wallTime } from "../util/time.js";
import { composeAutomationText } from "./compose.js";
import {
  briefPushBody,
  cleanWeekStreak,
  eveningFacts,
  hasEveningContent,
  hasWeeklyContent,
  overlapsIn,
  planCheckinMessage,
  resolveUpcomingMeeting,
  serializeEveningFacts,
  serializeWeeklyFacts,
  tasksMatchingTitle,
  weeklyFacts,
  type SyncOverlap,
} from "./content.js";
import {
  loadRecentDeliveries,
  shouldSuppressIgnoredTitle,
  storeDeliverer,
  titleKey,
  type Deliverer,
} from "./deliver.js";
import { registerHandler, type AutomationHandler } from "./handlers.js";

/** Swappable for tests; production uses the store deliverer (Step 5: FCM). */
let deliver: Deliverer = storeDeliverer;

export function setDeliverer(next: Deliverer): void {
  deliver = next;
}

// ── morning_brief ───────────────────────────────────────────────────

/** The synced compressed view widened back to the brief's event shape. */
function asBriefEvents(events: readonly { id: string; title: string; startsAt: string; endsAt: string; location?: string }[]): CalendarEvent[] {
  return events.map((event) => ({
    id: event.id,
    title: event.title,
    startsAt: event.startsAt,
    endsAt: event.endsAt,
    isAllDay: false,
    ...(event.location !== undefined ? { location: event.location } : {}),
  }));
}

function asConflicts(overlaps: readonly SyncOverlap[], events: readonly CalendarEvent[]): Conflict[] {
  const byId = new Map(events.map((event) => [event.id, event]));
  return overlaps.flatMap((overlap) => {
    const eventA = byId.get(overlap.a.id);
    const eventB = byId.get(overlap.b.id);
    if (eventA === undefined || eventB === undefined) {
      return [];
    }
    return [{ eventA, eventB, kind: "overlap" as const, minutesShort: overlap.minutes }];
  });
}

const morningBrief: AutomationHandler = async (automation, ctx) => {
  const events = ctx.calendar !== null && !ctx.calendar.stale ? ctx.calendar.events : [];
  const briefEvents = asBriefEvents(events);
  const overlaps = overlapsIn(events);
  const request: BriefRequest = {
    events: briefEvents,
    conflicts: asConflicts(overlaps, briefEvents),
    timezone: automation.timezone,
  };
  const context = await gatherBriefContext(automation.ownerId, request, ctx.now);

  // The push body is deterministic — reliable at 07:00 by construction.
  const body = briefPushBody(
    {
      weatherLine:
        context.weather === null
          ? null
          : `${context.weather.temperatureC.toFixed(0)} degrees` +
            (context.weather.precipitationProbability >= 50 ? " and likely rain." : "."),
      todayEvents: events,
      overlaps,
      dueCount: context.dueTasks.length,
      timezone: automation.timezone,
    },
    ctx.now,
  );
  if (body.length === 0) {
    return "suppressed";
  }

  // The FULL brief generates before delivery — the tap has something real
  // to play, and tomorrow's brief gets its continuity. A synthesis failure
  // fails the run: no push may point at a brief that does not exist.
  const startedAt = Date.now();
  const synthesis = await synthesizeBrief(context, automation.ownerId);
  await recordCostEvent({
    userId: automation.ownerId,
    turnId: `auto-${automation.id}-${context.date}`,
    tier: "background",
    model: BRIEF_MODEL,
    purpose: "brief",
    inputTokens: synthesis.usage.inputTokens,
    outputTokens: synthesis.usage.outputTokens,
    cacheReadTokens: synthesis.usage.cacheReadTokens,
    cacheCreationTokens: synthesis.usage.cacheCreationTokens,
    latencyMs: Date.now() - startedAt,
  });

  await deliver(automation.ownerId, automation, {
    title: "Morning brief",
    body,
    deepLink: "otto://brief",
    channel: "push",
  });

  // Continuity is best-effort once delivery happened.
  try {
    const summaryStartedAt = Date.now();
    const { summary, usage } = await summarizeBrief(synthesis.spoken, automation.ownerId);
    await storeBrief({
      ownerId: automation.ownerId,
      date: context.date,
      spoken: synthesis.spoken,
      summary,
      createdAt: ctx.now.toISOString(),
    });
    await recordCostEvent({
      userId: automation.ownerId,
      turnId: `auto-${automation.id}-${context.date}`,
      tier: "background",
      model: SUMMARY_MODEL,
      purpose: "brief",
      inputTokens: usage.inputTokens,
      outputTokens: usage.outputTokens,
      cacheReadTokens: usage.cacheReadTokens,
      cacheCreationTokens: usage.cacheCreationTokens,
      latencyMs: Date.now() - summaryStartedAt,
    });
  } catch (err) {
    logWarning("brief_summary_failed", { userId: automation.ownerId, ...errorFields(err) });
  }
  return "delivered";
};

// ── evening_shutdown ────────────────────────────────────────────────

const eveningShutdown: AutomationHandler = async (automation, ctx) => {
  const events = ctx.calendar !== null && !ctx.calendar.stale ? ctx.calendar.events : [];
  const tasks = await loadActiveTasks(automation.ownerId);
  const facts = eveningFacts(events, tasks, ctx.now, automation.timezone);
  if (!hasEveningContent(facts)) {
    return "suppressed";
  }
  const body = await composeAutomationText({
    uid: automation.ownerId,
    turnId: `auto-${automation.id}-${ctx.now.toISOString().slice(0, 10)}`,
    system:
      "This is the evening shutdown. Cover, in one breath: tomorrow's top " +
      "commitments with their times (at most three), anything that slipped " +
      "today, and one thing worth preparing tonight. If a section is empty, " +
      "skip it silently.",
    facts: serializeEveningFacts(facts),
  });
  await deliver(automation.ownerId, automation, {
    title: "Evening shutdown",
    body,
    deepLink: "otto://today",
    channel: "push",
  });
  return "delivered";
};

// ── meeting_prep ────────────────────────────────────────────────────

const meetingPrep: AutomationHandler = async (automation, ctx) => {
  if (automation.schedule.kind !== "relative_to_event" || ctx.calendar === null) {
    return "suppressed";
  }
  const meeting = resolveUpcomingMeeting(
    ctx.calendar.events,
    automation.schedule.eventFilter,
    automation.schedule.minutesBefore,
    ctx.now,
  );
  if (meeting === null) {
    // Moved or vanished since the fire was armed. Silence, not a guess.
    return "suppressed";
  }
  const key = titleKey(meeting.title);
  const history = await loadRecentDeliveries(automation.ownerId, automation.id);
  if (shouldSuppressIgnoredTitle(history, key)) {
    return "suppressed";
  }

  // Identities never sync, so context comes from the TITLE: memories that
  // resemble it, open tasks that share its words. Retrieval never throws.
  const [memories, tasks] = await Promise.all([
    retrieveMemories(automation.ownerId, meeting.title, ctx.now),
    loadActiveTasks(automation.ownerId),
  ]);
  const openItems = tasksMatchingTitle(tasks, meeting.title);

  const factLines: string[] = [
    `MEETING: ${meeting.title} at ${wallTime(meeting.startsAt, automation.timezone)}, ` +
      `${meeting.attendeeCount} attendees` +
      (meeting.location !== undefined ? `, at ${meeting.location}` : ""),
  ];
  if (memories.length > 0) {
    factLines.push("WHAT OTTO KNOWS (may or may not be relevant — judge):");
    for (const memory of memories.slice(0, 6)) {
      factLines.push(`- [${memory.category}] ${memory.content}`);
    }
  }
  if (openItems.length > 0) {
    factLines.push("OPEN ITEMS MENTIONING IT:");
    for (const task of openItems) {
      factLines.push(`- ${task.title}`);
    }
  }

  const body = await composeAutomationText({
    uid: automation.ownerId,
    turnId: `auto-${automation.id}-${meeting.id}`,
    system:
      "This is meeting preparation, arriving shortly before the meeting. " +
      "Say what the meeting is and when. If the context holds anything " +
      "genuinely relevant, weave in the one or two facts that matter and " +
      "any open items. End with ONE sharp question the owner could open " +
      "with. If the context is thin, keep it to the essentials — never pad.",
    facts: factLines.join("\n"),
  });
  await deliver(automation.ownerId, automation, {
    title: meeting.title,
    body,
    deepLink: "otto://calendar",
    channel: "push",
    titleKey: key,
  });
  return "delivered";
};

// ── weekly_review ───────────────────────────────────────────────────

const weeklyReview: AutomationHandler = async (automation, ctx) => {
  const [plans, tasks] = await Promise.all([
    loadActivePlans(automation.ownerId),
    loadActiveTasks(automation.ownerId),
  ]);
  const withSummaries = await Promise.all(
    plans.map(async (plan) => ({
      plan,
      summary: summarizeRecords(
        plan,
        await loadSessionRecords(automation.ownerId, plan.id),
        ctx.now,
      ),
    })),
  );
  const events = ctx.calendar !== null && !ctx.calendar.stale ? ctx.calendar.events : [];
  const facts = weeklyFacts(withSummaries, tasks, events, ctx.now, automation.timezone);
  if (!hasWeeklyContent(facts)) {
    return "suppressed";
  }
  const body = await composeAutomationText({
    uid: automation.ownerId,
    turnId: `auto-${automation.id}-${ctx.now.toISOString().slice(0, 10)}`,
    system:
      "This is the Sunday review. Cover what the adherence numbers actually " +
      "say (plainly — the owner can take it), what slipped, and what the " +
      "start of the week looks like. Skip empty sections silently.",
    facts: serializeWeeklyFacts(facts),
  });
  await deliver(automation.ownerId, automation, {
    title: "Weekly review",
    body,
    deepLink: "otto://review",
    channel: "push",
  });
  return "delivered";
};

// ── plan_checkin ────────────────────────────────────────────────────

const planCheckin: AutomationHandler = async (automation, ctx) => {
  const plans = await loadActivePlans(automation.ownerId);
  const inputs = await Promise.all(
    plans.map(async (plan) => {
      const records = await loadSessionRecords(automation.ownerId, plan.id, 200);
      return {
        plan,
        summary: summarizeRecords(plan, records, ctx.now),
        streakWeeks: cleanWeekStreak(plan, records, ctx.now),
      };
    }),
  );
  const message = planCheckinMessage(inputs);
  if (message === null) {
    // Nothing notable. DO NOT SEND.
    return "suppressed";
  }
  await deliver(automation.ownerId, automation, {
    title: "Plan check-in",
    body: message.body,
    deepLink: `otto://plans/${message.planId}`,
    channel: "push",
  });
  return "delivered";
};

// ── Registration ────────────────────────────────────────────────────

export function registerBuiltInHandlers(): void {
  registerHandler("morning_brief", morningBrief);
  registerHandler("evening_shutdown", eveningShutdown);
  registerHandler("meeting_prep", meetingPrep);
  registerHandler("weekly_review", weeklyReview);
  registerHandler("plan_checkin", planCheckin);
}
