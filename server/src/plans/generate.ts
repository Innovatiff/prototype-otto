/**
 * Plan generation — the expensive call, and worth it: plan quality is the
 * product.
 *
 * THE CORE ARCHITECTURAL RULE: the model writes the plan; the state machine
 * runs it. A generated plan must be COMPLETE and SELF-CONTAINED — every step
 * carries its own cue, targets, and completion mode, because the Phase 5
 * guidance runtime never gets an LLM call on the happy path.
 *
 * Mechanics: ONE opus call, the Plan schema as a forced tool input, zod +
 * referential validation and safety checks in code, ONE retry with the exact
 * errors fed back as an is_error tool result. Never returns an invalid or
 * unsafe plan.
 */
import type Anthropic from "@anthropic-ai/sdk";
import { Plan, Session, ScheduledSession } from "@otto/shared";
import { z } from "zod";

import { COLLECTIONS, db } from "../firestore.js";
import { getAnthropicClient } from "../llm/anthropic.js";
import { logInfo, logWarning } from "../log.js";
import { TIER_MODELS } from "../router/selectModel.js";
import { recordCostEvent } from "../telemetry/cost.js";
import { domainGuidance } from "./domains/index.js";
import { PlanDomain, type PlanConstraints } from "./interview.js";
import {
  checkPlanSafety,
  constraintsRiskText,
  detectRiskSignals,
  PERFORMANCE_FRAMING,
  type RiskSignal,
} from "./safety.js";

export const PLAN_MODEL = TIER_MODELS.opus;

/**
 * Above ~20k output the model is expanding sessions instead of using
 * templates — the cap turns that failure mode into a validation error
 * instead of a bill.
 */
const MAX_OUTPUT_TOKENS = 20_000;

/** What the model emits: a Plan minus the server-owned fields. */
export const GeneratedPlanPayload = z.object({
  meta: z.object({
    domain: PlanDomain,
    goal: z.string().min(1),
    horizonDays: z.number().int().min(7).max(180),
  }),
  sessions: z.array(Session).min(1).max(8),
  schedule: z.array(ScheduledSession).min(1).max(150),
});
export type GeneratedPlanPayload = z.infer<typeof GeneratedPlanPayload>;

export class PlanGenerationError extends Error {
  readonly attempts: number;
  readonly validationErrors: string[];

  constructor(message: string, attempts: number, validationErrors: string[]) {
    super(message);
    this.name = "PlanGenerationError";
    this.attempts = attempts;
    this.validationErrors = validationErrors;
  }
}

// ── Validation (zod + referential, in code) ─────────────────────────

export type ValidationResult =
  | { ok: true; payload: GeneratedPlanPayload }
  | { ok: false; errors: string[] };

export function validateGeneratedPlan(raw: unknown): ValidationResult {
  const parsed = GeneratedPlanPayload.safeParse(raw);
  if (!parsed.success) {
    return {
      ok: false,
      errors: parsed.error.issues
        .slice(0, 20)
        .map((issue) => `${issue.path.join(".") || "(root)"}: ${issue.message}`),
    };
  }
  const payload = parsed.data;
  const errors: string[] = [];

  const sessionIds = new Set<string>();
  for (const session of payload.sessions) {
    if (sessionIds.has(session.id)) {
      errors.push(`sessions: duplicate session id "${session.id}"`);
    }
    sessionIds.add(session.id);
    const stepIds = new Set<string>();
    for (const step of session.steps) {
      if (stepIds.has(step.id)) {
        errors.push(`session "${session.id}": duplicate step id "${step.id}"`);
      }
      stepIds.add(step.id);
    }
    if (session.steps.length === 0) {
      errors.push(`session "${session.id}" has no steps`);
    }
  }

  const referenced = new Set<string>();
  for (const [index, entry] of payload.schedule.entries()) {
    if (!sessionIds.has(entry.sessionId)) {
      errors.push(`schedule[${index}]: references unknown session "${entry.sessionId}"`);
    }
    referenced.add(entry.sessionId);
    if (entry.dayOffset < 0 || entry.dayOffset >= payload.meta.horizonDays) {
      errors.push(
        `schedule[${index}]: dayOffset ${entry.dayOffset} outside horizon 0..${payload.meta.horizonDays - 1}`,
      );
    }
  }
  for (const id of sessionIds) {
    if (!referenced.has(id)) {
      errors.push(`session "${id}" is never scheduled — remove it or schedule it`);
    }
  }

  return errors.length > 0 ? { ok: false, errors } : { ok: true, payload };
}

// ── The tool schema (mirrors the zod shapes) ────────────────────────

