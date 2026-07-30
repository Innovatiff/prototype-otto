/**
 * Cost telemetry.
 *
 * One cost_events document per model call, plus a per-user daily rollup in
 * cost_daily. Both collections are server-only — Firestore rules deny all
 * client access.
 */
import { FieldValue, Timestamp } from "firebase-admin/firestore";

import { COLLECTIONS, db } from "../firestore.js";
import { errorFields, logError } from "../log.js";
import type { Tier } from "../router/selectModel.js";

export type CostPurpose = "converse" | "extract_memory" | "brief" | "plan";

export interface CostEventInput {
  userId: string;
  turnId: string;
  tier: Tier;
  purpose: CostPurpose;
  inputTokens: number;
  outputTokens: number;
  cachedTokens: number;
  latencyMs: number;
}

/**
 * Placeholder USD per million tokens. local and pcc never call the API, so
 * they are free by construction. Revisit when real model calls land.
 */
const USD_PER_MILLION_TOKENS: Readonly<Record<Tier, { input: number; output: number }>> = {
  local: { input: 0, output: 0 },
  pcc: { input: 0, output: 0 },
  sonnet: { input: 3, output: 15 },
  opus: { input: 15, output: 75 },
};

export function estimateCostUsd(tier: Tier, inputTokens: number, outputTokens: number): number {
  const rate = USD_PER_MILLION_TOKENS[tier];
  return (inputTokens * rate.input + outputTokens * rate.output) / 1_000_000;
}

/**
 * Writes the cost_events document and folds the call into cost_daily.
 *
 * cost_daily doc id is `${userId}_${date}`; `byTier` counts calls per tier
 * (cost per tier is derivable from cost_events; counts capture the routing mix
 * including the free tiers). FieldValue.increment keeps the rollup atomic, and
 * increment(0) materializes the untouched tiers so the document always carries
 * all four keys.
 *
 * Never throws: telemetry must not break a user-facing request.
 */
export async function recordCostEvent(event: CostEventInput): Promise<void> {
  const now = new Date();
  const estimatedCostUsd = estimateCostUsd(event.tier, event.inputTokens, event.outputTokens);
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
