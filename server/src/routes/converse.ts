/**
 * POST /converse — the streamed round trip.
 *
 * Phase 1: the real model. Routing (classify → selectTier) picks the tier;
 * the turn goes to the Anthropic API and every text delta streams out as an
 * SSE `token` event the moment it arrives — nothing is buffered server-side.
 * `done` closes the turn, and real token counts land in cost_events.
 */
import { Router, type Request, type Response } from "express";
import { TurnRequest } from "@otto/shared";
import type { TurnEvent } from "@otto/shared";

import { AppError, parseOrThrow } from "../errors.js";
import { streamAssistantTurn, type LlmTurnResult } from "../llm/anthropic.js";
import { errorFields, logError, logInfo } from "../log.js";
import { requireUid } from "../middleware/auth.js";
import { classify } from "../router/classify.js";
import { estimateTokens, route, TIER_MODELS, type RouteInput } from "../router/selectModel.js";
import { recordCostEvent } from "../telemetry/cost.js";

export const converseRouter = Router();

/** Where SSE messages go. `closed` goes true when the client disconnects. */
export interface EventSink {
  write(chunk: string): void;
  readonly closed: boolean;
}

/**
 * One TurnEvent as one SSE message. JSON.stringify never emits raw newlines,
 * so the payload always fits a single `data:` line.
 */
export function sseMessage(event: TurnEvent): string {
  return `data: ${JSON.stringify(event)}\n\n`;
}

/**
 * Relays one model turn into the sink: each token is written as a `token`
 * event the moment `runTurn` produces it, then `done` (carrying the caller's
 * summary) once the turn completes.
 *
 * Token writes stop as soon as the sink closes — the route also aborts the
 * upstream call via its signal, this just guarantees nothing more is written
 * meanwhile. `done` is suppressed for a closed sink and for an aborted turn:
 * a turn that was cut off must not claim completion.
 */
export async function streamLlmTurn(
  sink: EventSink,
  runTurn: (onToken: (text: string) => void) => Promise<LlmTurnResult>,
  doneData: (result: LlmTurnResult) => Record<string, unknown>,
): Promise<{ tokensWritten: number; result: LlmTurnResult }> {
  let tokensWritten = 0;
  const result = await runTurn((text: string): void => {
    if (sink.closed || text.length === 0) {
      return;
    }
    sink.write(sseMessage({ type: "token", data: text }));
    tokensWritten += 1;
  });
  if (!sink.closed && !result.aborted) {
    sink.write(sseMessage({ type: "done", data: doneData(result) }));
  }
  return { tokensWritten, result };
}

converseRouter.post("/", async (req: Request, res: Response): Promise<void> => {
  const uid = requireUid(req);
  const turn = parseOrThrow(TurnRequest, req.body, "turn request");
  // The schema requires min(1), but whitespace-only slips through it and the
  // API rejects whitespace-only content — fail fast while a 400 can still be
  // a 400 (headers are not sent yet).
  const text = turn.text.trim();
  if (text.length === 0) {
    throw new AppError(400, "invalid_request", "Turn text is empty.");
  }

  const intent = classify(text);
  const routeInput: RouteInput = {
    intent,
    utteranceLength: text.length,
    // Phase 1 heuristics; real signals arrive with memory retrieval and the
    // planning pipeline in later phases.
    requiresMemory: intent === "question",
    requiresMultiStep: intent === "plan_request",
    contextTokens: estimateTokens(text),
  };
  const decision = route(routeInput, { turnId: turn.turnId, userId: uid });
  // local and pcc run on-device in a later phase. Until that path exists the
  // server answers those turns with sonnet; the routed tier is still logged
  // and recorded, so the intended mix stays visible in telemetry.
  const model = decision.model ?? TIER_MODELS.sonnet;

  res.status(200);
  res.setHeader("Content-Type", "text/event-stream");
  res.setHeader("Cache-Control", "no-cache, no-transform");
  res.setHeader("Connection", "keep-alive");
  // Tell buffering proxies not to batch events — flushing per event is the point.
  res.setHeader("X-Accel-Buffering", "no");
  res.flushHeaders();

  // A client disconnect aborts the upstream model call so generation (and
  // billing) stops with it. Barge-in arrives here as exactly this: the app
  // cancels the request, the socket closes, the model stops.
  const abort = new AbortController();
  let clientGone = false;
  res.on("close", () => {
    clientGone = true;
    abort.abort();
  });

  const sink: EventSink = {
    write: (chunk: string): void => {
      res.write(chunk);
    },
    get closed(): boolean {
      return clientGone || res.writableEnded;
    },
  };

  const startedAt = Date.now();
  try {
    const { tokensWritten, result } = await streamLlmTurn(
      sink,
      (onToken) =>
        streamAssistantTurn({
          model,
          userText: text,
          userId: uid,
          signal: abort.signal,
          onToken,
        }),
      (r) => ({
        turnId: turn.turnId,
        tier: decision.tier,
        model,
        stopReason: r.stopReason,
        usage: r.usage,
      }),
    );
    const latencyMs = Date.now() - startedAt;

    // Record telemetry before ending the response: Cloud Run only guarantees
    // CPU while a request is in flight. recordCostEvent never throws.
    await recordCostEvent({
      userId: uid,
      turnId: turn.turnId,
      tier: decision.tier,
      model,
      purpose: "converse",
      inputTokens: result.usage.inputTokens,
      outputTokens: result.usage.outputTokens,
      cacheReadTokens: result.usage.cacheReadTokens,
      cacheCreationTokens: result.usage.cacheCreationTokens,
      latencyMs,
    });

    logInfo("turn_completed", {
      turnId: turn.turnId,
      userId: uid,
      intent,
      tier: decision.tier,
      model,
      tokenEvents: tokensWritten,
      inputTokens: result.usage.inputTokens,
      outputTokens: result.usage.outputTokens,
      cacheReadTokens: result.usage.cacheReadTokens,
      cacheCreationTokens: result.usage.cacheCreationTokens,
      stopReason: result.stopReason,
      aborted: result.aborted,
      latencyMs,
      disconnected: clientGone,
    });
  } catch (err) {
    // SSE headers are long gone, so the failure travels in-band as an error
    // event. Details stay in the log — raw exception text never reaches a
    // client (same policy as errors.ts).
    logError("turn_failed", { turnId: turn.turnId, userId: uid, model, ...errorFields(err) });
    if (!sink.closed) {
      sink.write(
        sseMessage({
          type: "error",
          data: { code: "internal", message: "Otto could not reach the model." },
        }),
      );
    }
  } finally {
    if (!res.writableEnded) {
      res.end();
    }
  }
});
