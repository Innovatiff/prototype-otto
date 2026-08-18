/**
 * /plans — calendar links only, for now. Plan CONTENT is immutable and
 * server-authored (generation and adaptation write it); this route stores
 * the one piece of operational bookkeeping the device owns: which EventKit
 * event each scheduled occurrence became, after the device verified the
 * write by reading it back. Step 9 adds the read endpoints for the plan UI.
 */
import { Router, type Request, type Response } from "express";
import {
  Plan,
  PlanCalendarEventsRequest,
  type PlanCalendarEvent,
  type PlanSummary,
} from "@otto/shared";

import { AppError, IdParam, parseOrThrow } from "../errors.js";
import { COLLECTIONS, db } from "../firestore.js";
import { logInfo } from "../log.js";
import { requireUid } from "../middleware/auth.js";

export const plansRouter = Router();

/** The list view of a plan — body stripped, counts derived. Pure. */
export function summarizePlanDoc(plan: Plan): PlanSummary {
  return {
    id: plan.id,
    meta: plan.meta,
    status: plan.status,
    ...(plan.supersedes !== undefined ? { supersedes: plan.supersedes } : {}),
    sessionCount: plan.sessions.length,
    scheduleEntryCount: plan.schedule.length,
    createdAt: plan.createdAt,
  };
}

/**
 * Every plan the user has, newest first — active AND superseded, because
 * version history is the superseded chain. Summaries only; the equality
 * query needs no composite index (sorting happens here, per-user plan
 * counts are small).
 */
plansRouter.get("/", async (req: Request, res: Response): Promise<void> => {
  const uid = requireUid(req);
  const snapshot = await db()
    .collection(COLLECTIONS.plans)
    .where("ownerId", "==", uid)
    .limit(200)
    .get();
  const plans: PlanSummary[] = [];
  for (const doc of snapshot.docs) {
    const parsed = Plan.safeParse(doc.data());
    if (parsed.success) {
      plans.push(summarizePlanDoc(parsed.data));
    }
  }
  plans.sort((a, b) => b.createdAt.localeCompare(a.createdAt));
  res.json({ plans: plans.slice(0, 100) });
});

plansRouter.get("/:planId", async (req: Request, res: Response): Promise<void> => {
  const uid = requireUid(req);
  const planId = parseOrThrow(IdParam, req.params.planId, "plan id");
  const snapshot = await db().collection(COLLECTIONS.plans).doc(planId).get();
  const parsed = Plan.safeParse(snapshot.data());
  if (!parsed.success || parsed.data.ownerId !== uid) {
    throw new AppError(404, "not_found", "Plan not found.");
  }
  res.json(parsed.data);
});

/**
 * Links must address real schedule entries — a link to a coordinate the
 * plan doesn't have is a client bug, not data. Pure; exported for tests.
 */
export function invalidCalendarLinks(
  plan: Pick<Plan, "schedule">,
  events: readonly PlanCalendarEvent[],
): string[] {
  const coordinates = new Set(plan.schedule.map((e) => `${e.sessionId}@${e.dayOffset}`));
  return events
    .filter((event) => !coordinates.has(`${event.sessionId}@${event.dayOffset}`))
    .map((event) => `${event.sessionId}@${event.dayOffset}`);
}

plansRouter.post(
  "/:planId/calendar-events",
  async (req: Request, res: Response): Promise<void> => {
    const uid = requireUid(req);
    const planId = parseOrThrow(IdParam, req.params.planId, "plan id");
    const body = parseOrThrow(PlanCalendarEventsRequest, req.body, "calendar events");

    const snapshot = await db().collection(COLLECTIONS.plans).doc(planId).get();
    const parsed = Plan.safeParse(snapshot.data());
    // Missing and not-owned answer identically; foreign plans don't exist.
    if (!parsed.success || parsed.data.ownerId !== uid) {
      throw new AppError(404, "not_found", "Plan not found.");
    }
    if (parsed.data.status !== "active") {
      throw new AppError(409, "invalid_request", "Only the active plan can be scheduled.");
    }
    const unknown = invalidCalendarLinks(parsed.data, body.events);
    if (unknown.length > 0) {
      throw new AppError(
        400,
        "invalid_request",
        `Links reference schedule entries the plan does not have: ${unknown.slice(0, 5).join(", ")}`,
      );
    }

    await snapshot.ref.update({ calendarEvents: body.events });
    logInfo("plan_calendar_linked", {
      userId: uid,
      planId,
      events: body.events.length,
    });
    res.status(200).json({ stored: body.events.length });
  },
);
