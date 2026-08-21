/**
 * "Report a response": any Otto message can be flagged; reports land in a
 * server-only queue with the turn's context for review. Apple requires a
 * visible moderation path for generative output — this is it.
 */
import { Router, type Request, type Response } from "express";
import { z } from "zod";

import { parseOrThrow } from "../errors.js";
import { COLLECTIONS, db } from "../firestore.js";
import { logInfo } from "../log.js";
import { requireUid } from "../middleware/auth.js";

const Report = z.object({
  /** The Otto message being reported, verbatim. */
  content: z.string().min(1).max(4000),
  /** What the user said just before, when available. */
  context: z.string().max(4000).optional(),
});

export const moderationRouter = Router();

moderationRouter.post("/report", async (req: Request, res: Response): Promise<void> => {
  const uid = requireUid(req);
  const report = parseOrThrow(Report, req.body, "report");
  const ref = db().collection(COLLECTIONS.moderationReports).doc();
  await ref.set({
    id: ref.id,
    ownerId: uid,
    content: report.content,
    ...(report.context !== undefined ? { context: report.context } : {}),
    status: "open",
    createdAt: new Date().toISOString(),
  });
  logInfo("moderation_report", { userId: uid, reportId: ref.id });
  res.status(201).json({ reported: true });
});
