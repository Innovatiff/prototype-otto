/**
 * The read path: what Otto remembers going into a turn.
 *
 * Before each model call: embed the utterance, vector-search the user's
 * memories (top 8, cosine), always add every "identity" memory, dedupe, cap
 * the block at 800 tokens (identity first, then by similarity, newest first
 * on ties), and touch lastUsedAt on everything returned.
 *
 * Sits on the hot path — every failure degrades (identity-only, or nothing)
 * rather than delaying or breaking the turn.
 */
import { FieldValue } from "firebase-admin/firestore";
import type { Memory } from "@otto/shared";

import { COLLECTIONS, db } from "../firestore.js";
import { errorFields, logWarning } from "../log.js";
import { estimateTokens } from "../router/selectModel.js";
import { parseMemoryDoc } from "./docs.js";
import { tryEmbed } from "./embed.js";

export const RETRIEVAL_LIMIT = 8;
export const MEMORY_TOKEN_BUDGET = 800;

export interface SimilarMemory {
  memory: Memory;
  distance: number;
}

/** Cosine-distance order, newest first on ties. */
export function sortSimilar(candidates: SimilarMemory[]): Memory[] {
  return candidates
    .slice()
    .sort(
      (a, b) =>
        a.distance - b.distance || b.memory.createdAt.localeCompare(a.memory.createdAt),
    )
    .map((candidate) => candidate.memory);
}

/**
 * Pure selection: identity memories first (all of them, newest first), then
 * similar ones in their given order; deduped by id; superseded memories are
 * excluded; the whole block stays under the token budget.
 */
export function selectMemories(
  identity: Memory[],
  similar: Memory[],
  budget: number = MEMORY_TOKEN_BUDGET,
): Memory[] {
  const identityNewestFirst = identity
    .slice()
    .sort((a, b) => b.createdAt.localeCompare(a.createdAt));
  const selected: Memory[] = [];
  const seen = new Set<string>();
  let spent = 0;
  for (const memory of [...identityNewestFirst, ...similar]) {
    if (seen.has(memory.id) || memory.supersededBy !== undefined) {
      continue;
    }
    const cost = estimateTokens(`- [${memory.category}] ${memory.content}`);
    if (spent + cost > budget) {
      continue;
    }
    seen.add(memory.id);
    selected.push(memory);
    spent += cost;
  }
  return selected;
}

/** Everything Otto should remember for this utterance. Never throws. */
export async function retrieveMemories(
  uid: string,
  utterance: string,
  now: Date,
): Promise<Memory[]> {
  try {
    const collection = db().collection(COLLECTIONS.memories);

    const identityPromise = collection
      .where("ownerId", "==", uid)
      .where("category", "==", "identity")
      .orderBy("createdAt", "desc")
      .limit(50)
      .get();

    const vectorPromise = (async (): Promise<SimilarMemory[]> => {
      const vector = await tryEmbed(utterance, "query");
      if (vector === null) {
        return [];
      }
      const snapshot = await collection
        .where("ownerId", "==", uid)
        .findNearest({
          vectorField: "embedding",
          queryVector: FieldValue.vector(vector),
          limit: RETRIEVAL_LIMIT,
          distanceMeasure: "COSINE",
          distanceResultField: "vector_distance",
        })
        .get();
      const candidates: SimilarMemory[] = [];
      for (const doc of snapshot.docs) {
        const parsed = parseMemoryDoc(doc.data());
        if (parsed !== null) {
          const distance = doc.get("vector_distance") as unknown;
          candidates.push({
            memory: parsed.memory,
            distance: typeof distance === "number" ? distance : Number.MAX_SAFE_INTEGER,
          });
        }
      }
      return candidates;
    })();

    const [identitySnapshot, similarCandidates] = await Promise.all([
      identityPromise,
      vectorPromise,
    ]);
    const identity = identitySnapshot.docs
      .map((doc) => parseMemoryDoc(doc.data()))
      .filter((doc): doc is NonNullable<typeof doc> => doc !== null)
      .map((doc) => doc.memory);

    const selected = selectMemories(identity, sortSimilar(similarCandidates));

    if (selected.length > 0) {
      // Best-effort usage stamp; never on the critical path.
      const batch = db().batch();
      const nowIso = now.toISOString();
      for (const memory of selected) {
        batch.update(collection.doc(memory.id), { lastUsedAt: nowIso });
      }
      batch.commit().catch((err: unknown) => {
        logWarning("memory_last_used_update_failed", { userId: uid, ...errorFields(err) });
      });
    }
    return selected;
  } catch (err) {
    logWarning("memory_retrieval_failed", { userId: uid, ...errorFields(err) });
    return [];
  }
}
