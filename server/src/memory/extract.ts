/**
 * The write path: passive memory extraction after each turn.
 *
 * Fired with `void` from the converse route AFTER the response is complete —
 * the user never waits on this. Runs on the cheap tier (Haiku), plans its
 * writes against the user's existing memories, and never throws.
 *
 * Hard rules enforced here, not trusted to the model:
 *   - a memory with userEdited=true is never auto-overwritten: a
 *     contradicting fact is stored separately with conflictsWith set;
 *   - a normal supersede stamps supersededBy on the old memory so retrieval
 *     stops returning it (nothing is deleted);
 *   - exact duplicates are dropped.
 *
 * NOTE (Cloud Run): fire-and-forget work needs CPU after the response ends.
 * Fine on dev and CPU-always-allocated; a queue (Cloud Tasks) replaces this
 * when deployment hardening happens.
 */
import { FieldValue } from "firebase-admin/firestore";
import { Memory, MemoryCategory } from "@otto/shared";
import { z } from "zod";

import { COLLECTIONS, db } from "../firestore.js";
import { getAnthropicClient } from "../llm/anthropic.js";
import { errorFields, logInfo, logWarning } from "../log.js";
import { recordCostEvent } from "../telemetry/cost.js";
import { parseMemoryDoc } from "./docs.js";
import { embedTexts } from "./embed.js";

/** The cheap tier. Extraction quality does not need a frontier model. */
export const EXTRACTION_MODEL = "claude-haiku-4-5";

/** Confidence assigned to passively extracted facts (explicit saves get 1.0). */
export const EXTRACTED_CONFIDENCE = 0.8;

/** How many existing memories the extractor sees for contradiction checks. */
const EXISTING_MEMORY_LIMIT = 100;

/** Per-turn cap on new facts; more than this is the model over-extracting. */
const MAX_FACTS_PER_TURN = 10;

/** Verbatim from the product spec, plus the output shape. */
export const EXTRACTION_PROMPT = `Extract atomic facts worth remembering long-term. Return JSON only.
RULES
- One fact per entry. Never compound.
- Durable facts only. Not 'I'm tired today.' Yes 'I don't drink coffee after 2pm.'
- If a fact contradicts an existing memory, include supersedes: <id>.
- Return [] when nothing is worth storing. This is the common case.
- Categories: identity, schedule, preference, constraint, goal, context

Output: a JSON array, each entry {"category": "...", "content": "...", "supersedes": "<id, only when contradicting an existing memory>"}. No prose, no code fences.`;

export const ExtractedFact = z.object({
  category: MemoryCategory,
  content: z.string().min(1).max(500),
  supersedes: z.string().min(1).optional(),
});
export type ExtractedFact = z.infer<typeof ExtractedFact>;

/**
 * Tolerant parse of the model's reply: fences stripped, non-array rejected,
 * invalid entries dropped individually, capped.
 */
export function parseExtractionResponse(text: string): ExtractedFact[] {
  const stripped = text
    .trim()
    .replace(/^```(?:json)?\s*/i, "")
    .replace(/\s*```$/, "");
  let raw: unknown;
  try {
    raw = JSON.parse(stripped);
  } catch {
    return [];
  }
  if (!Array.isArray(raw)) {
    return [];
  }
  const facts: ExtractedFact[] = [];
  for (const entry of raw.slice(0, MAX_FACTS_PER_TURN)) {
    const parsed = ExtractedFact.safeParse(entry);
    if (parsed.success) {
      facts.push(parsed.data);
    }
  }
  return facts;
}

export interface PlannedCreate {
  memory: Memory;
}
export interface PlannedSupersede {
  /** Existing memory to stamp with supersededBy. */
  id: string;
  supersededBy: string;
}
export interface WritePlan {
  creates: PlannedCreate[];
  supersedes: PlannedSupersede[];
}

/**
 * Pure planning: which documents get written, given the model's facts and
 * the user's existing (non-superseded) memories. Enforces the userEdited
 * protection and drops duplicates and dangling supersede references.
 */
