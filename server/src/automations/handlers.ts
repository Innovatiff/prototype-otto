/**
 * The action-handler registry the tick dispatches through.
 *
 * Step 3 registers the built-in handlers (morning_brief, evening_shutdown,
 * meeting_prep, weekly_review, plan_checkin); Step 4 adds the custom-action
 * ones. Until a kind is registered, executing it throws — and the tick
 * frame turns any handler throw into lastResult "failed" with NOTHING
 * delivered. A half-generated brief must never reach a phone.
 */
import type { Automation } from "@otto/shared";

import type { CalendarView } from "./calendarView.js";

/**
 * "suppressed" is a success: the handler ran, decided there was nothing
 * worth saying, and said nothing. Handlers never return "failed" — failure
 * is thrown, so a bug cannot accidentally report a clean miss.
 */
export type AutomationHandlerResult = "delivered" | "suppressed";

export interface AutomationRunContext {
  /** The nextRunAt that triggered this run (ISO), for lateness decisions. */
  readonly scheduledFor: string | null;
  readonly now: Date;
  /**
   * The owner's synced 48-hour view, if one exists. `stale` means older
   * than 24 hours — enrich-only handlers (briefs) should drop the calendar
   * section rather than narrate yesterday's schedule.
   */
  readonly calendar: CalendarView | null;
}

export type AutomationHandler = (
  automation: Automation,
  ctx: AutomationRunContext,
) => Promise<AutomationHandlerResult>;

const HANDLERS = new Map<string, AutomationHandler>();

/** Registers (or replaces) the handler for an action kind. */
export function registerHandler(kind: string, handler: AutomationHandler): void {
  HANDLERS.set(kind, handler);
}

export function executeAutomation(
  automation: Automation,
  ctx: AutomationRunContext,
): Promise<AutomationHandlerResult> {
  const handler = HANDLERS.get(automation.action.kind);
  if (handler === undefined) {
    throw new Error(`No handler registered for action kind "${automation.action.kind}".`);
  }
  return handler(automation, ctx);
}
