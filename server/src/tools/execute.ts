/**
 * Tool execution — what actually happens when the model calls a tool.
 *
 * Every executor is scoped to the authenticated uid, returns a compact JSON
 * string for the model to speak from, and emits TurnEvents so the client can
 * render what changed. A failed or invalid call comes back as an is_error
 * tool result — the model recovers verbally; nothing throws through the
 * stream.
 */
import { FieldValue } from "firebase-admin/firestore";
import {
  isoDateTime,
  Memory,
  MemoryCategory,
  Task,
  TaskIntent,
  TaskStatus,
  zId,
  type ListItem,
  type TurnEvent,
} from "@otto/shared";
import { z } from "zod";

import { COLLECTIONS, db } from "../firestore.js";
import { errorFields, logInfo, logWarning } from "../log.js";
import { tryEmbed } from "../memory/embed.js";
import { adaptPlan, PlanAdaptationError } from "../plans/adapt.js";
import { generatePlan, PlanGenerationError } from "../plans/generate.js";
import { PlanConstraints, PlanDomain } from "../plans/interview.js";
import { loadActivePlan, saveNewPlan } from "../plans/store.js";
import { summaryLine } from "../plans/summarize.js";

// ── Inputs (mirror tools/definitions.ts; the model is validated, not trusted) ──

export const CreateTaskInput = z.object({
  intent: z.enum(["reminder", "list", "capture"]),
  title: z.string().min(1).max(200),
  items: z.array(z.string().min(1).max(200)).max(50).optional(),
  context: z.string().min(1).max(100).optional(),
  triggerAt: isoDateTime.optional(),
});

export const QueryTasksInput = z.object({
  intent: TaskIntent.optional(),
  context: z.string().min(1).max(100).optional(),
  status: TaskStatus.optional(),
});

export const UpdateTaskItemsInput = z.object({
  taskId: zId,
  check: z.array(z.string().min(1)).max(50).optional(),
  uncheck: z.array(z.string().min(1)).max(50).optional(),
  add: z.array(z.string().min(1).max(200)).max(50).optional(),
});

export const CompleteTaskInput = z.object({ taskId: zId });

export const SaveMemoryInput = z.object({
  category: MemoryCategory,
  content: z.string().min(1).max(500),
});

export const DraftMessageInput = z.object({
  recipientName: z.string().min(1).max(100),
  body: z.string().min(1).max(2000),
});

export const ProposeCalendarEventInput = z.object({
  title: z.string().min(1).max(200),
  startsAt: isoDateTime,
  endsAt: isoDateTime,
  location: z.string().min(1).max(200).optional(),
  notes: z.string().max(1000).optional(),
});

export const ProposeCalendarMoveInput = z.object({
  eventTitle: z.string().min(1).max(200),
  newStartsAt: isoDateTime,
  newEndsAt: isoDateTime.optional(),
});

// ── Fuzzy item matching (pure, tested) ──────────────────────────────

