/**
 * Plan adaptation — a DIFF, never a regeneration. The user is mid-plan;
 * everything the patch doesn't touch stands.
 *
 * Sonnet emits a small patch (schedule ops + step replacements) against the
 * current plan; applyPatch replays it in code onto a NEW immutable version
 * (meta.version + 1, supersedes set), re-validating structure and safety
 * before anything is returned. One retry with exact errors, same as
 * generation. Otto confirms in one sentence.
 */
import type Anthropic from "@anthropic-ai/sdk";
import { Plan, Progression, ScheduledSession, Session, Step } from "@otto/shared";
import { z } from "zod";

import { getAnthropicClient } from "../llm/anthropic.js";
import { logInfo, logWarning } from "../log.js";
import { TIER_MODELS } from "../router/selectModel.js";
import { recordCostEvent } from "../telemetry/cost.js";
import { STEP_SCHEMA, validateGeneratedPlan } from "./generate.js";
import { PlanConstraints } from "./interview.js";
import { checkPlanSafety } from "./safety.js";
import { mintPlanId, planWeek } from "./store.js";

export const ADAPT_MODEL = TIER_MODELS.sonnet;

/** A patch is small by definition; a bigger one is a rewrite in disguise. */
const MAX_OUTPUT_TOKENS = 4000;

// ── The patch (what the model emits) ────────────────────────────────

/** Ops reference schedule entries by sessionId + CURRENT dayOffset. */
const EntryRef = z.object({
  sessionId: z.string().min(1),
  dayOffset: z.number().int().min(0),
});

export const PatchPayload = z.object({
  /** ONE spoken sentence confirming the change. */
  summary: z.string().min(1).max(200),
  /** Swap a movement inside a template — the injury case. */
  replaceSteps: z
    .array(
      z.object({
        sessionId: z.string().min(1),
        stepId: z.string().min(1),
        newStep: Step,
      }),
    )
    .max(20)
    .optional(),
  removeSessions: z.array(EntryRef).max(60).optional(),
  shiftSessions: z
    .array(EntryRef.extend({ newDayOffset: z.number().int().min(0) }))
    .max(60)
    .optional(),
  modifySessions: z.array(EntryRef.extend({ progression: Progression })).max(60).optional(),
  /** Rare: re-placing a missed session. Only existing templates. */
  addSessions: z.array(ScheduledSession).max(20).optional(),
});
export type PatchPayload = z.infer<typeof PatchPayload>;

export class PlanAdaptationError extends Error {
  readonly attempts: number;
  readonly validationErrors: string[];

  constructor(message: string, attempts: number, validationErrors: string[]) {
    super(message);
    this.name = "PlanAdaptationError";
    this.attempts = attempts;
    this.validationErrors = validationErrors;
  }
}

// ── Applying a patch (pure, deterministic) ──────────────────────────

export type ApplyResult = { ok: true; plan: Plan } | { ok: false; errors: string[] };

/**
 * Replays a patch onto a new immutable version. All ops address the
 * ORIGINAL schedule coordinates; templates left unscheduled are pruned; the
 * result passes the same structural validation and safety checks as a fresh
 * generation (minus the deload rule — repairs to a lived schedule are not
 * how plans are written).
 */