const STEP_SCHEMA = {
  type: "object",
  properties: {
    id: { type: "string", description: "Unique within the session, e.g. 'warmup-1'." },
    type: { type: "string", enum: ["timed", "counted", "checklist", "prompt"] },
    title: { type: "string" },
    cue: {
      type: "string",
      description:
        "The exact words spoken when this step starts. Self-contained: form " +
        "reminders, pacing, what done feels like. No placeholders.",
    },
    target: {
      type: "object",
      properties: {
        sets: { type: "integer" },
        reps: { type: "integer" },
        load: { type: "number", description: "kg; omit for bodyweight." },
        durationSec: { type: "integer" },
      },
      required: [],
    },
    completion: { type: "string", enum: ["auto", "manual", "voice"] },
  },
  required: ["id", "type", "title", "cue", "completion"],
} as const;

export const PLAN_GENERATION_TOOL: Anthropic.Tool = {
  name: "emit_plan",
  description:
    "Emit the complete, self-contained plan. Called exactly once, with the " +
    "final plan — sessions are TEMPLATES; the schedule references them with " +
    "progression overrides.",
  input_schema: {
    type: "object",
    properties: {
      meta: {
        type: "object",
        properties: {
          domain: { type: "string", enum: ["fitness", "productivity", "learning"] },
          goal: { type: "string" },
          horizonDays: { type: "integer", description: "Total plan length in days." },
        },
        required: ["domain", "goal", "horizonDays"],
      },
      sessions: {
        type: "array",
        description: "4-6 DISTINCT session templates. Never one per occurrence.",
        items: {
          type: "object",
          properties: {
            id: { type: "string", description: "e.g. 'lower-a'." },
            title: { type: "string" },
            estimatedMinutes: { type: "integer" },
            steps: { type: "array", items: STEP_SCHEMA },
          },
          required: ["id", "title", "estimatedMinutes", "steps"],
        },
      },
      schedule: {
        type: "array",
        description:
          "Every occurrence across the horizon, referencing template ids, " +
          "with progression overrides where weeks differ.",
        items: {
          type: "object",
          properties: {
            sessionId: { type: "string" },
            dayOffset: { type: "integer", description: "Days from plan start, 0-based." },
            timeOfDay: { type: "string", description: "Local wall clock, e.g. '07:00'. Optional." },
            progression: {
              type: "object",
              properties: {
                loadMultiplier: { type: "number", description: "1.0 = as written." },
                repsDelta: { type: "integer" },
                setsDelta: { type: "integer" },
                note: { type: "string", description: "e.g. 'deload week — keep it light'." },
              },
              required: [],
            },
          },
          required: ["sessionId", "dayOffset"],
        },
      },
    },
    required: ["meta", "sessions", "schedule"],
  },
};

// ── The prompt ──────────────────────────────────────────────────────

export const GENERATION_SYSTEM_PROMPT = `You are Otto's plan writer. You produce one complete, structured program via the emit_plan tool. A deterministic runtime executes it step by step with NO model available — so the plan must be COMPLETE and SELF-CONTAINED: every step carries the exact spoken cue, its targets, and how it completes. No placeholders, no "adjust as needed".

THE TEMPLATE RULE (non-negotiable)
Write 4-6 DISTINCT session templates in sessions[]. The schedule[] places
them across the horizon by dayOffset and expresses week-to-week change
through progression overrides (loadMultiplier, repsDelta, setsDelta, note).
NEVER write one session per occurrence. An 8-week program is a handful of
templates and a long schedule — that is how real programs are written.

CUES ARE SPOKEN
Each cue is what Otto says aloud when the step starts. Write it for the ear:
short sentences, concrete, no lists. Include what good execution feels like.

HONESTY
Never promise a body outcome by a date. If the goal implies one, the plan
delivers what the timeframe can realistically deliver.

Call emit_plan exactly once with the finished plan.`;

function buildUserMessage(constraints: PlanConstraints, riskSignals: RiskSignal[]): string {
  const parts = [
    domainGuidance(constraints.domain),
    "",
    "CONSTRAINTS (from the interview and memory — respect absolutely):",
    JSON.stringify(constraints),
  ];
  if (riskSignals.length > 0) {
    parts.push("", PERFORMANCE_FRAMING);
  }
  return parts.join("\n");
}

// ── Generation ──────────────────────────────────────────────────────

interface AttemptOutcome {
  raw: unknown;
  toolUseId: string | null;
  usage: Anthropic.Usage;
}

