import { z } from "zod";
import { isoDateTime, zId } from "./common.js";

/** The kind of fact a memory records. */
export const MemoryCategory = z.enum([
  "identity",
  "schedule",
  "preference",
  "constraint",
  "goal",
  "context",
]);
export type MemoryCategory = z.infer<typeof MemoryCategory>;

/**
 * One atomic thing Otto knows about the user.
 *
 * `content` must always be a single, atomic fact — never compound. Compound
 * statements are split into multiple Memory documents upstream.
 */
export const Memory = z.object({
  id: zId,
  ownerId: zId,
  category: MemoryCategory,
  /** ONE atomic fact, never compound. */
  content: z.string().min(1),
  embedding: z.array(z.number()).optional(),
  confidence: z.number().min(0).max(1),
  sourceTurnId: zId,
  /** id of a memory this replaces. */
  supersedes: zId.optional(),
  /** Set on the OLD memory when a newer one replaced it; retrieval skips these. */
  supersededBy: zId.optional(),
  /**
   * Set when this fact contradicts a userEdited memory: the edited one is
   * never auto-overwritten, so the new fact is stored alongside and flagged.
   */
  conflictsWith: zId.optional(),
  createdAt: isoDateTime,
  lastUsedAt: isoDateTime.optional(),
  /** When true, Otto must never auto-overwrite this memory. */
  userEdited: z.boolean().default(false),
});
export type Memory = z.infer<typeof Memory>;