export function applyPatch(input: {
  plan: Plan;
  patch: PatchPayload;
  newId: string;
  now: Date;
}): ApplyResult {
  const { plan, patch } = input;
  const errors: string[] = [];

  // Step replacements on deep-copied templates.
  const sessions: Session[] = plan.sessions.map((session) => ({
    ...session,
    steps: session.steps.map((step) => ({ ...step })),
  }));
  for (const rep of patch.replaceSteps ?? []) {
    const session = sessions.find((s) => s.id === rep.sessionId);
    if (session === undefined) {
      errors.push(`replaceSteps: unknown session "${rep.sessionId}"`);
      continue;
    }
    const index = session.steps.findIndex((step) => step.id === rep.stepId);
    if (index === -1) {
      errors.push(`replaceSteps: no step "${rep.stepId}" in session "${rep.sessionId}"`);
      continue;
    }
    session.steps[index] = rep.newStep;
  }

  // Schedule ops, addressed by original coordinates.
  interface Tracked {
    key: string;
    removed: boolean;
    value: ScheduledSession;
  }
  const keyOf = (sessionId: string, dayOffset: number): string => `${sessionId}@${dayOffset}`;
  const tracked: Tracked[] = plan.schedule.map((entry) => ({
    key: keyOf(entry.sessionId, entry.dayOffset),
    removed: false,
    value: {
      ...entry,
      ...(entry.progression === undefined ? {} : { progression: { ...entry.progression } }),
    },
  }));
  const find = (ref: { sessionId: string; dayOffset: number }, op: string): Tracked | null => {
    const match = tracked.find((t) => t.key === keyOf(ref.sessionId, ref.dayOffset) && !t.removed);
    if (match === null || match === undefined) {
      errors.push(`${op}: no schedule entry "${ref.sessionId}" at day ${ref.dayOffset}`);
      return null;
    }
    return match;
  };
  for (const ref of patch.removeSessions ?? []) {
    const match = find(ref, "removeSessions");
    if (match !== null) {
      match.removed = true;
    }
  }
  for (const shift of patch.shiftSessions ?? []) {
    const match = find(shift, "shiftSessions");
    if (match !== null) {
      match.value.dayOffset = shift.newDayOffset;
    }
  }
  for (const modify of patch.modifySessions ?? []) {
    const match = find(modify, "modifySessions");
    if (match !== null) {
      match.value.progression = modify.progression;
    }
  }
  const schedule: ScheduledSession[] = tracked
    .filter((t) => !t.removed)
    .map((t) => t.value)
    .concat(patch.addSessions ?? [])
    .sort((a, b) => a.dayOffset - b.dayOffset);

  // Templates with no remaining occurrences drop out of the new version —
  // history keeps them in the superseded one.
  const referenced = new Set(schedule.map((entry) => entry.sessionId));
  const keptSessions = sessions.filter((session) => referenced.has(session.id));

  if (errors.length > 0) {
    return { ok: false, errors };
  }

  // Same bar as generation: structure, then safety.
  const validation = validateGeneratedPlan({
    meta: {
      domain: plan.meta.domain,
      goal: plan.meta.goal,
      horizonDays: plan.meta.horizonDays,
    },
    sessions: keptSessions,
    schedule,
  });
  if (!validation.ok) {
    return { ok: false, errors: validation.errors };
  }
  const constraints = PlanConstraints.safeParse(plan.constraints);
  if (constraints.success) {
    const violations = checkPlanSafety(validation.payload, constraints.data, {
      skipDeloadCheck: true,
    });
    if (violations.length > 0) {
      return {
        ok: false,
        errors: violations.map((v) => `safety(${v.rule}): ${v.detail}`),
      };
    }
  }

  return {
    ok: true,
    plan: Plan.parse({
      id: input.newId,
      ownerId: plan.ownerId,
      meta: { ...plan.meta, version: plan.meta.version + 1 },
      constraints: plan.constraints,
      sessions: keptSessions,
      schedule,
      status: "active",
      supersedes: plan.id,
      createdAt: input.now.toISOString(),
    }),
  };
}

// ── The tool and the prompt ─────────────────────────────────────────

export const PLAN_ADAPT_TOOL: Anthropic.Tool = {
  name: "emit_patch",
  description:
    "Emit the patch — the minimal set of changes to the current plan. " +
    "Called exactly once. Everything not referenced stands unchanged.",
  input_schema: {
    type: "object",
    properties: {
      summary: {
        type: "string",
        description: "ONE spoken sentence confirming the change.",
      },
      replaceSteps: {
        type: "array",
        description: "Swap a movement inside a session template (injury, equipment).",
        items: {
          type: "object",
          properties: {
            sessionId: { type: "string" },
            stepId: { type: "string", description: "The step being replaced." },
            newStep: STEP_SCHEMA,
          },
          required: ["sessionId", "stepId", "newStep"],
        },
      },
      removeSessions: {
        type: "array",
        description: "Drop schedule entries, addressed by sessionId + current dayOffset.",
        items: {
          type: "object",
          properties: {
            sessionId: { type: "string" },
            dayOffset: { type: "integer" },
          },
          required: ["sessionId", "dayOffset"],
        },
      },
      shiftSessions: {
        type: "array",
        description: "Move entries to a new dayOffset.",
        items: {
          type: "object",
          properties: {
            sessionId: { type: "string" },
            dayOffset: { type: "integer", description: "Current position." },
            newDayOffset: { type: "integer" },
          },
          required: ["sessionId", "dayOffset", "newDayOffset"],
        },
      },
      modifySessions: {
        type: "array",
        description: "Replace an entry's progression override.",
        items: {
          type: "object",
          properties: {
            sessionId: { type: "string" },
            dayOffset: { type: "integer" },
            progression: {
              type: "object",
              properties: {
                loadMultiplier: { type: "number" },
                repsDelta: { type: "integer" },
                setsDelta: { type: "integer" },
                note: { type: "string" },
              },
              required: [],
            },
          },
          required: ["sessionId", "dayOffset", "progression"],
        },
      },
      addSessions: {
        type: "array",
        description: "Add occurrences of EXISTING templates (re-placing missed work).",
        items: {
          type: "object",
          properties: {
            sessionId: { type: "string" },
            dayOffset: { type: "integer" },
            timeOfDay: { type: "string" },
            progression: {
              type: "object",
              properties: {
                loadMultiplier: { type: "number" },
                repsDelta: { type: "integer" },
                setsDelta: { type: "integer" },
                note: { type: "string" },
              },
              required: [],
            },
          },
          required: ["sessionId", "dayOffset"],
        },
      },
    },
    required: ["summary"],
  },
};