export function planMemoryWrites(
  facts: ExtractedFact[],
  existing: Memory[],
  input: { userId: string; turnId: string; now: Date; mintId: () => string },
): WritePlan {
  const byId = new Map(existing.map((memory) => [memory.id, memory]));
  const creates: PlannedCreate[] = [];
  const supersedes: PlannedSupersede[] = [];
  const nowIso = input.now.toISOString();

  for (const fact of facts) {
    const duplicate = existing.some(
      (memory) =>
        memory.category === fact.category &&
        memory.content.trim().toLowerCase() === fact.content.trim().toLowerCase(),
    );
    if (duplicate) {
      continue;
    }

    const id = input.mintId();
    const target = fact.supersedes !== undefined ? byId.get(fact.supersedes) : undefined;
    const memory: Memory = {
      id,
      ownerId: input.userId,
      category: fact.category,
      content: fact.content,
      confidence: EXTRACTED_CONFIDENCE,
      sourceTurnId: input.turnId,
      createdAt: nowIso,
      userEdited: false,
    };

    if (target !== undefined) {
      if (target.userEdited) {
        // Never auto-overwrite a user-edited memory: store alongside, flagged.
        memory.conflictsWith = target.id;
      } else {
        memory.supersedes = target.id;
        supersedes.push({ id: target.id, supersededBy: id });
      }
    }
    creates.push({ memory });
  }
  return { creates, supersedes };
}

export interface ExtractionInput {
  userId: string;
  turnId: string;
  userText: string;
  assistantText: string;
  now: Date;
}

/** The full async pass. Never throws; all failure is logged and dropped. */
export async function extractMemories(input: ExtractionInput): Promise<void> {
  const startedAt = Date.now();
  try {
    const collection = db().collection(COLLECTIONS.memories);
    const snapshot = await collection
      .where("ownerId", "==", input.userId)
      .orderBy("createdAt", "desc")
      .limit(EXISTING_MEMORY_LIMIT)
      .get();
    const existing = snapshot.docs
      .map((doc) => parseMemoryDoc(doc.data()))
      .filter((doc): doc is NonNullable<typeof doc> => doc !== null)
      .map((doc) => doc.memory)
      .filter((memory) => memory.supersededBy === undefined);

    const existingBlock =
      existing.length === 0
        ? "(none)"
        : existing
            .map(
              (memory) =>
                `${memory.id} · ${memory.category}${memory.userEdited ? " · edited-by-user" : ""} · ${memory.content}`,
            )
            .join("\n");

    const response = await getAnthropicClient().messages.create({
      model: EXTRACTION_MODEL,
      max_tokens: 1000,
      system: `${EXTRACTION_PROMPT}\n\nExisting memories:\n${existingBlock}`,
      messages: [
        {
          role: "user",
          content: `User: ${input.userText}\nOtto: ${input.assistantText}`,
        },
      ],
      metadata: { user_id: input.userId },
    });

    await recordCostEvent({
      userId: input.userId,
      turnId: input.turnId,
      tier: "background",
      model: EXTRACTION_MODEL,
      purpose: "extract_memory",
      inputTokens: response.usage.input_tokens,
      outputTokens: response.usage.output_tokens,
      cacheReadTokens: response.usage.cache_read_input_tokens ?? 0,
      cacheCreationTokens: response.usage.cache_creation_input_tokens ?? 0,
      latencyMs: Date.now() - startedAt,
    });

    const reply = response.content
      .filter((block) => block.type === "text")
      .map((block) => block.text)
      .join("");
    const facts = parseExtractionResponse(reply);
    if (facts.length === 0) {
      return;
    }

    const plan = planMemoryWrites(facts, existing, {
      userId: input.userId,
      turnId: input.turnId,
      now: input.now,
      mintId: () => collection.doc().id,
    });
    if (plan.creates.length === 0) {
      return;
    }

    // One Voyage call for all new contents; failure stores vector-less docs.
    let vectors: number[][] | null = null;
    try {
      vectors = await embedTexts(
        plan.creates.map((create) => create.memory.content),
        "document",
      );
    } catch (err) {
      logWarning("extraction_embedding_failed", { userId: input.userId, ...errorFields(err) });
    }

    const batch = db().batch();
    plan.creates.forEach((create, index) => {
      const vector = vectors?.[index];
      batch.set(collection.doc(create.memory.id), {
        ...create.memory,
        ...(vector !== undefined ? { embedding: FieldValue.vector(vector) } : {}),
      });
    });
    for (const supersede of plan.supersedes) {
      batch.update(collection.doc(supersede.id), { supersededBy: supersede.supersededBy });
    }
    await batch.commit();

    logInfo("memories_extracted", {
      userId: input.userId,
      turnId: input.turnId,
      created: plan.creates.length,
      superseded: plan.supersedes.length,
      conflicts: plan.creates.filter((create) => create.memory.conflictsWith !== undefined).length,
    });
  } catch (err) {
    logWarning("memory_extraction_failed", {
      userId: input.userId,
      turnId: input.turnId,
      ...errorFields(err),
    });
  }
}
