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
  SessionRecord,
  SessionRecordUpload,
  type PlanCalendarEvent,
  type PlanProgressSummary,
  type PlanSummary,
} from "@otto/shared";

import { AppError, IdParam, parseOrThrow } from "../errors.js";
import { COLLECTIONS, db } from "../firestore.js";
import { logInfo } from "../log.js";
import { requireUid } from "../middleware/auth.js";
import { loadSessionRecords, saveSessionRecord } from "../plans/store.js";

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
  const plan = await readOwnedPlan(planId, uid);
  res.json(plan);
});

async function readOwnedPlan(planId: string, uid: string): Promise<Plan> {
  const snapshot = await db().collection(COLLECTIONS.plans).doc(planId).get();
  const parsed = Plan.safeParse(snapshot.data());
  if (!parsed.success || parsed.data.ownerId !== uid) {
    throw new AppError(404, "not_found", "Plan not found.");
  }
  return parsed.data;
}

// ── Session records: the adaptation loop's raw material ─────────────

/**
 * The device reports a finished guided session. Records are additive and
 * idempotent enough for the offline outbox: a retry after a lost response
 * just writes a second record with a fresh id — rare, and harmless to the
 * aggregates compared to losing a session.
 */
plansRouter.post("/:planId/sessions", async (req: Request, res: Response): Promise<void> => {
  const uid = requireUid(req);
  const planId = parseOrThrow(IdParam, req.params.planId, "plan id");
  const upload = parseOrThrow(SessionRecordUpload, req.body, "session record");
  const plan = await readOwnedPlan(planId, uid);
  if (!plan.sessions.some((session) => session.id === upload.sessionId)) {
    throw new AppError(400, "invalid_request", "Unknown session template for this plan.");
  }
  const record = SessionRecord.parse({
    ...upload,
    id: db().collection(COLLECTIONS.sessionRecords).doc().id,
    ownerId: uid,
    planId,
  });
  await saveSessionRecord(record);
  res.status(201).json({ id: record.id });
});

/**
 * The adherence math, pure: what was scheduled against what happened.
 * "Missed" counts scheduled occurrences whose day fully passed with no
 * record that week; a partial (ended-early) session still counts as
 * showing up.
 */
export function summarizeRecords(
  plan: Plan,
  records: readonly SessionRecord[],
  now: Date,
): PlanProgressSummary {
  const startMs = new Date(plan.createdAt).getTime();
  const elapsedDays = Math.max(0, Math.floor((now.getTime() - startMs) / 86_400_000));
  const scheduledToDate = plan.schedule.filter((entry) => entry.dayOffset < elapsedDays).length;

  const weekAgoMs = now.getTime() - 7 * 86_400_000;
  const scheduledThisWeek = plan.schedule.filter((entry) => {
    const dayMs = startMs + entry.dayOffset * 86_400_000;
    return dayMs >= weekAgoMs && entry.dayOffset < elapsedDays;
  }).length;
  const attendedThisWeek = records.filter(
    (record) => new Date(record.completedAt).getTime() >= weekAgoMs,
  ).length;

  const skipCounts = new Map<string, number>();
  for (const record of records) {
    for (const stepId of new Set(record.skippedSteps)) {
      skipCounts.set(stepId, (skipCounts.get(stepId) ?? 0) + 1);
    }
  }
  const substitutionCandidates = [...skipCounts.entries()]
    .filter(([, skips]) => skips >= 2)
    .sort((a, b) => b[1] - a[1])
    .map(([stepId, skips]) => ({ stepId, skips }));

  // Newest wins: walk oldest → newest so later sessions overwrite.
  const latestLoggedValues: Record<string, string> = {};
  const chronological = [...records].sort((a, b) => a.completedAt.localeCompare(b.completedAt));
  for (const record of chronological) {
    for (const [stepId, value] of Object.entries(record.loggedValues)) {
      latestLoggedValues[stepId] = value;
    }
  }

  const lastCompletedAt = records
    .map((record) => record.completedAt)
    .sort()
    .at(-1);

  return {
    planId: plan.id,
    records: records.length,
    scheduledToDate,
    missedToDate: Math.max(0, scheduledToDate - records.length),
    missedThisWeek: Math.max(0, scheduledThisWeek - attendedThisWeek),
    ...(lastCompletedAt !== undefined ? { lastCompletedAt } : {}),
    substitutionCandidates,
    latestLoggedValues,
  };
}

plansRouter.get("/:planId/summary", async (req: Request, res: Response): Promise<void> => {
  const uid = requireUid(req);
  const planId = parseOrThrow(IdParam, req.params.planId, "plan id");
  const plan = await readOwnedPlan(planId, uid);
  const records = await loadSessionRecords(uid, planId, 200);
  res.json(summarizeRecords(plan, records, new Date()));
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