async function runAttempt(
  messages: Anthropic.MessageParam[],
  userId: string,
): Promise<AttemptOutcome> {
  const response = await getAnthropicClient().messages.create({
    model: PLAN_MODEL,
    max_tokens: MAX_OUTPUT_TOKENS,
    system: GENERATION_SYSTEM_PROMPT,
    messages,
    tools: [PLAN_GENERATION_TOOL],
    // Forced tool call guarantees structured output. Thinking stays off:
    // forced tool_choice and extended thinking are mutually exclusive.
    tool_choice: { type: "tool", name: "emit_plan" },
    metadata: { user_id: userId },
  });
  const toolUse = response.content.find(
    (block): block is Anthropic.ToolUseBlock => block.type === "tool_use",
  );
  return {
    raw: toolUse?.input ?? null,
    toolUseId: toolUse?.id ?? null,
    usage: response.usage,
  };
}

async function recordAttempt(
  userId: string,
  turnId: string,
  usage: Anthropic.Usage,
  startedAt: number,
): Promise<void> {
  await recordCostEvent({
    userId,
    turnId,
    tier: "opus",
    model: PLAN_MODEL,
    purpose: "plan",
    inputTokens: usage.input_tokens,
    outputTokens: usage.output_tokens,
    cacheReadTokens: usage.cache_read_input_tokens ?? 0,
    cacheCreationTokens: usage.cache_creation_input_tokens ?? 0,
    latencyMs: Date.now() - startedAt,
  });
}

export interface GeneratedPlan {
  plan: Plan;
  attempts: number;
  /** Non-empty when the request was routed to a performance-framed plan. */
  riskSignals: RiskSignal[];
}

/**
 * One generation, one retry, or a clear error. The returned Plan is fully
 * validated (structure + safety) and stamped with server-owned fields — but
 * NOT persisted; storage, versioning, and metering are the store module's
 * job.
 */
export async function generatePlan(input: {
  userId: string;
  turnId: string;
  constraints: PlanConstraints;
  now: Date;
}): Promise<GeneratedPlan> {
  // Risk-signal routing happens BEFORE generation: the plan itself gets
  // performance framing, and the detection is logged for review.
  const riskSignals =
    input.constraints.domain === "fitness"
      ? detectRiskSignals(constraintsRiskText(input.constraints))
      : [];
  if (riskSignals.length > 0) {
    logWarning("plan_risk_signals", {
      userId: input.userId,
      turnId: input.turnId,
      signals: riskSignals,
    });
  }

  const messages: Anthropic.MessageParam[] = [
    { role: "user", content: buildUserMessage(input.constraints, riskSignals) },
  ];

  let lastErrors: string[] = [];
  for (let attempt = 1; attempt <= 2; attempt += 1) {
    const startedAt = Date.now();
    const outcome = await runAttempt(messages, input.userId);
    await recordAttempt(input.userId, input.turnId, outcome.usage, startedAt);

    const result = validateGeneratedPlan(outcome.raw);
    const errors = result.ok
      ? checkPlanSafety(result.payload, input.constraints).map(
          (v) => `safety(${v.rule}): ${v.detail}`,
        )
      : result.errors;
    if (result.ok && errors.length === 0) {
      const ref = db().collection(COLLECTIONS.plans).doc();
      const plan = Plan.parse({
        id: ref.id,
        ownerId: input.userId,
        meta: { ...result.payload.meta, version: 1 },
        constraints: input.constraints,
        sessions: result.payload.sessions,
        schedule: result.payload.schedule,
        createdAt: input.now.toISOString(),
      });
      logInfo("plan_generated", {
        userId: input.userId,
        planId: plan.id,
        domain: plan.meta.domain,
        attempts: attempt,
        sessions: plan.sessions.length,
        scheduleEntries: plan.schedule.length,
        outputTokens: outcome.usage.output_tokens,
      });
      return { plan, attempts: attempt, riskSignals };
    }

    lastErrors = errors;
    logWarning(result.ok ? "plan_safety_failed" : "plan_validation_failed", {
      userId: input.userId,
      attempt,
      errors: errors.slice(0, 10),
    });
    if (attempt === 1 && outcome.toolUseId !== null) {
      // Feed the exact errors back as a failed tool result and retry ONCE.
      messages.push(
        {
          role: "assistant",
          content: [
            {
              type: "tool_use",
              id: outcome.toolUseId,
              name: "emit_plan",
              input: outcome.raw ?? {},
            },
          ],
        },
        {
          role: "user",
          content: [
            {
              type: "tool_result",
              tool_use_id: outcome.toolUseId,
              is_error: true,
              content:
                "The plan failed required checks. Fix EXACTLY these and call " +
                "emit_plan again with the corrected, complete plan:\n" +
                lastErrors.join("\n"),
            },
          ],
        },
      );
    }
  }

  throw new PlanGenerationError(
    "Plan generation failed its checks twice. Nothing was saved.",
    2,
    lastErrors,
  );
}
