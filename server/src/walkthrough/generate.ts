/**
 * Walkthrough generation — the "do it with me" call.
 *
 * A walkthrough is ONE session Otto builds on the spot for something the
 * user wants to do right now: cook a dish, change a tire, fix a faucet,
 * assemble furniture. Same architectural rule as plans: the model writes
 * it, the deterministic guidance runtime speaks it step by step with NO
 * model available — so every step is complete and self-contained.
 *
 * Mechanics mirror plan generation at a smaller scale: one sonnet call,
 * a forced tool, zod + referential validation in code, one retry with the
 * exact errors fed back. Hazardous tasks come back as a refusal the model
 * relays — never as steps.
 */
import { randomUUID } from "node:crypto";
import type Anthropic from "@anthropic-ai/sdk";
import { Session, Step, Walkthrough, WalkthroughDomain } from "@otto/shared";
import { z } from "zod";

import { getAnthropicClient } from "../llm/anthropic.js";
import { logInfo, logWarning } from "../log.js";
import { STEP_SCHEMA } from "../plans/generate.js";
import { TIER_MODELS } from "../router/selectModel.js";
import { recordCostEvent } from "../telemetry/cost.js";

export const WALKTHROUGH_MODEL = TIER_MODELS.sonnet;

/** 30 rich steps fit comfortably; past this something is being padded. */
const MAX_OUTPUT_TOKENS = 6000;

/** What the model emits: either a refusal or the full session material. */
export const WalkthroughPayload = z.object({
  /** Set ONLY for hazardous tasks — one plain sentence, no steps. */
  refused: z.string().min(1).max(300).optional(),
  domain: WalkthroughDomain.optional(),
  title: z.string().min(1).max(120).optional(),
  estimatedMinutes: z.number().int().min(1).max(240).optional(),
  steps: z.array(Step).min(3).max(30).optional(),
});
export type WalkthroughPayload = z.infer<typeof WalkthroughPayload>;

export class WalkthroughGenerationError extends Error {
  readonly attempts: number;
  readonly validationErrors: string[];

  constructor(message: string, attempts: number, validationErrors: string[]) {
    super(message);
    this.name = "WalkthroughGenerationError";
    this.attempts = attempts;
    this.validationErrors = validationErrors;
  }
}

// ── Validation (zod + step sanity, in code) ─────────────────────────

export type WalkthroughValidation =
  | { ok: "refused"; reason: string }
  | { ok: "walkthrough"; payload: Required<Omit<WalkthroughPayload, "refused">> }
  | { ok: false; errors: string[] };

export function validateWalkthrough(raw: unknown): WalkthroughValidation {
  const parsed = WalkthroughPayload.safeParse(raw);
  if (!parsed.success) {
    return {
      ok: false,
      errors: parsed.error.issues
        .slice(0, 20)
        .map((issue) => `${issue.path.join(".") || "(root)"}: ${issue.message}`),
    };
  }
  const payload = parsed.data;
  if (payload.refused !== undefined) {
    return { ok: "refused", reason: payload.refused };
  }

  const errors: string[] = [];
  if (payload.domain === undefined) errors.push("domain: required unless refusing");
  if (payload.title === undefined) errors.push("title: required unless refusing");
  if (payload.estimatedMinutes === undefined) {
    errors.push("estimatedMinutes: required unless refusing");
  }
  if (payload.steps === undefined) {
    errors.push("steps: required unless refusing");
    return { ok: false, errors };
  }

  const stepIds = new Set<string>();
  for (const [index, step] of payload.steps.entries()) {
    if (stepIds.has(step.id)) {
      errors.push(`steps[${index}]: duplicate step id "${step.id}"`);
    }
    stepIds.add(step.id);
    if (step.cue.trim().length < 8) {
      errors.push(`steps[${index}] "${step.id}": cue too thin to speak — write the words`);
    }
    const duration = step.target?.durationSec;
    if (step.type === "timed" && (duration === undefined || duration < 10 || duration > 7200)) {
      errors.push(
        `steps[${index}] "${step.id}": timed steps need target.durationSec between 10 and 7200`,
      );
    }
  }

  if (errors.length > 0) {
    return { ok: false, errors };
  }
  return {
    ok: "walkthrough",
    payload: {
      domain: payload.domain as WalkthroughDomain,
      title: payload.title as string,
      estimatedMinutes: payload.estimatedMinutes as number,
      steps: payload.steps,
    },
  };
}

/** Payload → shared Walkthrough, session id injected. Pure. */
export function buildWalkthrough(
  payload: Required<Omit<WalkthroughPayload, "refused">>,
  sessionId: string,
): Walkthrough {
  return Walkthrough.parse({
    domain: payload.domain,
    session: Session.parse({
      id: sessionId,
      title: payload.title,
      estimatedMinutes: payload.estimatedMinutes,
      steps: payload.steps,
    }),
  });
}

// ── The tool ────────────────────────────────────────────────────────

export const WALKTHROUGH_TOOL: Anthropic.Tool = {
  name: "emit_walkthrough",
  description:
    "Emit the complete walkthrough — or a refusal for hazardous tasks. " +
    "Called exactly once.",
  input_schema: {
    type: "object",
    properties: {
      refused: {
        type: "string",
        description:
          "ONLY for tasks hazardous to an untrained person. One plain " +
          "sentence: why, and the safe alternative. No other fields.",
      },
      domain: {
        type: "string",
        enum: ["cooking", "repair", "errand", "fitness", "chores", "learning", "other"],
      },
      title: { type: "string", description: "Short, e.g. 'Chicken Alfredo for Two'." },
      estimatedMinutes: {
        type: "integer",
        description: "Honest wall-clock for a first-timer, waits included.",
      },
      steps: { type: "array", items: STEP_SCHEMA },
    },
    required: [],
  },
};

