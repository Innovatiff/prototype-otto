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
import { streamAssistantTurn, type LlmMessage, type LlmTurnResult } from "../llm/anthropic.js";
import { errorFields, logError, logInfo } from "../log.js";
import { extractMemories } from "../memory/extract.js";
import { retrieveMemories } from "../memory/retrieve.js";
import { requireUid } from "../middleware/auth.js";
import { addressTermAllowed, buildSystemPrompt } from "../persona/system.js";
import { classify } from "../router/classify.js";
import { estimateTokens, route, TIER_MODELS, type RouteInput } from "../router/selectModel.js";
import { cachedCurrentWeather } from "../services/weather/index.js";
import { appendExchange, loadOrCreateSession } from "../sessions/index.js";
import { recordCostEvent } from "../telemetry/cost.js";
import { executeToolUse, loadTasks } from "../tools/execute.js";
import { loadUserProfile } from "../users/index.js";

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

  // Session, profile, and retrieved memories ride on every model call —
  // loaded in parallel (retrieval includes an embedding round trip). Loading
  // before routing lets contextTokens reflect the real payload size.
  const now = new Date();
  const [session, user, memories, activeTasks, weather] = await Promise.all([
    loadOrCreateSession(uid, turn.sessionId, now),
    loadUserProfile(uid, now),
    retrieveMemories(uid, text, now),
    loadTasks(uid).catch((err: unknown) => {
      logError("active_tasks_load_failed", { userId: uid, ...errorFields(err) });
      return [];
    }),
    // 10-minute cache; never throws. Weather in the dynamic block answers
    // "what's the weather like?" with no tool call.
    cachedCurrentWeather(),
  ]);
  const messages: LlmMessage[] = [
    ...session.messages.map((m): LlmMessage => ({ role: m.role, content: m.content })),
    { role: "user", content: text },
  ];

  // The persona, in two parts around the cache breakpoint.
  const prompt = buildSystemPrompt(user, memories, activeTasks, {
    now,
    timezone: turn.timezone,
    addressAllowed: addressTermAllowed(user.addressTerm, session.messages),
    events: turn.events ?? [],
    weather,
  });

  const intent = classify(text);
  const routeInput: RouteInput = {
    intent,
    utteranceLength: text.length,
    // Phase 1 heuristics; real signals arrive with memory retrieval and the
    // planning pipeline in later phases.
    requiresMemory: intent === "question",
    requiresMultiStep: intent === "plan_request",
    contextTokens: messages.reduce((sum, m) => sum + estimateTokens(m.content), 0),
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
  // Accumulated as it streams — for the session document, not for the wire;
  // every delta still goes straight out through onToken.
  let assistantText = "";
  try {
    const { tokensWritten, result } = await streamLlmTurn(
      sink,
      (onToken) =>
        streamAssistantTurn({
          model,
          system: prompt,
          messages,
          userId: uid,
          signal: abort.signal,
          onToken: (delta: string): void => {
            assistantText += delta;
            onToken(delta);
          },
          // Tool calls execute here, scoped to this uid; task/draft events go
          // straight onto the SSE stream between text tokens.
          onToolUse: (name, toolInput) =>
            executeToolUse(name, toolInput, {
              uid,
              turnId: turn.turnId,
              now: new Date(),
              emit: (event): void => {
                if (!sink.closed) {
                  sink.write(sseMessage(event));
                }
              },
            }),
        }),
      (r) => ({
        turnId: turn.turnId,
        sessionId: session.sessionId,
        tier: decision.tier,
        model,
        stopReason: r.stopReason,
        usage: r.usage,
      }),
    );
    const latencyMs = Date.now() - startedAt;

    // The exchange enters session memory even when the turn was barged into —
    // the user heard part of it, so context-wise it happened. A turn that
    // produced no text at all is not remembered (and an empty assistant
    // message would be rejected by the API on the next call anyway).
    if (assistantText.trim().length > 0) {
      await appendExchange({
        session,
        userId: uid,
        userText: text,
        assistantText,
        now: new Date(),
      });
      // Passive memory extraction: deliberately un-awaited — the spoken
      // response must never wait on it. extractMemories catches everything
      // internally.
      void extractMemories({
        userId: uid,
        turnId: turn.turnId,
        userText: text,
        assistantText,
        now: new Date(),
      });
    }

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
      sessionId: session.sessionId,
      historyMessages: session.messages.length,
      intent,
      tier: decision.tier,
      model,
      tokenEvents: tokensWritten,
      toolCalls: result.toolCalls,
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
