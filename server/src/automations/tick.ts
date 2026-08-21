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
import type { AutomationDelivery, DeliveryRecord } from "./deliver.js";
import type { AutomationHandlerResult, AutomationRunContext } from "./handlers.js";
import { nextRunAt } from "./schedule.js";
import type { RunCompletion } from "./store.js";
import { deliveryPriority, suppressionVerdict, type QuietHours } from "./suppress.js";

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
  /** The owner's quiet hours. Cached per owner per pass. */
  loadQuietHours(ownerId: string): Promise<QuietHours>;
  /** Tier + AI consent for gating. Cached per owner per pass. */
  loadOwnerGate(ownerId: string): Promise<OwnerGate>;
  /** Owner-wide recent deliveries (daily cap). Cached per owner per pass. */
  loadOwnerDeliveries(ownerId: string): Promise<DeliveryRecord[]>;
  /** One automation's own deliveries, deep enough for the ignored streak. */
  loadAutomationDeliveries(ownerId: string, automationId: string): Promise<DeliveryRecord[]>;
  /** Delivers the one auto-disable notice (through the normal deliverer). */
  notify(
    uid: string,
    automation: { id: string; type: string },
    delivery: AutomationDelivery,
  ): Promise<void>;
  /** Turns an automation off (enabled false, nextRunAt null). */
  disable(id: string): Promise<void>;
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
  quietHours: number;
  alreadyDelivered: number;
  rateLimited: number;
  /** Automations turned off after five unengaged deliveries in a row. */
  autoDisabled: number;
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
    quietHours: 0,
    alreadyDelivered: 0,
    rateLimited: 0,
    autoDisabled: 0,
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
  // Contention order: when more automations are due than today's budget
  // allows, the important ones (what expires, what the user created) go
  // first and the rate limit silences the rest.
  due.sort(
    (a, b) =>
      deliveryPriority(a) - deliveryPriority(b) ||
      (a.nextRunAt ?? "").localeCompare(b.nextRunAt ?? ""),
  );

  // One load per owner per pass — several automations often share one.
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
  const quietCache = new Map<string, QuietHours>();
  const deliveriesCache = new Map<string, DeliveryRecord[]>();
  const gateCache = new Map<string, OwnerGate>();
  /** Pushes delivered earlier in THIS pass, per owner — the cap sees them. */
  const passPushes = new Map<string, number>();

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
    let disableAfterComplete = false;
    if (isStaleFire(scheduledFor, deps.now())) {
      result = "suppressed";
      summary.stale += 1;
    } else if (claimed.schedule.kind === "relative_to_event" && (view === null || view.stale)) {
      // Calendar-dependent and the calendar can't be trusted (no sync, or
      // older than a day): the meeting may have moved or vanished. Silence.
      result = "suppressed";
      summary.noCalendar += 1;
    } else {
      const outcome = await gateAndExecute(deps, claimed, view, {
        quietCache,
        deliveriesCache,
        gateCache,
        passPushes,
        summary,
        scheduledFor,
      });
      result = outcome.result;
      disableAfterComplete = outcome.disable;
    }

    if (result === "delivered") {
      summary.delivered += 1;
      passPushes.set(claimed.ownerId, (passPushes.get(claimed.ownerId) ?? 0) + 1);
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
    if (disableAfterComplete) {
      // AFTER the completion write, so the final state is the invariant
      // one: enabled false, nextRunAt null, lock released.
      try {
        await deps.disable(claimed.id);
      } catch (err) {
        logError("auto_disable_failed", { automationId: claimed.id, ...errorFields(err) });
      }
    }
  }

  logInfo("automations_tick", { ...summary, ms: deps.now().getTime() - startedAt.getTime() });
  return summary;
}

/** What the tick needs to know about an owner before running anything. */
export interface OwnerGate {
  /** "free" | "lite" | "pro" | "max" — the subscription tier on file. */
  tier: string;
  /** Third-party AI consent granted — without it, nothing runs. */
  hasConsent: boolean;
}

/** Automation types that belong to Pro and above. */
const PRO_AUTOMATION_TYPES: ReadonlySet<string> = new Set(["meeting_prep", "weekly_review"]);

