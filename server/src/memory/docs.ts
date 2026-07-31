/**
 * Reading memory documents.
 *
 * The wire/API shape (the Zod Memory schema) carries no vector; Firestore
 * documents carry the embedding as a VectorValue in the same field. Every
 * read therefore goes through parseMemoryDoc, which separates the vector
 * from the validated Memory. Distance fields injected by vector queries are
 * stripped by Zod's default unknown-key behavior.
 *
 * The vector is recognized by shape (`toArray()`), not by `instanceof`:
 * firebase-admin does not re-export the VectorValue class, and an instanceof
 * against a second copy of @google-cloud/firestore would silently fail.
 */
import { Memory } from "@otto/shared";

export interface MemoryDoc {
  memory: Memory;
  /** The stored embedding, when present and well-formed. */
  vector: number[] | null;
}

function numberArray(value: unknown): number[] | null {
  return Array.isArray(value) && value.every((entry) => typeof entry === "number")
    ? (value as number[])
    : null;
}

function vectorFrom(embedding: unknown): number[] | null {
  const direct = numberArray(embedding);
  if (direct !== null) {
    return direct;
  }
  if (typeof embedding === "object" && embedding !== null && "toArray" in embedding) {
    const toArray = (embedding as { toArray: unknown }).toArray;
    if (typeof toArray === "function") {
      return numberArray((toArray as () => unknown).call(embedding));
    }
  }
  return null;
}

export function parseMemoryDoc(data: unknown): MemoryDoc | null {
  if (typeof data !== "object" || data === null) {
    return null;
  }
  const { embedding, ...rest } = data as { embedding?: unknown };
  const parsed = Memory.safeParse(rest);
  if (!parsed.success) {
    return null;
  }
  return { memory: parsed.data, vector: vectorFrom(embedding) };
}
