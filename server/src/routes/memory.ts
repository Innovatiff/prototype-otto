/**
 * /memory — full CRUD, every query scoped to the authenticated uid.
 *
 * Same ownership contract as /tasks: missing and not-owned both answer 404.
 * (The "never auto-overwrite when userEdited" rule binds the Phase 2 memory
 * extractor, not this CRUD surface — a user editing their own memory through
 * here is exactly the case userEdited exists to record.)
 */
import { Router, type Request, type Response } from "express";
import { FieldValue, type Query } from "firebase-admin/firestore";
import { Memory, MemoryCategory } from "@otto/shared";
import { z } from "zod";

import { AppError, IdParam, parseOrThrow } from "../errors.js";
import { COLLECTIONS, db } from "../firestore.js";
import { logInfo, logWarning } from "../log.js";
import { parseMemoryDoc } from "../memory/docs.js";
import { tryEmbed } from "../memory/embed.js";
import { requireUid } from "../middleware/auth.js";

export const memoryRouter = Router();

/** Fields a client may supply; the server owns id, ownerId, and createdAt. */
const MemoryCreate = Memory.omit({ id: true, ownerId: true, createdAt: true });
const MemoryUpdate = MemoryCreate.partial();

const MemoryListQuery = z.object({
  category: MemoryCategory.optional(),
  limit: z.coerce.number().int().min(1).max(200).default(50),
});

function memoriesCollection() {
  return db().collection(COLLECTIONS.memories);
}

/** Reads a memory and verifies ownership; 404 for missing and not-owned alike. */
async function readOwnedMemory(id: string, uid: string): Promise<Memory> {
  const snapshot = await memoriesCollection().doc(id).get();
  const data = snapshot.data();
  if (data === undefined) {
    throw new AppError(404, "not_found", "Memory not found.");
  }
  // parseMemoryDoc separates the stored VectorValue embedding from the wire
  // shape — the vector never leaves the server.
  const parsed = parseMemoryDoc(data);
  if (parsed === null) {
    throw new AppError(500, "internal", "Stored memory failed validation.");
  }
  if (parsed.memory.ownerId !== uid) {
    throw new AppError(404, "not_found", "Memory not found.");
  }
  return parsed.memory;
}

memoryRouter.post("/", async (req: Request, res: Response): Promise<void> => {
  const uid = requireUid(req);
  const input = parseOrThrow(MemoryCreate, req.body, "memory");
  const ref = memoriesCollection().doc();
  const memory = Memory.parse({
    ...input,
    id: ref.id,
    ownerId: uid,
    createdAt: new Date().toISOString(),
  });
  // Embed for vector retrieval; a failure stores the memory without a vector.
  const vector = await tryEmbed(memory.content, "document");
  await ref.set({
    ...memory,
    ...(vector !== null ? { embedding: FieldValue.vector(vector) } : {}),
  });
  res.status(201).json(memory);
});

memoryRouter.get("/", async (req: Request, res: Response): Promise<void> => {
  const uid = requireUid(req);
  const query = parseOrThrow(MemoryListQuery, req.query, "query");
  let scoped: Query = memoriesCollection().where("ownerId", "==", uid);
  if (query.category !== undefined) {
    scoped = scoped.where("category", "==", query.category);
  }
  // Equality filters + orderBy need the composite indexes in firestore.indexes.json.
  const snapshot = await scoped.orderBy("createdAt", "desc").limit(query.limit).get();
  const memories: Memory[] = [];
  for (const doc of snapshot.docs) {
    const parsed = parseMemoryDoc(doc.data());
    if (parsed !== null) {
      memories.push(parsed.memory);
    } else {
      logWarning("corrupt_memory_skipped", { id: doc.id });
    }
  }
  res.json({ memories });
});

memoryRouter.get("/:id", async (req: Request, res: Response): Promise<void> => {
  const uid = requireUid(req);
  const id = parseOrThrow(IdParam, req.params.id, "memory id");
  const memory = await readOwnedMemory(id, uid);
  res.json(memory);
});

memoryRouter.patch("/:id", async (req: Request, res: Response): Promise<void> => {
  const uid = requireUid(req);
  const id = parseOrThrow(IdParam, req.params.id, "memory id");
  const updates = parseOrThrow(MemoryUpdate, req.body, "memory update");
  if (Object.keys(updates).length === 0) {
    throw new AppError(400, "invalid_request", "Update body is empty.");
  }
  const existing = await readOwnedMemory(id, uid);
  const merged = Memory.parse({
    ...existing,
    ...updates,
    id: existing.id,
    ownerId: existing.ownerId,
    createdAt: existing.createdAt,
  });
  // Changed content needs a fresh vector or similarity search would keep
  // matching the old wording; unchanged content keeps the stored vector
  // (set with merge preserves fields we do not name).
  const contentChanged = merged.content !== existing.content;
  const vector = contentChanged ? await tryEmbed(merged.content, "document") : null;
  await memoriesCollection()
    .doc(id)
    .set(
      {
        ...merged,
        ...(vector !== null ? { embedding: FieldValue.vector(vector) } : {}),
      },
      { merge: true },
    );
  res.json(merged);
});

/**
 * Deletes every memory the caller owns — the memory screen's "Delete all",
 * which confirms client-side first. Batched under Firestore's 500-write cap.
 */
memoryRouter.delete("/", async (req: Request, res: Response): Promise<void> => {
  const uid = requireUid(req);
  let deleted = 0;
  for (;;) {
    const snapshot = await memoriesCollection().where("ownerId", "==", uid).limit(450).get();
    if (snapshot.empty) {
      break;
    }
    const batch = db().batch();
    for (const doc of snapshot.docs) {
      batch.delete(doc.ref);
    }
    await batch.commit();
    deleted += snapshot.size;
  }
  logInfo("memories_deleted_all", { userId: uid, deleted });
  res.json({ deleted });
});

memoryRouter.delete("/:id", async (req: Request, res: Response): Promise<void> => {
  const uid = requireUid(req);
  const id = parseOrThrow(IdParam, req.params.id, "memory id");
  await readOwnedMemory(id, uid);
  await memoriesCollection().doc(id).delete();
  res.status(204).end();
});
