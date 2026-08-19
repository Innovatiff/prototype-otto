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
import type { Automation, AutomationRunResult } from "@otto/shared";

import { errorFields, logError, logInfo } from "../log.js";
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
}

export interface TickSummary {
  due: number;
  claimed: number;
  delivered: number;
  suppressed: number;
  failed: number;
  /** Suppressions that were stale fires, never handed to a handler. */
  stale: number;
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
 * strictly after `now`, never carried forward by offset arithmetic.
 */
export function completionFor(
  automation: Automation,
  result: AutomationRunResult,
  now: Date,
): RunCompletion {
  const next = nextRunAt(automation.schedule, automation.timezone, now);
  return {
    lastRunAt: now.toISOString(),
    lastResult: result,
    nextRunAt: next === null ? null : next.toISOString(),
  };
}

export async function runTick(deps: TickDeps): Promise<TickSummary> {
  const startedAt = deps.now();
  const due = await deps.loadDue(startedAt, MAX_PER_TICK);
  const summary: TickSummary = {
    due: due.length,
    claimed: 0,
    delivered: 0,
    suppressed: 0,
    failed: 0,
    stale: 0,
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

    let result: AutomationRunResult;
    if (isStaleFire(scheduledFor, deps.now())) {
      result = "suppressed";
      summary.stale += 1;
    } else {
      try {
        result = await deps.execute(claimed, { scheduledFor, now: deps.now() });
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
      await deps.complete(claimed.id, completionFor(claimed, result, deps.now()));
    } catch (err) {
      // The lock expires on its own; the next tick may re-fire this
      // occurrence. At-least-once is the accepted trade here.
      logError("automation_complete_failed", { automationId: claimed.id, ...errorFields(err) });
    }
  }

  logInfo("automations_tick", { ...summary, ms: deps.now().getTime() - startedAt.getTime() });
  return summary;
}
