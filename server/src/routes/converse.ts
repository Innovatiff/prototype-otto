/**
 * POST /converse — the streamed round trip.
 *
 * Phase 0 stubs the LLM: the input text streams back word by word as SSE
 * `token` events with a delay between words, then `done`. Routing (classify →
 * selectTier) runs for real and every call writes a cost_events document.
 */
import { Router, type Request, type Response } from "express";
import { TurnRequest } from "@otto/shared";
import type { TurnEvent } from "@otto/shared";

import { parseOrThrow } from "../errors.js";
import { logInfo } from "../log.js";
import { requireUid } from "../middleware/auth.js";
import { classify } from "../router/classify.js";
import { estimateTokens, route, type RouteInput } from "../router/selectModel.js";
import { recordCostEvent } from "../telemetry/cost.js";

export const converseRouter = Router();

/** Milliseconds between streamed words — keeps the stream visibly incremental. */
const WORD_DELAY_MS = 40;

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
}

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
 * The Phase 0 LLM stub: streams `text` back word by word as `token` events
 * with `delayMs` between words, then emits `done` carrying `doneData`.
 * Whitespace runs collapse to single spaces.
 *
 * Stops (and skips `done`) as soon as the sink reports closed, so a client
 * disconnect never leaves a timer chain running. Returns the number of token
 * events written.
 */
export async function streamStubTurn(
  sink: EventSink,
  text: string,
  doneData: Record<string, unknown>,
  delayMs: number,
): Promise<number> {
  const words = text.split(/\s+/).filter((word) => word.length > 0);
  let written = 0;
  for (const [index, word] of words.entries()) {
    if (index > 0) {
      await sleep(delayMs);
    }
    if (sink.closed) {
      return written;
    }
    const token = index < words.length - 1 ? `${word} ` : word;
    sink.write(sseMessage({ type: "token", data: token }));
    written += 1;
  }
  if (!sink.closed) {
    sink.write(sseMessage({ type: "done", data: doneData }));
  }
  return written;
}

converseRouter.post("/", async (req: Request, res: Response): Promise<void> => {
  const uid = requireUid(req);
  const turn = parseOrThrow(TurnRequest, req.body, "turn request");

  const intent = classify(turn.text);
  const routeInput: RouteInput = {
    intent,
    utteranceLength: turn.text.length,
    // Phase 0 heuristics; real signals arrive with memory retrieval and the
    // planning pipeline in later phases.
    requiresMemory: intent === "question",
    requiresMultiStep: intent === "plan_request",
    contextTokens: estimateTokens(turn.text),
  };
  const decision = route(routeInput, { turnId: turn.turnId, userId: uid });

  res.status(200);
  res.setHeader("Content-Type", "text/event-stream");
  res.setHeader("Cache-Control", "no-cache, no-transform");
  res.setHeader("Connection", "keep-alive");
  // Tell buffering proxies not to batch events — flushing per event is the point.
  res.setHeader("X-Accel-Buffering", "no");
  res.flushHeaders();

  let clientGone = false;
  res.on("close", () => {
    clientGone = true;
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
  const tokenCount = await streamStubTurn(
    sink,
    turn.text,
    { turnId: turn.turnId, tier: decision.tier, model: decision.model },
    WORD_DELAY_MS,
  );
  const latencyMs = Date.now() - startedAt;
  const disconnected = clientGone;

  // Record telemetry before ending the response: Cloud Run only guarantees CPU
  // while a request is in flight. recordCostEvent never throws.
  await recordCostEvent({
    userId: uid,
    turnId: turn.turnId,
    tier: decision.tier,
    purpose: "converse",
    inputTokens: estimateTokens(turn.text),
    outputTokens: estimateTokens(turn.text), // the stub echoes its input
    cachedTokens: 0,
    latencyMs,
  });

  if (!res.writableEnded) {
    res.end();
  }

  logInfo("turn_completed", {
    turnId: turn.turnId,
    userId: uid,
    intent,
    tier: decision.tier,
    tokenCount,
    latencyMs,
    disconnected,
  });
});
