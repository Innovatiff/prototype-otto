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
  type StageVisual,
  type TurnEvent,
} from "@otto/shared";
import { z } from "zod";

import {
  buildCustomAutomation,
  CustomAutomationInput,
  describeSchedule,
  enabledUpdateFields,
  matchAutomation,
} from "../automations/custom.js";
import {
  deleteAutomationDoc,
  loadOwnerAutomations,
  mintAutomationId,
  saveAutomation,
  syncCustomAutomationCount,
  updateAutomationScheduling,
} from "../automations/store.js";
import { dueToday, listCounts, loadActiveTasks, loadPlanContext } from "../brief/gather.js";
import { COLLECTIONS, db } from "../firestore.js";
import { errorFields, logInfo, logWarning } from "../log.js";
import { tryEmbed } from "../memory/embed.js";
import { adaptPlan, PlanAdaptationError } from "../plans/adapt.js";
import { generatePlan, PlanGenerationError } from "../plans/generate.js";
import { PlanConstraints, PlanDomain } from "../plans/interview.js";
import {
  loadActivePlan,
  loadSessionRecords,
  recordPlanCreation,
  saveNewPlan,
} from "../plans/store.js";
import { summaryLine } from "../plans/summarize.js";
import { cachedCurrentWeather, DEFAULT_LAT, DEFAULT_LON } from "../services/weather/index.js";

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
  /** The device's IANA zone this turn — new automations anchor to it. */
  timezone: string;
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
  // The screen shows the assembly the whole time generation runs.
  emitStage(ctx, { kind: "building", label: "Building your plan" });
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
    // Metering counts successful GENERATIONS only (adaptations never call
    // this) — and a metering hiccup must never fail a plan that saved.
    let plansCreatedThisMonth: number | null = null;
    try {
      plansCreatedThisMonth = await recordPlanCreation(ctx.uid, ctx.now);
    } catch (err) {
      logWarning("plan_meter_failed", { userId: ctx.uid, ...errorFields(err) });
    }
    ctx.emit({ type: "plan_ready", data: { plan: generated.plan, plansCreatedThisMonth } });
    return {
      result: JSON.stringify({
        created: true,
        plansCreatedThisMonth,
        summary: summaryLine(generated.plan),
        speak:
          "Say a summary from these facts in under 60 words, honest about " +
          "what the timeframe delivers. The full plan is already on their " +
          "screen — never read the plan itself aloud. Do not offer to put " +
          "sessions on the calendar; the device makes that offer itself " +
          "right after you finish.",
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
  emitStage(ctx, { kind: "building", label: "Reshaping your plan" });
  // What actually happened informs the patch: real loads beat assumed
  // ones, and repeatedly skipped steps are substitution candidates.
  const records = await loadSessionRecords(ctx.uid, active.id, 8).catch(() => []);
  try {
    const adapted = await adaptPlan({
      userId: ctx.uid,
      turnId: ctx.turnId,
      plan: active,
      change: input.change,
      now: ctx.now,
      records,
    });
    await saveNewPlan(adapted.plan);
    // Adaptations do NOT touch the meter — same wrapper shape, no count.
    ctx.emit({ type: "plan_ready", data: { plan: adapted.plan, plansCreatedThisMonth: null } });
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
// ── Automations (Phase 6) ───────────────────────────────────────────

export const ManageAutomationsInput = z.object({
  op: z.enum(["list", "enable", "disable", "delete"]),
  label: z.string().min(1).max(200).optional(),
});

export const ShowVisualInput = z.object({
  kind: z.enum(["weather", "calendar", "reminders", "plans"]),
});

/** Emits a stage TurnEvent, typed at the seam. */
function emitStage(ctx: ToolContext, visual: StageVisual): void {
  ctx.emit({ type: "stage", data: visual });
}

/**
 * The stage: puts the matching illustration on screen while the model
 * answers. Weather/reminders/plans carry server-owned data; calendar sends
 * kind only — the device renders from its own EventKit events.
 */
async function showVisualTool(
  input: z.infer<typeof ShowVisualInput>,
  ctx: ToolContext,
): Promise<ToolExecution> {
  switch (input.kind) {
    case "weather": {
      const weather = await cachedCurrentWeather(DEFAULT_LAT, DEFAULT_LON);
      emitStage(ctx, { kind: "weather", weather: weather ?? undefined });
      return {
        result: JSON.stringify({
          shown: "weather",
          weatherAvailable: weather !== null,
          note: "On screen. Speak the judgment, not the numbers.",
        }),
      };
    }
    case "calendar": {
      emitStage(ctx, { kind: "calendar" });
      return {
        result: JSON.stringify({
          shown: "calendar",
          note: "Today's events are on screen. Speak the judgment, not the list.",
        }),
      };
    }
    case "reminders": {
      const tasks = await loadActiveTasks(ctx.uid).catch((): Task[] => []);
      emitStage(ctx, {
        kind: "reminders",
        dueTasks: dueToday(tasks, ctx.now, ctx.timezone).slice(0, 10),
        lists: listCounts(tasks).slice(0, 10),
      });
      return {
        result: JSON.stringify({
          shown: "reminders",
          note: "Due items and list counts are on screen. Don't read them out.",
        }),
      };
    }
    case "plans": {
      const planContext = await loadPlanContext(ctx.uid, ctx.now, ctx.timezone);
      emitStage(ctx, { kind: "plans", planSessions: planContext.planSessions.slice(0, 6) });
      return {
        result: JSON.stringify({
          shown: "plans",
          hasActivePlans: planContext.hasActivePlans,
          todaysSessions: planContext.planSessions.length,
          note: "Today's plan sessions are on screen.",
        }),
      };
    }
  }
}

/**
 * Create a voice-defined automation. The model parsed speech into the
 * schedule; everything is re-validated here against the strict subset, and
 * the result hands back the humanized schedule for the one-line confirm.
 */
async function createAutomationTool(
  input: CustomAutomationInput,
  ctx: ToolContext,
): Promise<ToolExecution> {
  emitStage(ctx, { kind: "building", label: "Setting up the automation" });
  const existing = await loadOwnerAutomations(ctx.uid);
  const customCount = existing.filter((automation) => automation.type === "custom").length;
  const built = buildCustomAutomation(
    ctx.uid,
    ctx.timezone,
    input,
    customCount,
    ctx.now,
    mintAutomationId,
  );
  if (!built.ok) {
    return failure(built.error);
  }
  await saveAutomation(built.automation);
  // The build resolves into the armed automation on screen.
  emitStage(ctx, {
    kind: "automation",
    label: built.automation.label,
    detail: describeSchedule(built.automation.schedule),
  });
  // Tier meter (Lite caps at 3; enforcement is Phase 7's). Failure-isolated:
  // a metering hiccup must never fail a created automation.
  let customAutomationCount: number | null = null;
  try {
    customAutomationCount = await syncCustomAutomationCount(ctx.uid);
  } catch (err) {
    logWarning("automation_meter_failed", { userId: ctx.uid, ...errorFields(err) });
  }
  return {
    result: JSON.stringify({
      created: true,
      label: built.automation.label,
      schedule: describeSchedule(built.automation.schedule),
      customAutomationCount,
      speak:
        "Confirm in ONE short line using the schedule, e.g. " +
        "'Done. Every Friday at 3:30.' Nothing else.",
    }),
  };
}

async function manageAutomationsTool(
  input: z.infer<typeof ManageAutomationsInput>,
  ctx: ToolContext,
): Promise<ToolExecution> {
  const automations = await loadOwnerAutomations(ctx.uid);
  if (input.op === "list") {
    return {
      result: JSON.stringify({
        automations: automations.map((automation) => ({
          label: automation.label,
          schedule: describeSchedule(automation.schedule),
          enabled: automation.enabled,
          builtIn: automation.type !== "custom",
          lastResult: automation.lastResult ?? null,
        })),
        speak:
          "Answer from this list in plain speech — names and schedules, " +
          "never the raw data.",
      }),
    };
  }
  if (input.label === undefined) {
    return failure("Say which automation — pass its name as `label`.");
  }
  const target = matchAutomation(automations, input.label);
  if (target === null) {
    return failure(
      `No automation matches "${input.label}". Use op="list" to see what exists.`,
    );
  }
  if (input.op === "delete") {
    if (target.type !== "custom") {
      return failure(
        `"${target.label}" is built in — it can be disabled, not deleted.`,
      );
    }
    await deleteAutomationDoc(target.id);
    try {
      await syncCustomAutomationCount(ctx.uid);
    } catch (err) {
      logWarning("automation_meter_failed", { userId: ctx.uid, ...errorFields(err) });
    }
    return {
      result: JSON.stringify({
        deleted: true,
        label: target.label,
        speak: "Confirm the deletion in one short sentence.",
      }),
    };
  }
  const enabled = input.op === "enable";
  await updateAutomationScheduling(target.id, enabledUpdateFields(target, enabled, ctx.now));
  return {
    result: JSON.stringify({
      [enabled ? "enabled" : "disabled"]: true,
      label: target.label,
      speak: "Confirm in one short sentence.",
    }),
  };
}

export async function executeToolUse(
  name: string,
  rawInput: unknown,
  ctx: ToolContext,
): Promise<ToolExecution> {
  try {
    switch (name) {
      case "show_visual": {
        const parsed = ShowVisualInput.safeParse(rawInput);
        return parsed.success
          ? await showVisualTool(parsed.data, ctx)
          : failure("Invalid show_visual input: kind must be weather, calendar, reminders, or plans.");
      }
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
      case "create_automation": {
        const parsed = CustomAutomationInput.safeParse(rawInput);
        return parsed.success
          ? await createAutomationTool(parsed.data, ctx)
          : failure(
              "Invalid create_automation input: timeOfDay must be zero-padded " +
                "24h 'HH:mm', and the rrule must use the supported subset.",
            );
      }
      case "manage_automations": {
        const parsed = ManageAutomationsInput.safeParse(rawInput);
        return parsed.success
          ? await manageAutomationsTool(parsed.data, ctx)
          : failure("Invalid manage_automations input.");
      }
      default:
        return failure(`Unknown tool: ${name}`);
    }
  } catch (err) {
    logWarning("tool_execution_failed", { tool: name, userId: ctx.uid, ...errorFields(err) });
    return failure("The tool failed. Tell the user plainly; do not retry.");
  }
}