// ── The prompt ──────────────────────────────────────────────────────

export const WALKTHROUGH_SYSTEM_PROMPT = `You are Otto's walkthrough writer. The user wants to DO something now — cook a dish, change a tire, fix a faucet, assemble furniture, pack for a trip. You produce ONE guided session via emit_walkthrough. A deterministic runtime speaks it step by step with NO model available, so every step is COMPLETE and SELF-CONTAINED: exact amounts, times, and order live in the steps, not in the user's memory.

STEPS
- 3 to 30 steps. Each step is ONE action a person finishes before moving on.
- The cue is what Otto SAYS when the step starts. Write for the ear: short
  sentences, concrete quantities, what done looks like. No lists read
  aloud, no "adjust as needed", no placeholders.
- type "timed" for anything with a duration (simmer, sear, rest, cure):
  set target.durationSec and completion "auto" — the runtime runs the
  clock and speaks when it's done.
- type "counted" for repetitions; set target.sets/reps.
- type "checklist" for gathering; "prompt" for everything else, with
  completion "manual" or "voice".
- FRONT-LOAD one checklist step gathering every ingredient, tool, and part
  — a person mid-task with greasy hands cannot go shopping.

SAFETY
- Physical tasks OPEN with the safety step: level ground and parking brake
  before jacking, breaker off before wiring a fixture, unplug before
  opening the case.
- Food gets doneness temperatures, never guesses.
- If the task is genuinely hazardous for an untrained person — mains
  electrical panels, gas lines, brake hydraulics, roof work, anything
  medical — do NOT write steps. Call emit_walkthrough with ONLY refused:
  one plain sentence and the safe alternative.

HONESTY
estimatedMinutes is the honest first-timer wall-clock, waits included.

Call emit_walkthrough exactly once.`;

// ── Generation ──────────────────────────────────────────────────────

export type WalkthroughResult =
  | { outcome: "ok"; walkthrough: Walkthrough; attempts: number }
  | { outcome: "refused"; reason: string };

export async function generateWalkthrough(input: {
  userId: string;
  turnId: string;
  goal: string;
  domain: WalkthroughDomain;
  notes?: string;
  now: Date;
}): Promise<WalkthroughResult> {
  const request = [
    `TASK: ${input.goal}`,
    `DOMAIN: ${input.domain}`,
    ...(input.notes !== undefined ? [`CONTEXT FROM THE USER: ${input.notes}`] : []),
  ].join("\n");
  const messages: Anthropic.MessageParam[] = [{ role: "user", content: request }];

  let lastErrors: string[] = [];
  for (let attempt = 1; attempt <= 2; attempt += 1) {
    const startedAt = Date.now();
    const response = await getAnthropicClient().messages.create({
      model: WALKTHROUGH_MODEL,
      max_tokens: MAX_OUTPUT_TOKENS,
      system: WALKTHROUGH_SYSTEM_PROMPT,
      messages,
      tools: [WALKTHROUGH_TOOL],
      tool_choice: { type: "tool", name: "emit_walkthrough" },
      thinking: { type: "disabled" },
      metadata: { user_id: input.userId },
    });
    await recordCostEvent({
      userId: input.userId,
      turnId: input.turnId,
      tier: "sonnet",
      model: WALKTHROUGH_MODEL,
      purpose: "plan",
      inputTokens: response.usage.input_tokens,
      outputTokens: response.usage.output_tokens,
      cacheReadTokens: response.usage.cache_read_input_tokens ?? 0,
      cacheCreationTokens: response.usage.cache_creation_input_tokens ?? 0,
      latencyMs: Date.now() - startedAt,
    });

    const toolUse = response.content.find(
      (block): block is Anthropic.ToolUseBlock => block.type === "tool_use",
    );
    const result = validateWalkthrough(toolUse?.input ?? null);
    if (result.ok === "refused") {
      logInfo("walkthrough_refused", { userId: input.userId, goal: input.goal.slice(0, 80) });
      return { outcome: "refused", reason: result.reason };
    }
    if (result.ok === "walkthrough") {
      const walkthrough = buildWalkthrough(result.payload, randomUUID());
      logInfo("walkthrough_generated", {
        userId: input.userId,
        domain: walkthrough.domain,
        steps: walkthrough.session.steps.length,
        estimatedMinutes: walkthrough.session.estimatedMinutes,
        attempts: attempt,
      });
      return { outcome: "ok", walkthrough, attempts: attempt };
    }

    lastErrors = result.errors;
    logWarning("walkthrough_validation_failed", {
      userId: input.userId,
      attempt,
      errors: result.errors.slice(0, 10),
    });
    if (attempt === 1 && toolUse !== undefined) {
      messages.push(
        {
          role: "assistant",
          content: [
            { type: "tool_use", id: toolUse.id, name: "emit_walkthrough", input: toolUse.input },
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
                "Validation failed. Fix EXACTLY these and emit again:\n" +
                result.errors.join("\n"),
            },
          ],
        },
      );
    }
  }

  throw new WalkthroughGenerationError(
    "walkthrough generation failed after retry",
    2,
    lastErrors,
  );
}
