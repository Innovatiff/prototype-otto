/**
 * POST /brief — the day's bookends, one endpoint, three modes.
 *
 * morning (default): the classic brief. When the wake-time automation
 * already generated and stored today's (chapters + card), it is served
 * INSTANTLY — a push tap goes straight to voice, no gather, no sonnet.
 * Fresh generations store the playable halves so the next tap is instant.
 *
 * evening: the close-out — tomorrow's first thing, what slipped, one line
 * of closure. Short, never stored.
 *
 * weekly: the Sunday mirror — the week's numbers, counted in code.
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
import { gatherBriefContext, wallDate } from "./../brief/gather.js";
import { isServableBrief, loadBrief, storeBrief } from "./../brief/store.js";
import {
  BRIEF_MODEL,
  EVENING_SYSTEM_PROMPT,
  SUMMARY_MODEL,
  summarizeBrief,
  synthesizeBrief,
  WEEKLY_SYSTEM_PROMPT,
  type SynthesizedBrief,
} from "./../brief/synthesize.js";
import { gatherWeeklyFacts, weeklyFactsText } from "./../brief/weekly.js";

export const briefRouter = Router();

briefRouter.post("/", async (req: Request, res: Response): Promise<void> => {
  const uid = requireUid(req);
  const request = parseOrThrow(BriefRequest, req.body, "brief request");
  const mode = request.mode ?? "morning";
  const now = new Date();
  const startedAt = Date.now();
  const today = wallDate(now, request.timezone);

  // The instant path: today's brief already exists in full — play it.
  if (mode === "morning") {
    const stored = await loadBrief(uid, today).catch((): null => null);
    if (stored !== null && isServableBrief(stored, now)) {
      const payload: BriefResponse = {
        spoken: stored.spoken,
        card: stored.card,
        chapters: stored.chapters,
      };
      res.json(payload);
      logInfo("brief_served_stored", { userId: uid, date: today });
      return;
    }
  }

  const context = await gatherBriefContext(uid, request, now);

  let synthesis: SynthesizedBrief;
  if (mode === "evening") {
    synthesis = await synthesizeBrief(context, uid, { system: EVENING_SYSTEM_PROMPT });
  } else if (mode === "weekly") {
    const facts = await gatherWeeklyFacts(uid, now);
    synthesis = await synthesizeBrief(context, uid, {
      system: WEEKLY_SYSTEM_PROMPT,
      extraFacts: weeklyFactsText(facts),
    });
  } else {
    synthesis = await synthesizeBrief(context, uid);
  }

  await recordCostEvent({
    userId: uid,
    turnId: `brief-${mode}-${context.date}`,
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
    planSessions: context.planSessions,
  };

  const payload: BriefResponse = {
    spoken: synthesis.spoken,
    card,
    chapters: synthesis.chapters,
  };
  res.json(payload);

  // Continuity and the instant path both ride the background store —
  // morning only; close-outs and reviews are moments, not records.
  if (mode === "morning") {
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
          chapters: synthesis.chapters,
          card,
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
  }

  logInfo("brief_delivered", {
    userId: uid,
    mode,
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
