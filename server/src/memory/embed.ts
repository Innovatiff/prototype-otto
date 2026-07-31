/**
 * Voyage AI embeddings (voyage-3-lite, 512 dimensions).
 *
 * Two call sites with opposite postures:
 *   - retrieval (input_type "query") sits on the hot path before the model
 *     call, so it is tightly time-capped and failure degrades to
 *     identity-only retrieval;
 *   - storage (input_type "document") runs in the async extraction pass,
 *     where failure just means a memory without a vector (still reachable
 *     through the identity path, re-embeddable later).
 */
import { z } from "zod";

import { errorFields, logWarning } from "../log.js";
import { getSecret } from "../secrets/index.js";

export const EMBEDDING_MODEL = "voyage-3-lite";
export const EMBEDDING_DIMENSION = 512;

const VOYAGE_URL = "https://api.voyageai.com/v1/embeddings";

/** Hot-path cap: a slow embed must not eat the 800ms voice budget. */
const TIMEOUT_MS = 2500;

export const VoyageResponse = z.object({
  data: z.array(
    z.object({
      embedding: z.array(z.number()).length(EMBEDDING_DIMENSION),
      index: z.number().int(),
    }),
  ),
});

export type EmbeddingInputType = "query" | "document";

/** Embeds a batch; order matches the input. Throws on any failure. */
export async function embedTexts(
  texts: string[],
  inputType: EmbeddingInputType,
): Promise<number[][]> {
  if (texts.length === 0) {
    return [];
  }
  const response = await fetch(VOYAGE_URL, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${getSecret("VOYAGE_API_KEY")}`,
    },
    body: JSON.stringify({ input: texts, model: EMBEDDING_MODEL, input_type: inputType }),
    signal: AbortSignal.timeout(TIMEOUT_MS),
  });
  if (!response.ok) {
    throw new Error(`Voyage embeddings failed: ${response.status}`);
  }
  const parsed = VoyageResponse.parse(await response.json());
  return parsed.data
    .slice()
    .sort((a, b) => a.index - b.index)
    .map((entry) => entry.embedding);
}

/** Single text, never throws; null means "proceed without a vector". */
export async function tryEmbed(
  text: string,
  inputType: EmbeddingInputType,
): Promise<number[] | null> {
  try {
    const [vector] = await embedTexts([text], inputType);
    return vector ?? null;
  } catch (err) {
    logWarning("embedding_failed", { inputType, ...errorFields(err) });
    return null;
  }
}
