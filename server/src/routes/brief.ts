/**
 * POST /brief — the morning brief.
 *
 * The client sends today's calendar (events + conflicts already computed in
 * Swift); the server gathers weather, due tasks, list counts, carried
 * memories, and yesterday's summary; sonnet synthesizes the spoken brief;
 * the structured card returns alongside for the screen. A short summary is
 * stored so tomorrow's brief can reference today's.
 */
import { Router, type Request, type Response } from "express";
import {
  BriefRequest,
  type BriefCard,
  type BriefRecord,
  type BriefResponse,
} from "@otto/shared";

import { parseOrThrow } from "../errors.js";
import { logInfo } from "../log.js";
import { requireUid } from "../middleware/auth.js";
import { recordCostEvent } from "../telemetry/cost.js";
import { gatherBriefContext } from "./../brief/gather.js";
import { storeBrief } from "./../brief/store.js";
import {
  BRIEF_MODEL,
  SUMMARY_MODEL,
  summarizeBrief,
  synthesizeBrief,
} from "./../brief/synthesize.js";

export const briefRouter = Router();

briefRouter.post("/", async (req: Request, res: Response): Promise<void> => {
  const uid = requireUid(req);
  const request = parseOrThrow(BriefRequest, req.body, "brief request");
  const now = new Date();
  const startedAt = Date.now();

  const context = await gatherBriefContext(uid, request, now);
  const synthesis = await synthesizeBrief(context, uid);

  await recordCostEvent({
    userId: uid,
    turnId: `brief-${context.date}`,
    tier: "sonnet",
    model: BRIEF_MODEL,
    purpose: "brief",
    inputTokens: synthesis.usage.inputTokens,
    outputTokens: synthesis.usage.outputTokens,
    cacheReadTokens: synthesis.usage.cacheReadTokens,
    cacheCreationTokens: synthesis.usage.cacheCreationTokens,
    latencyMs: Date.now() - startedAt,
  });

  const card: BriefCard = {
    date: context.date,
    weather: context.weather ?? undefined,
    events: request.events,
    conflicts: request.conflicts,
    dueTasks: context.dueTasks,
    lists: context.lists,
  };

  const payload: BriefResponse = {
    spoken: synthesis.spoken,
    card,
    chapters: synthesis.chapters,
  };
  res.json(payload);

  // Continuity happens off the response path: summarize on the cheap tier
  // and store for tomorrow. The user never waits on it.
  void (async (): Promise<void> => {
    const summaryStartedAt = Date.now();
    try {
      const { summary, usage } = await summarizeBrief(synthesis.spoken, uid);
      const record: BriefRecord = {
        ownerId: uid,
        date: context.date,
        spoken: synthesis.spoken,
        summary,
        createdAt: now.toISOString(),
      };
      await storeBrief(record);
      await recordCostEvent({
        userId: uid,
        turnId: `brief-${context.date}`,
        tier: "background",
        model: SUMMARY_MODEL,
        purpose: "brief",
        inputTokens: usage.inputTokens,
        outputTokens: usage.outputTokens,
        cacheReadTokens: usage.cacheReadTokens,
        cacheCreationTokens: usage.cacheCreationTokens,
        latencyMs: Date.now() - summaryStartedAt,
      });
    } catch {
      // storeBrief and recordCostEvent log their own failures; a summary
      // failure costs tomorrow's continuity, never today's brief.
    }
  })();

  logInfo("brief_delivered", {
    userId: uid,
    date: context.date,
    events: request.events.length,
    conflicts: request.conflicts.length,
    dueTasks: context.dueTasks.length,
    lists: context.lists.length,
    hadWeather: context.weather !== null,
    hadYesterday: context.yesterdaySummary !== null,
    spokenChars: synthesis.spoken.length,
  });
});
