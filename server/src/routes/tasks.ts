/**
 * /tasks — full CRUD, every query scoped to the authenticated uid.
 *
 * Missing and not-owned documents both answer 404, so the API never confirms
 * that another user's document exists.
 */
import { Router, type Request, type Response } from "express";
import type { Query } from "firebase-admin/firestore";
import { Task, TaskStatus } from "@otto/shared";
import { z } from "zod";

import { AppError, IdParam, parseOrThrow } from "../errors.js";
import { COLLECTIONS, db } from "../firestore.js";
import { logWarning } from "../log.js";
import { requireUid } from "../middleware/auth.js";

export const tasksRouter = Router();

/** Fields a client may supply; the server owns id, ownerId, and createdAt. */
const TaskCreate = Task.omit({ id: true, ownerId: true, createdAt: true });
const TaskUpdate = TaskCreate.partial();

const TaskListQuery = z.object({
  status: TaskStatus.optional(),
  limit: z.coerce.number().int().min(1).max(200).default(50),
});

function tasksCollection() {
  return db().collection(COLLECTIONS.tasks);
}

/** Reads a task and verifies ownership; 404 for missing and not-owned alike. */
async function readOwnedTask(id: string, uid: string): Promise<Task> {
  const snapshot = await tasksCollection().doc(id).get();
  const data = snapshot.data();
  if (data === undefined) {
    throw new AppError(404, "not_found", "Task not found.");
  }
  const parsed = Task.safeParse(data);
  if (!parsed.success) {
    throw new AppError(500, "internal", "Stored task failed validation.");
  }
  if (parsed.data.ownerId !== uid) {
    throw new AppError(404, "not_found", "Task not found.");
  }
  return parsed.data;
}

tasksRouter.post("/", async (req: Request, res: Response): Promise<void> => {
  const uid = requireUid(req);
  const input = parseOrThrow(TaskCreate, req.body, "task");
  const ref = tasksCollection().doc();
  const task = Task.parse({
    ...input,
    id: ref.id,
    ownerId: uid,
    createdAt: new Date().toISOString(),
  });
  await ref.set(task);
  res.status(201).json(task);
});

tasksRouter.get("/", async (req: Request, res: Response): Promise<void> => {
  const uid = requireUid(req);
  const query = parseOrThrow(TaskListQuery, req.query, "query");
  let scoped: Query = tasksCollection().where("ownerId", "==", uid);
  if (query.status !== undefined) {
    scoped = scoped.where("status", "==", query.status);
  }
  // Equality filters + orderBy need the composite indexes in firestore.indexes.json.
  const snapshot = await scoped.orderBy("createdAt", "desc").limit(query.limit).get();
  const tasks: Task[] = [];
  for (const doc of snapshot.docs) {
    const parsed = Task.safeParse(doc.data());
    if (parsed.success) {
      tasks.push(parsed.data);
    } else {
      logWarning("corrupt_task_skipped", { id: doc.id });
    }
  }
  res.json({ tasks });
});

tasksRouter.get("/:id", async (req: Request, res: Response): Promise<void> => {
  const uid = requireUid(req);
  const id = parseOrThrow(IdParam, req.params.id, "task id");
  const task = await readOwnedTask(id, uid);
  res.json(task);
});

tasksRouter.patch("/:id", async (req: Request, res: Response): Promise<void> => {
  const uid = requireUid(req);
  const id = parseOrThrow(IdParam, req.params.id, "task id");
  const updates = parseOrThrow(TaskUpdate, req.body, "task update");
  if (Object.keys(updates).length === 0) {
    throw new AppError(400, "invalid_request", "Update body is empty.");
  }
  const existing = await readOwnedTask(id, uid);
  // id, ownerId, and createdAt are immutable: TaskUpdate cannot carry them
  // (Zod strips unknown keys), and re-pinning keeps that true regardless.
  const merged = Task.parse({
    ...existing,
    ...updates,
    id: existing.id,
    ownerId: existing.ownerId,
    createdAt: existing.createdAt,
  });
  await tasksCollection().doc(id).set(merged);
  res.json(merged);
});

tasksRouter.delete("/:id", async (req: Request, res: Response): Promise<void> => {
  const uid = requireUid(req);
  const id = parseOrThrow(IdParam, req.params.id, "task id");
  await readOwnedTask(id, uid);
  await tasksCollection().doc(id).delete();
  res.status(204).end();
});
