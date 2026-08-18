/**
 * /plans — calendar links only, for now. Plan CONTENT is immutable and
 * server-authored (generation and adaptation write it); this route stores
 * the one piece of operational bookkeeping the device owns: which EventKit
 * event each scheduled occurrence became, after the device verified the
 * write by reading it back. Step 9 adds the read endpoints for the plan UI.
 */
import { Router, type Request, type Response } from "express";
import { Plan, PlanCalendarEventsRequest, type PlanCalendarEvent } from "@otto/shared";

import { AppError, IdParam, parseOrThrow } from "../errors.js";
import { COLLECTIONS, db } from "../firestore.js";
import { logInfo } from "../log.js";
import { requireUid } from "../middleware/auth.js";

export const plansRouter = Router();

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
