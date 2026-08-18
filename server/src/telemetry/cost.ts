/**
 * Cost telemetry.
 *
 * One cost_events document per model call, plus a per-user daily rollup in
 * cost_daily. Both collections are server-only — Firestore rules deny all
 * client access.
 */
import { FieldValue, Timestamp } from "firebase-admin/firestore";

import { COLLECTIONS, db } from "../firestore.js";
import { errorFields, logError, logWarning } from "../log.js";
import type { Tier } from "../router/selectModel.js";

export type CostPurpose = "converse" | "extract_memory" | "brief" | "plan" | "adapt";

export interface CostEventInput {
  userId: string;
  turnId: string;
  /**
   * The router's choice for this turn — the routing mix, not the bill.
   * "background" marks off-turn work (memory extraction) that never went
   * through routing; it counts in no byTier bucket.
   */
  tier: Tier | "background";
  /**
   * The model actually called. null means no API call was made (the future
   * on-device tiers), which is free by construction. This can differ from the
   * tier's own model while local/pcc fall back to sonnet server-side.
   */
  model: string | null;
  purpose: CostPurpose;
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cacheCreationTokens: number;
  latencyMs: number;
}

/**
 * Anthropic sticker prices, USD per million tokens. Sonnet 5 launch pricing
 * ($2/$10 through 2026-08-31) means real bills run a third lower until then;
 * the sticker rate is the stable, conservative estimate.
 */
const USD_PER_MILLION_TOKENS: Readonly<Record<string, { input: number; output: number }>> = {
  "claude-sonnet-5": { input: 3, output: 15 },
  "claude-opus-5": { input: 5, output: 25 },
  "claude-haiku-4-5": { input: 1, output: 5 },
};

/** Cache reads bill at 0.1x the input rate; 5-minute cache writes at 1.25x. */
const CACHE_READ_MULTIPLIER = 0.1;
const CACHE_WRITE_MULTIPLIER = 1.25;

export interface TokenCounts {
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cacheCreationTokens: number;
}

/**
 * Estimated USD for one call. Unknown model strings estimate to zero — the
 * caller warns so a new model can't silently record free calls.
 */
export function estimateCostUsd(model: string | null, tokens: TokenCounts): number {
  if (model === null) {
    return 0;
  }
  const rate = USD_PER_MILLION_TOKENS[model];
  if (rate === undefined) {
    return 0;
  }
  const inputUsd =
    tokens.inputTokens * rate.input +
    tokens.cacheReadTokens * rate.input * CACHE_READ_MULTIPLIER +
    tokens.cacheCreationTokens * rate.input * CACHE_WRITE_MULTIPLIER;
  return (inputUsd + tokens.outputTokens * rate.output) / 1_000_000;
}

/**
 * Writes the cost_events document and folds the call into cost_daily.
 *
 * cost_daily doc id is `${userId}_${date}`; `byTier` counts calls per routed
 * tier (dollars follow the model actually called; the counts capture the
 * routing mix including the tiers that will one day be free). FieldValue
 * .increment keeps the rollup atomic, and increment(0) materializes the
 * untouched tiers so the document always carries all four keys.
 *
 * Never throws: telemetry must not break a user-facing request.
 */
export async function recordCostEvent(event: CostEventInput): Promise<void> {
  const now = new Date();
  if (event.model !== null && USD_PER_MILLION_TOKENS[event.model] === undefined) {
    logWarning("cost_rate_missing", { model: event.model, turnId: event.turnId });
  }
  const estimatedCostUsd = estimateCostUsd(event.model, event);
  const date = now.toISOString().slice(0, 10);
  try {
    const database = db();
    const eventRef = database.collection(COLLECTIONS.costEvents).doc();
    const dailyRef = database.collection(COLLECTIONS.costDaily).doc(`${event.userId}_${date}`);

    const batch = database.batch();
    batch.set(eventRef, {
      ...event,
      estimatedCostUsd,
      timestamp: Timestamp.fromDate(now),
    });
    batch.set(
      dailyRef,
      {
        userId: event.userId,
        date,
        totalCostUsd: FieldValue.increment(estimatedCostUsd),
        callCount: FieldValue.increment(1),
        byTier: {
          local: FieldValue.increment(event.tier === "local" ? 1 : 0),
          pcc: FieldValue.increment(event.tier === "pcc" ? 1 : 0),
          sonnet: FieldValue.increment(event.tier === "sonnet" ? 1 : 0),
          opus: FieldValue.increment(event.tier === "opus" ? 1 : 0),
        },
      },
      { merge: true },
    );
    await batch.commit();
  } catch (err) {
    logError("cost_event_write_failed", {
      userId: event.userId,
      turnId: event.turnId,
      tier: event.tier,
      purpose: event.purpose,
      ...errorFields(err),
    });
  }
}