/** Lowercase, punctuation stripped, articles dropped, whitespace collapsed. */
export function normalizeItemText(text: string): string {
  return text
    .toLowerCase()
    .replace(/[^\p{L}\p{N}\s]/gu, " ")
    .replace(/\b(the|a|an|some|my)\b/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function singular(text: string): string {
  return text.endsWith("s") ? text.slice(0, -1) : text;
}

/**
 * First item matching the spoken reference: exact normalized match, then
 * containment either way, then naive singular/plural. Null when nothing
 * plausibly matches.
 */
export function matchItem(items: readonly ListItem[], reference: string): ListItem | null {
  const ref = normalizeItemText(reference);
  if (ref.length === 0) {
    return null;
  }
  for (const item of items) {
    if (normalizeItemText(item.text) === ref) {
      return item;
    }
  }
  for (const item of items) {
    const norm = normalizeItemText(item.text);
    if (norm.includes(ref) || ref.includes(norm)) {
      return item;
    }
  }
  for (const item of items) {
    if (singular(normalizeItemText(item.text)) === singular(ref)) {
      return item;
    }
  }
  return null;
}

export interface ItemUpdateResult {
  items: ListItem[];
  checked: string[];
  unchecked: string[];
  added: string[];
  notFound: string[];
  openCount: number;
}

/** Applies check/uncheck/add against a task's items. Pure. */
export function applyItemUpdates(
  items: readonly ListItem[],
  input: { check?: string[]; uncheck?: string[]; add?: string[] },
  now: Date,
  mintId: () => string,
): ItemUpdateResult {
  const next = items.map((item) => ({ ...item }));
  const checked: string[] = [];
  const unchecked: string[] = [];
  const notFound: string[] = [];

  for (const reference of input.check ?? []) {
    const match = matchItem(next, reference);
    if (match === null) {
      notFound.push(reference);
    } else {
      const item = next.find((candidate) => candidate.id === match.id);
      if (item !== undefined) {
        item.checked = true;
        checked.push(item.text);
      }
    }
  }
  for (const reference of input.uncheck ?? []) {
    const match = matchItem(next, reference);
    if (match === null) {
      notFound.push(reference);
    } else {
      const item = next.find((candidate) => candidate.id === match.id);
      if (item !== undefined) {
        item.checked = false;
        unchecked.push(item.text);
      }
    }
  }
  const added: string[] = [];
  for (const text of input.add ?? []) {
    // Adding an item that already exists un-checks it instead of duplicating.
    const existing = matchItem(next, text);
    if (existing !== null) {
      const item = next.find((candidate) => candidate.id === existing.id);
      if (item !== undefined && item.checked) {
        item.checked = false;
        unchecked.push(item.text);
      }
      continue;
    }
    next.push({ id: mintId(), text, checked: false, addedAt: now.toISOString() });
    added.push(text);
  }
  return {
    items: next,
    checked,
    unchecked,
    added,
    notFound,
    openCount: next.filter((item) => !item.checked).length,
  };
}

// ── Execution ───────────────────────────────────────────────────────

export interface ToolExecution {
  /** Compact JSON the model speaks from. */
  result: string;
  isError?: boolean;
}

export interface ToolContext {
  uid: string;
  turnId: string;
  now: Date;
  /** Emits a TurnEvent onto the SSE stream (no-op once the client is gone). */
  emit: (event: TurnEvent) => void;
}

function tasksCollection() {
  return db().collection(COLLECTIONS.tasks);
}

function failure(message: string): ToolExecution {
  return { result: JSON.stringify({ error: message }), isError: true };
}

/** Reads a task and verifies ownership; null for missing and foreign alike. */
async function readOwnedTask(taskId: string, uid: string): Promise<Task | null> {
  const snapshot = await tasksCollection().doc(taskId).get();
  const parsed = Task.safeParse(snapshot.data());
  return parsed.success && parsed.data.ownerId === uid ? parsed.data : null;
}

/** Active tasks for the dynamic prompt block and query_tasks. */
export async function loadTasks(
  uid: string,
  filters: { intent?: string; context?: string; status?: string } = {},
): Promise<Task[]> {
  const status = filters.status ?? "active";
  const snapshot = await tasksCollection()
    .where("ownerId", "==", uid)
    .where("status", "==", status)
    .orderBy("createdAt", "desc")
    .limit(25)
    .get();
  const tasks: Task[] = [];
  for (const doc of snapshot.docs) {
    const parsed = Task.safeParse(doc.data());
    if (parsed.success) {
      tasks.push(parsed.data);
    }
  }
  const context = filters.context?.toLowerCase();
  return tasks.filter(
    (task) =>
      (filters.intent === undefined || task.intent === filters.intent) &&
      (context === undefined || task.context?.toLowerCase() === context),
  );
}

/** Trimmed task view for tool results — enough to speak from, no noise. */
function taskView(task: Task): Record<string, unknown> {
  return {
    taskId: task.id,
    intent: task.intent,
    title: task.title,
    context: task.context,
    status: task.status,
    triggerAt: task.trigger.type === "time" ? task.trigger.at : undefined,
    items: task.items.map((item) => ({ text: item.text, checked: item.checked })),
  };
}

async function createTask(input: z.infer<typeof CreateTaskInput>, ctx: ToolContext): Promise<ToolExecution> {
  const ref = tasksCollection().doc();
  const nowIso = ctx.now.toISOString();
  const task = Task.parse({
    id: ref.id,
    ownerId: ctx.uid,
    intent: input.intent,
    title: input.title,
    items: (input.items ?? []).map((text) => ({
      id: tasksCollection().doc().id,
      text,
      checked: false,
      addedAt: nowIso,
    })),
    context: input.context,
    trigger: input.triggerAt !== undefined ? { type: "time", at: input.triggerAt } : { type: "none" },
    verification: "inline",
    status: "active",
    createdAt: nowIso,
  });
  await ref.set(task);
  ctx.emit({ type: "task_created", data: task });
  logInfo("task_created", { userId: ctx.uid, taskId: task.id, intent: task.intent });
  return {
    result: JSON.stringify({
      taskId: task.id,
      title: task.title,
      context: task.context,
      itemCount: task.items.length,
      triggerAt: input.triggerAt,
    }),
  };
}

async function queryTasks(input: z.infer<typeof QueryTasksInput>, ctx: ToolContext): Promise<ToolExecution> {
  const tasks = await loadTasks(ctx.uid, input);
  return { result: JSON.stringify({ tasks: tasks.map(taskView) }) };
}

async function updateTaskItems(
  input: z.infer<typeof UpdateTaskItemsInput>,
  ctx: ToolContext,
): Promise<ToolExecution> {
  const task = await readOwnedTask(input.taskId, ctx.uid);
  if (task === null) {
    return failure("No such task.");
  }
  const outcome = applyItemUpdates(task.items, input, ctx.now, () => tasksCollection().doc().id);
  const updated: Task = { ...task, items: outcome.items };
  await tasksCollection().doc(task.id).set(updated);
  ctx.emit({ type: "task_updated", data: updated });
  return {
    result: JSON.stringify({
      taskId: task.id,
      checkedOff: outcome.checked,
      unchecked: outcome.unchecked,
      added: outcome.added,
      notFound: outcome.notFound,
      remainingOpen: outcome.openCount,
    }),
  };
}

async function completeTask(input: z.infer<typeof CompleteTaskInput>, ctx: ToolContext): Promise<ToolExecution> {
  const task = await readOwnedTask(input.taskId, ctx.uid);
  if (task === null) {
    return failure("No such task.");
  }
  const updated: Task = { ...task, status: "completed", completedAt: ctx.now.toISOString() };
  await tasksCollection().doc(task.id).set(updated);
  ctx.emit({ type: "task_updated", data: updated });
  return { result: JSON.stringify({ taskId: task.id, status: "completed" }) };
}

async function saveMemory(input: z.infer<typeof SaveMemoryInput>, ctx: ToolContext): Promise<ToolExecution> {
  const ref = db().collection(COLLECTIONS.memories).doc();
  const memory = Memory.parse({
    id: ref.id,
    ownerId: ctx.uid,
    category: input.category,
    content: input.content,
    // Explicitly stated by the user — full confidence (extraction uses 0.8).
    confidence: 1,
    sourceTurnId: ctx.turnId,
    createdAt: ctx.now.toISOString(),
    userEdited: false,
  });
  const vector = await tryEmbed(memory.content, "document");
  await ref.set({
    ...memory,
    ...(vector !== null ? { embedding: FieldValue.vector(vector) } : {}),
  });
  logInfo("memory_saved_explicit", { userId: ctx.uid, memoryId: memory.id, category: memory.category });
  return { result: JSON.stringify({ memoryId: memory.id, category: memory.category }) };
}

function proposeCalendarEvent(
  input: z.infer<typeof ProposeCalendarEventInput>,
  ctx: ToolContext,
): ToolExecution {
  // Nothing is written here. The device confirms, writes via EventKit, and
  // verifies by read-back; the model must not claim success.
  ctx.emit({
    type: "calendar_proposal",
    data: { kind: "create", draft: input },
  });
  return {
    result: JSON.stringify({
      proposed: true,
      awaitingConfirmation: true,
      note: "Confirmation card shown on device. Do not claim the event was created.",
    }),
  };
}

function proposeCalendarMove(
  input: z.infer<typeof ProposeCalendarMoveInput>,
  ctx: ToolContext,
): ToolExecution {
  ctx.emit({
    type: "calendar_proposal",
    data: {
      kind: "move",
      eventTitle: input.eventTitle,
      newStartsAt: input.newStartsAt,
      ...(input.newEndsAt !== undefined ? { newEndsAt: input.newEndsAt } : {}),
    },
  });
  return {
    result: JSON.stringify({
      proposed: true,
      awaitingConfirmation: true,
      note: "Confirmation card shown on device. Do not claim the move happened.",
    }),
  };
}

/**
 * The generation UX contract: progress events while the opus call runs, the
 * finished Plan to the SCREEN as an event, and only summary facts to the
 * model — so the full plan structurally cannot be read aloud. Not persisted
 * yet; storage and versioning land with the store module.
 */
async function generatePlanTool(input: PlanConstraints, ctx: ToolContext): Promise<ToolExecution> {
  try {
    const generated = await generatePlan({
      userId: ctx.uid,
      turnId: ctx.turnId,
      constraints: input,
      now: ctx.now,
      onProgress: (stage) => ctx.emit({ type: "plan_progress", data: { stage } }),
    });
    // Persisted before the client hears about it; any previous active plan
    // in this domain is superseded in the same transaction.
    await saveNewPlan(generated.plan);
    ctx.emit({ type: "plan_ready", data: generated.plan });
    return {
      result: JSON.stringify({
        created: true,
        summary: summaryLine(generated.plan),
        speak:
          "Say a summary from these facts in under 60 words, honest about " +
          "what the timeframe delivers. The full plan is already on their " +
          "screen — never read the plan itself aloud.",
        ...(generated.riskSignals.length > 0
          ? {
              riskNote:
                "Risk signals were detected; the plan is performance-framed. " +
                "Say plainly what is realistic — no appearance or calorie promises.",
            }
          : {}),
      }),
    };
  } catch (err) {
    ctx.emit({ type: "plan_failed", data: {} });
    if (err instanceof PlanGenerationError) {
      logWarning("plan_generation_gave_up", { userId: ctx.uid, errors: err.validationErrors });
      return failure(
        "Plan generation failed twice; nothing was saved. Tell the user " +
          "plainly and offer to try again.",
      );
    }
    throw err;
  }
}

export const AdaptPlanInput = z.object({
  domain: PlanDomain,
  change: z.string().min(1).max(1000),
});

/**
 * Load the active plan, patch it (sonnet diff, never regeneration), persist
 * the new version superseding the old, and put the updated plan on screen.
 * The model confirms in one sentence from the patch's own summary.
 */
async function adaptPlanTool(
  input: z.infer<typeof AdaptPlanInput>,
  ctx: ToolContext,
): Promise<ToolExecution> {
  const active = await loadActivePlan(ctx.uid, input.domain);
  if (active === null) {
    return failure(`No active ${input.domain} plan to adapt.`);
  }
  try {
    const adapted = await adaptPlan({
      userId: ctx.uid,
      turnId: ctx.turnId,
      plan: active,
      change: input.change,
      now: ctx.now,
    });
    await saveNewPlan(adapted.plan);
    ctx.emit({ type: "plan_ready", data: adapted.plan });
    return {
      result: JSON.stringify({
        adapted: true,
        version: adapted.plan.meta.version,
        summary: adapted.summary,
        speak:
          "Confirm in ONE sentence (the summary says what changed). The " +
          "updated plan is already on their screen.",
      }),
    };
  } catch (err) {
    if (err instanceof PlanAdaptationError) {
      logWarning("plan_adapt_gave_up", { userId: ctx.uid, errors: err.validationErrors });
      return failure(
        "The adaptation didn't hold up; the plan is unchanged. Tell the " +
          "user plainly and ask them to rephrase what changed.",
      );
    }
    throw err;
  }
}

function draftMessage(input: z.infer<typeof DraftMessageInput>, ctx: ToolContext): ToolExecution {
  // Nothing persists and nothing sends — the client reads the draft back
  // aloud and hands off to the system compose sheet.
  ctx.emit({
    type: "draft",
    data: { recipientName: input.recipientName, body: input.body },
  });
  return {
    result: JSON.stringify({ drafted: true, recipientName: input.recipientName, body: input.body }),
  };
}

/** Dispatch. Unknown names and invalid inputs come back as is_error results. */
export async function executeToolUse(
  name: string,
  rawInput: unknown,
  ctx: ToolContext,
): Promise<ToolExecution> {
  try {
    switch (name) {
      case "create_task": {
        const parsed = CreateTaskInput.safeParse(rawInput);
        return parsed.success ? await createTask(parsed.data, ctx) : failure("Invalid create_task input.");
      }
      case "query_tasks": {
        const parsed = QueryTasksInput.safeParse(rawInput);
        return parsed.success ? await queryTasks(parsed.data, ctx) : failure("Invalid query_tasks input.");
      }
      case "update_task_items": {
        const parsed = UpdateTaskItemsInput.safeParse(rawInput);
        return parsed.success
          ? await updateTaskItems(parsed.data, ctx)
          : failure("Invalid update_task_items input.");
      }
      case "complete_task": {
        const parsed = CompleteTaskInput.safeParse(rawInput);
        return parsed.success ? await completeTask(parsed.data, ctx) : failure("Invalid complete_task input.");
      }
      case "save_memory": {
        const parsed = SaveMemoryInput.safeParse(rawInput);
        return parsed.success ? await saveMemory(parsed.data, ctx) : failure("Invalid save_memory input.");
      }
      case "draft_message": {
        const parsed = DraftMessageInput.safeParse(rawInput);
        return parsed.success ? draftMessage(parsed.data, ctx) : failure("Invalid draft_message input.");
      }
      case "generate_plan": {
        const parsed = PlanConstraints.safeParse(rawInput);
        return parsed.success
          ? await generatePlanTool(parsed.data, ctx)
          : failure("Invalid generate_plan input: domain and goal are required.");
      }
      case "adapt_plan": {
        const parsed = AdaptPlanInput.safeParse(rawInput);
        return parsed.success
          ? await adaptPlanTool(parsed.data, ctx)
          : failure("Invalid adapt_plan input: domain and change are required.");
      }
      case "propose_calendar_event": {
        const parsed = ProposeCalendarEventInput.safeParse(rawInput);
        return parsed.success
          ? proposeCalendarEvent(parsed.data, ctx)
          : failure("Invalid propose_calendar_event input (datetimes need offsets).");
      }
      case "propose_calendar_move": {
        const parsed = ProposeCalendarMoveInput.safeParse(rawInput);
        return parsed.success
          ? proposeCalendarMove(parsed.data, ctx)
          : failure("Invalid propose_calendar_move input (datetimes need offsets).");
      }
      default:
        return failure(`Unknown tool: ${name}`);
    }
  } catch (err) {
    logWarning("tool_execution_failed", { tool: name, userId: ctx.uid, ...errorFields(err) });
    return failure("The tool failed. Tell the user plainly; do not retry.");
  }
}