export const ADAPT_SYSTEM_PROMPT = `You are Otto's plan adapter. You emit ONE patch via the emit_patch tool — a diff against the current plan, never a rewrite. The user is mid-plan; everything the patch does not touch stands.

RULES
- Change the MINIMUM that solves the problem. Prefer schedule ops; edit a
  step only when the movement itself is the problem (injury, equipment).
- Replacement steps are COMPLETE and SELF-CONTAINED — exact spoken cue with
  a form reminder, targets, completion mode. Same bar as the original plan.
- Never invent new session templates. Never change the goal or the horizon.
- Preserve the progression logic: deloads stay where they are, week-to-week
  increases stay gradual, loads only move through progression overrides.
- The past already happened: only entries from today's dayOffset onward may
  change. Reshape what remains; never rewrite completed days.
- Ops address entries by sessionId + their CURRENT dayOffset in the plan.
- summary is ONE spoken sentence, plain and final:
  "Swapped overhead pressing out for two weeks. Everything else stands."

Call emit_patch exactly once.`;

function buildAdaptMessage(plan: Plan, change: string, now: Date): string {
  const week = planWeek(plan, now);
  const dayOffset = Math.max(
    0,
    Math.floor((now.getTime() - new Date(plan.createdAt).getTime()) / 86_400_000),
  );
  return [
    "THE CURRENT PLAN:",
    JSON.stringify({
      meta: plan.meta,
      constraints: plan.constraints,
      sessions: plan.sessions,
      schedule: plan.schedule,
    }),
    "",
    `Today is dayOffset ${dayOffset} (week ${week} of ${Math.ceil(plan.meta.horizonDays / 7)}).`,
    "",
    `WHAT CHANGED: ${change}`,
  ].join("\n");
}

// ── Adaptation ──────────────────────────────────────────────────────

export interface AdaptedPlan {
  plan: Plan;
  summary: string;
  attempts: number;
}

/**
 * One sonnet call, one retry, or a clear error. Returns the NEW validated
 * version without persisting — the caller stores it (superseding the old
 * one) and speaks the one-sentence summary.
 */
export async function adaptPlan(input: {
  userId: string;
  turnId: string;
  plan: Plan;
  change: string;
  now: Date;
}): Promise<AdaptedPlan> {
  const messages: Anthropic.MessageParam[] = [
    { role: "user", content: buildAdaptMessage(input.plan, input.change, input.now) },
  ];

  let lastErrors: string[] = [];
  for (let attempt = 1; attempt <= 2; attempt += 1) {
    const startedAt = Date.now();
    const response = await getAnthropicClient().messages.create({
      model: ADAPT_MODEL,
      max_tokens: MAX_OUTPUT_TOKENS,
      system: ADAPT_SYSTEM_PROMPT,
      messages,
      tools: [PLAN_ADAPT_TOOL],
      tool_choice: { type: "tool", name: "emit_patch" },
      metadata: { user_id: input.userId },
    });
    await recordCostEvent({
      userId: input.userId,
      turnId: input.turnId,
      tier: "sonnet",
      model: ADAPT_MODEL,
      purpose: "adapt",
      inputTokens: response.usage.input_tokens,
      outputTokens: response.usage.output_tokens,
      cacheReadTokens: response.usage.cache_read_input_tokens ?? 0,
      cacheCreationTokens: response.usage.cache_creation_input_tokens ?? 0,
      latencyMs: Date.now() - startedAt,
    });

    const toolUse = response.content.find(
      (block): block is Anthropic.ToolUseBlock => block.type === "tool_use",
    );
    const parsed = PatchPayload.safeParse(toolUse?.input ?? null);
    const outcome: ApplyResult = parsed.success
      ? applyPatch({
          plan: input.plan,
          patch: parsed.data,
          newId: mintPlanId(),
          now: input.now,
        })
      : {
          ok: false,
          errors: parsed.error.issues
            .slice(0, 20)
            .map((issue) => `${issue.path.join(".") || "(root)"}: ${issue.message}`),
        };

    if (outcome.ok && parsed.success) {
      logInfo("plan_adapted", {
        userId: input.userId,
        planId: outcome.plan.id,
        supersedes: input.plan.id,
        version: outcome.plan.meta.version,
        attempts: attempt,
      });
      return { plan: outcome.plan, summary: parsed.data.summary, attempts: attempt };
    }

    lastErrors = outcome.ok ? [] : outcome.errors;
    logWarning("plan_adapt_failed", {
      userId: input.userId,
      attempt,
      errors: lastErrors.slice(0, 10),
    });
    if (attempt === 1 && toolUse !== undefined) {
      messages.push(
        {
          role: "assistant",
          content: [
            { type: "tool_use", id: toolUse.id, name: "emit_patch", input: toolUse.input ?? {} },
          ],
        },
        {
          role: "user",
          content: [
            {
              type: "tool_result",
              tool_use_id: toolUse.id,
              is_error: true,
              content:
                "The patch failed required checks. Fix EXACTLY these and call " +
                "emit_patch again:\n" + lastErrors.join("\n"),
            },
          ],
        },
      );
    }
  }

  throw new PlanAdaptationError(
    "Plan adaptation failed its checks twice. The plan is unchanged.",
    2,
    lastErrors,
  );
}
