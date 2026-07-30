/**
 * /memory — full CRUD, every query scoped to the authenticated uid.
 *
 * Same ownership contract as /tasks: missing and not-owned both answer 404.
 * (The "never auto-overwrite when userEdited" rule binds the Phase 2 memory
 * extractor, not this CRUD surface — a user editing their own memory through
 * here is exactly the case userEdited exists to record.)
 */
import { Router, type Request, type Response } from "express";
import type { Query } from "firebase-admin/firestore";
import { Memory, MemoryCategory } from "@otto/shared";
import { z } from "zod";

import { AppError, IdParam, parseOrThrow } from "../errors.js";
import { COLLECTIONS, db } from "../firestore.js";
import { logWarning } from "../log.js";
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
  const parsed = Memory.safeParse(data);
  if (!parsed.success) {
    throw new AppError(500, "internal", "Stored memory failed validation.");
  }
  if (parsed.data.ownerId !== uid) {
    throw new AppError(404, "not_found", "Memory not found.");
  }
  return parsed.data;
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
  await ref.set(memory);
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
    const parsed = Memory.safeParse(doc.data());
    if (parsed.success) {
      memories.push(parsed.data);
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
  await memoriesCollection().doc(id).set(merged);
  res.json(merged);
});

memoryRouter.delete("/:id", async (req: Request, res: Response): Promise<void> => {
  const uid = requireUid(req);
  const id = parseOrThrow(IdParam, req.params.id, "memory id");
  await readOwnedMemory(id, uid);
  await memoriesCollection().doc(id).delete();
  res.status(204).end();
});