interface GateState {
  readonly quietCache: Map<string, QuietHours>;
  readonly deliveriesCache: Map<string, DeliveryRecord[]>;
  readonly gateCache: Map<string, OwnerGate>;
  readonly passPushes: Map<string, number>;
  readonly summary: TickSummary;
  readonly scheduledFor: string | null;
}

interface GateOutcome {
  readonly result: AutomationRunResult;
  /** True when the loop must turn the automation off after completing. */
  readonly disable: boolean;
}

/**
 * The suppression gate, then the handler. Every suppression is a normal
 * "suppressed" completion; the disable verdict sends its one farewell
 * notice here and asks the loop to switch the automation off after the
 * completion write.
 */
async function gateAndExecute(
  deps: TickDeps,
  claimed: Automation,
  view: CalendarView | null,
  state: GateState,
): Promise<GateOutcome> {
  let ownerGate = state.gateCache.get(claimed.ownerId);
  if (ownerGate === undefined) {
    // Fail closed: an unreadable profile runs nothing this pass.
    ownerGate = await deps
      .loadOwnerGate(claimed.ownerId)
      .catch((): OwnerGate => ({ tier: "free", hasConsent: false }));
    state.gateCache.set(claimed.ownerId, ownerGate);
  }
  // Revoked (or never-granted) AI consent silences every automation —
  // their content is model-derived from personal data.
  if (!ownerGate.hasConsent) {
    return { result: "suppressed", disable: false };
  }
  // Pro-tier automations stay quiet on lower tiers; nothing is deleted,
  // they simply don't run until the tier does.
  if (
    PRO_AUTOMATION_TYPES.has(claimed.type) &&
    ownerGate.tier !== "pro" &&
    ownerGate.tier !== "max"
  ) {
    return { result: "suppressed", disable: false };
  }

  let quiet = state.quietCache.get(claimed.ownerId);
  if (quiet === undefined) {
    quiet = await deps
      .loadQuietHours(claimed.ownerId)
      .catch((): QuietHours => ({ start: "22:00", end: "07:00" }));
    state.quietCache.set(claimed.ownerId, quiet);
  }
  let ownerDeliveries = state.deliveriesCache.get(claimed.ownerId);
  if (ownerDeliveries === undefined) {
    ownerDeliveries = await deps
      .loadOwnerDeliveries(claimed.ownerId)
      .catch((): DeliveryRecord[] => []);
    state.deliveriesCache.set(claimed.ownerId, ownerDeliveries);
  }
  const automationDeliveries = await deps
    .loadAutomationDeliveries(claimed.ownerId, claimed.id)
    .catch((): DeliveryRecord[] => []);

  const verdict = suppressionVerdict({
    automation: claimed,
    now: deps.now(),
    quiet,
    automationDeliveries,
    ownerDeliveries,
    deliveredThisPass: state.passPushes.get(claimed.ownerId) ?? 0,
  });

  if (verdict.kind === "disable") {
    // One farewell, then off. The notice bypasses the daily cap — it is
    // the last thing this automation will ever say.
    try {
      await deps.notify(claimed.ownerId, claimed, {
        title: claimed.label,
        body: verdict.notice,
        deepLink: "otto://settings",
        channel: "push",
      });
    } catch (err) {
      logError("auto_disable_notice_failed", { automationId: claimed.id, ...errorFields(err) });
    }
    state.summary.autoDisabled += 1;
    return { result: "suppressed", disable: true };
  }

  if (verdict.kind === "suppress") {
    if (verdict.reason === "quiet_hours") {
      state.summary.quietHours += 1;
    } else if (verdict.reason === "already_delivered") {
      state.summary.alreadyDelivered += 1;
    } else {
      state.summary.rateLimited += 1;
    }
    return { result: "suppressed", disable: false };
  }

  try {
    const result = await deps.execute(claimed, {
      scheduledFor: state.scheduledFor,
      now: deps.now(),
      calendar: view,
    });
    return { result, disable: false };
  } catch (err) {
    logError("automation_handler_failed", {
      automationId: claimed.id,
      userId: claimed.ownerId,
      actionKind: claimed.action.kind,
      ...errorFields(err),
    });
    return { result: "failed", disable: false };
  }
}
