/**
 * One scheduler pass: find due automations, claim each against racing
 * ticks, run its handler, recompute the next fire in the OWNER'S timezone,
 * record the result, release the lock.
 *
 * The engine takes its dependencies as values so the whole claim/execute/
 * complete choreography is testable without Firestore. Failure posture is
 * absolute: a handler throw records "failed" and delivers NOTHING; a
 * completion-write failure abandons that automation to its expiring lock
 * (at-least-once, bounded by LOCK_MS) rather than stalling the pass.
 */
import type { Automation, AutomationRunResult, CalendarSyncEvent } from "@otto/shared";

import { errorFields, logError, logInfo } from "../log.js";
import type { CalendarView } from "./calendarView.js";
import type { AutomationHandlerResult, AutomationRunContext } from "./handlers.js";
import { nextRunAt } from "./schedule.js";
import type { RunCompletion } from "./store.js";

/** Per-pass cap; anything beyond it is picked up by the next 5-minute tick. */
export const MAX_PER_TICK = 25;

/**
 * A fire more than this far past its moment is stale: the 07:00 brief has
 * no business arriving at lunch because the server was down all morning.
 * Stale fires record "suppressed" WITHOUT running the handler, and the
 * schedule advances to the next occurrence.
 */
export const STALE_GRACE_MS = 60 * 60 * 1000;

export interface TickDeps {
  now(): Date;
  loadDue(now: Date, limit: number): Promise<Automation[]>;
  claim(id: string, now: Date): Promise<Automation | null>;
  complete(id: string, completion: RunCompletion): Promise<void>;
  execute(automation: Automation, ctx: AutomationRunContext): Promise<AutomationHandlerResult>;
  /** The owner's synced calendar view, or null. Cached per owner per pass. */
  loadView(ownerId: string, now: Date): Promise<CalendarView | null>;
  /** Deletes views past their 48-hour TTL; returns how many. */
  purgeViews(now: Date): Promise<number>;
}

export interface TickSummary {
  due: number;
  claimed: number;
  delivered: number;
  suppressed: number;
  failed: number;
  /** Suppressions that were stale fires, never handed to a handler. */
  stale: number;
  /** Calendar-dependent automations suppressed for a missing/stale view. */
  noCalendar: number;
  purgedViews: number;
}

/** True when this fire's moment is more than the grace window gone. */
export function isStaleFire(scheduledFor: string | null, now: Date): boolean {
  if (scheduledFor === null) {
    return false;
  }
  const scheduled = Date.parse(scheduledFor);
  if (Number.isNaN(scheduled)) {
    return true;
  }
  return now.getTime() - scheduled > STALE_GRACE_MS;
}

/**
 * The completion record for a finished run: result, run stamp, and the
 * next occurrence — recomputed from the rule in the automation's timezone
 * strictly after `now` (fixed), or from the synced events (relative) —
 * never carried forward by offset arithmetic.
 */
export function completionFor(
  automation: Automation,
  result: AutomationRunResult,
  now: Date,
  events: readonly CalendarSyncEvent[] = [],
): RunCompletion {
  const next = nextRunAt(automation.schedule, automation.timezone, now, events);
  return {
    lastRunAt: now.toISOString(),
    lastResult: result,
    nextRunAt: next === null ? null : next.toISOString(),
  };
}

export async function runTick(deps: TickDeps): Promise<TickSummary> {
  const startedAt = deps.now();
  const summary: TickSummary = {
    due: 0,
    claimed: 0,
    delivered: 0,
    suppressed: 0,
    failed: 0,
    stale: 0,
    noCalendar: 0,
    purgedViews: 0,
  };

  // Retention first: synced views die at 48 hours whether or not anything
  // else in this pass works.
  try {
    summary.purgedViews = await deps.purgeViews(startedAt);
  } catch (err) {
    logError("calendar_purge_failed", errorFields(err));
  }

  const due = await deps.loadDue(startedAt, MAX_PER_TICK);
  summary.due = due.length;

  // One view load per owner per pass — several automations often share one.
  const viewCache = new Map<string, CalendarView | null>();
  const viewFor = async (ownerId: string): Promise<CalendarView | null> => {
    if (viewCache.has(ownerId)) {
      return viewCache.get(ownerId) ?? null;
    }
    let view: CalendarView | null = null;
    try {
      view = await deps.loadView(ownerId, deps.now());
    } catch (err) {
      logError("calendar_view_load_failed", { userId: ownerId, ...errorFields(err) });
    }
    viewCache.set(ownerId, view);
    return view;
  };

  // Sequential on purpose: per-pass work is capped, handlers may hit the
  // model, and a predictable pass beats a fast one here.
  for (const candidate of due) {
    const claimed = await deps.claim(candidate.id, deps.now());
    if (claimed === null) {
      continue;
    }
    summary.claimed += 1;
    const scheduledFor = claimed.nextRunAt ?? null;
    const view = await viewFor(claimed.ownerId);

    let result: AutomationRunResult;
    if (isStaleFire(scheduledFor, deps.now())) {
      result = "suppressed";
      summary.stale += 1;
    } else if (claimed.schedule.kind === "relative_to_event" && (view === null || view.stale)) {
      // Calendar-dependent and the calendar can't be trusted (no sync, or
      // older than a day): the meeting may have moved or vanished. Silence.
      result = "suppressed";
      summary.noCalendar += 1;
    } else {
      try {
        result = await deps.execute(claimed, { scheduledFor, now: deps.now(), calendar: view });
      } catch (err) {
        logError("automation_handler_failed", {
          automationId: claimed.id,
          userId: claimed.ownerId,
          actionKind: claimed.action.kind,
          ...errorFields(err),
        });
        result = "failed";
      }
    }

    if (result === "delivered") {
      summary.delivered += 1;
    } else if (result === "suppressed") {
      summary.suppressed += 1;
    } else {
      summary.failed += 1;
    }

    try {
      await deps.complete(
        claimed.id,
        completionFor(claimed, result, deps.now(), view?.events ?? []),
      );
    } catch (err) {
      // The lock expires on its own; the next tick may re-fire this
      // occurrence. At-least-once is the accepted trade here.
      logError("automation_complete_failed", { automationId: claimed.id, ...errorFields(err) });
    }
  }

  logInfo("automations_tick", { ...summary, ms: deps.now().getTime() - startedAt.getTime() });
  return summary;
}
