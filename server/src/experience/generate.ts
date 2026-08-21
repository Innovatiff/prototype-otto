/**
 * Experience generation — dates, trips, days out: researched, budgeted,
 * and presented.
 *
 * Two rules carry the product:
 *
 *   1. REALISM. The call runs with web search when the API offers it, so
 *      hotels, restaurants, and prices can be grounded in the real world;
 *      when it can't verify, the plan says what to book in honest generic
 *      terms instead of inventing names.
 *
 *   2. THE BUDGET ENVELOPE. Whatever the user stated, the plan commits to
 *      AT MOST 85% of it — enforced numerically here, not by trust. The
 *      remainder is the buffer, computed server-side and shown proudly.
 *
 * Mechanics mirror the other generators: forced-ish tool emission, zod +
 * referential validation in code, one retry with the exact errors fed back.
 */
import type Anthropic from "@anthropic-ai/sdk";
import {
  Experience,
  ExperienceChapter,
  ExperienceDay,
  ExperienceKind,
  type ExperienceBudget,
} from "@otto/shared";
import { z } from "zod";

import { getAnthropicClient } from "../llm/anthropic.js";
import { logInfo, logWarning } from "../log.js";
import { TIER_MODELS } from "../router/selectModel.js";
import { recordCostEvent } from "../telemetry/cost.js";

export const EXPERIENCE_MODEL = TIER_MODELS.sonnet;
const MAX_OUTPUT_TOKENS = 6000;

/** The share of the stated budget the plan may commit. The rest is buffer. */
export const BUDGET_ENVELOPE = 0.85;

/** What the model emits — budget math is server-owned, so no budget here. */
export const ExperiencePayload = z.object({
  kind: ExperienceKind,
  title: z.string().min(1).max(120),
  destination: z.string().min(1).max(120),
  vibe: z.string().max(40).optional(),
  days: z.array(ExperienceDay).min(1).max(14),
  chapters: z.array(ExperienceChapter).min(2).max(8),
  summary: z.string().min(1).max(200),
});
export type ExperiencePayload = z.infer<typeof ExperiencePayload>;

export class ExperienceGenerationError extends Error {
  readonly validationErrors: string[];

  constructor(message: string, validationErrors: string[]) {
    super(message);
    this.name = "ExperienceGenerationError";
    this.validationErrors = validationErrors;
  }
}

// ── Validation (zod + the envelope, in code) ────────────────────────

export function plannedTotal(days: readonly ExperienceDay[]): number {
  let total = 0;
  for (const day of days) {
    for (const item of day.items) {
      total += item.estCost ?? 0;
    }
  }
  return total;
}

export type ExperienceValidation =
  | { ok: true; payload: ExperiencePayload }
  | { ok: false; errors: string[] };

export function validateExperience(raw: unknown, statedBudget: number): ExperienceValidation {
  const parsed = ExperiencePayload.safeParse(raw);
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

  const envelope = Math.floor(statedBudget * BUDGET_ENVELOPE);
  const total = plannedTotal(payload.days);
  if (total > envelope) {
    errors.push(
      `budget: planned total ${total} exceeds the envelope ${envelope} ` +
        `(85% of the stated ${statedBudget}). Cut or swap items — keep it ` +
        `realistic, never just cheaper-sounding.`,
    );
  }
  if (total === 0) {
    errors.push("budget: nothing carries an estCost — estimate the paid items honestly");
  }

  // The itinerary is an instruction sheet: everything but a tip has a
  // clock time, and every drive carries how long it takes.
  for (const [dayIndex, day] of payload.days.entries()) {
    for (const [itemIndex, item] of day.items.entries()) {
      const where = `days[${dayIndex}].items[${itemIndex}] "${item.title}"`;
      if (item.kind !== "tip" && item.startTime === undefined) {
        errors.push(`${where}: startTime is required — the plan must be followable by the clock`);
      }
      if (item.kind === "transport" && item.durationMin === undefined) {
        errors.push(`${where}: transport needs durationMin (how long the drive/ride takes)`);
      }
    }
  }

  const chapterKinds = new Set(payload.chapters.map((chapter) => chapter.kind));
  if (!chapterKinds.has("overview")) {
    errors.push('chapters: an "overview" chapter is required (first)');
  }
  if (!chapterKinds.has("budget")) {
    errors.push('chapters: a "budget" chapter is required (last)');
  }
  if (payload.chapters[0]?.kind !== "overview") {
    errors.push('chapters: "overview" must come first');
  }
  if (payload.chapters[payload.chapters.length - 1]?.kind !== "budget") {
    errors.push('chapters: "budget" must come last');
  }

  return errors.length > 0 ? { ok: false, errors } : { ok: true, payload };
}

/** Payload + server-owned budget math → the stored Experience. Pure. */
export function buildExperience(
  payload: ExperiencePayload,
  input: { id: string; ownerId: string; statedBudget: number; currency: string; now: Date },
): Experience {
  const total = plannedTotal(payload.days);
  const budget: ExperienceBudget = {
    stated: input.statedBudget,
    planned: total,
    buffer: input.statedBudget - total,
    currency: input.currency,
  };
  return Experience.parse({
    id: input.id,
    ownerId: input.ownerId,
    kind: payload.kind,
    title: payload.title,
    destination: payload.destination,
    vibe: payload.vibe,
    days: payload.days,
    budget,
    chapters: payload.chapters,
    summary: payload.summary,
    createdAt: input.now.toISOString(),
  });
}

// ── The tools ───────────────────────────────────────────────────────

const ITEM_SCHEMA = {
  type: "object",
  properties: {
    kind: { type: "string", enum: ["stay", "food", "activity", "transport", "tip"] },
    title: {
      type: "string",
      description: "The SPECIFIC name — 'Hotel La Compañía', 'Fonda Lo Que Hay', 'Drive to Miraflores'.",
    },
    note: {
      type: "string",
      description: "ONE short line: what to order, why it's here, distance for drives.",
    },
    area: { type: "string", description: "Neighborhood, for orientation." },
    address: { type: "string", description: "Street address when known." },
    startTime: {
      type: "string",
      description: "24h wall clock 'HH:mm'. REQUIRED for everything except tips.",
    },
    durationMin: {
      type: "integer",
      description: "Minutes it takes. REQUIRED for transport; give it for dinner and activities too.",
    },
    estCost: {
      type: "integer",
      description:
        "Whole currency units, estimated HIGH. Drives carry approximate gas " +
        "or fare here. Omit only for free things.",
    },
  },
  required: ["kind", "title"],
} as const;

export const EXPERIENCE_TOOL: Anthropic.Tool = {
  name: "emit_experience",
  description: "Emit the finished experience. Called exactly once, after any research.",
  input_schema: {
    type: "object",
    properties: {
      kind: { type: "string", enum: ["trip", "date", "outing"] },
      title: { type: "string", description: "Short — 'Panama, Five Days'." },
      destination: { type: "string" },
      vibe: {
        type: "string",
        description: "One word the visuals wear: beach, city, romantic, nature, food.",
      },
      days: {
        type: "array",
        items: {
          type: "object",
          properties: {
            label: { type: "string", description: "'Day 1 — Casco Viejo'; 'The evening' for a date." },
            items: { type: "array", items: ITEM_SCHEMA },
          },
          required: ["label", "items"],
        },
      },
      chapters: {
        type: "array",
        description: "The spoken presentation, in order: overview first, budget last.",
        items: {
          type: "object",
          properties: {
            kind: {
              type: "string",
              enum: ["overview", "stay", "food", "activities", "transport", "budget"],
            },
            spoken: { type: "string", description: "1-3 spoken sentences. Judgment, not lists." },
          },
          required: ["kind", "spoken"],
        },
      },
      summary: { type: "string", description: "One line for lists." },
    },
    required: ["kind", "title", "destination", "days", "chapters", "summary"],
  },
};

/**
 * The web search server tool. Typed loosely on purpose: the SDK's tool
 * union may trail the API; the fallback path below handles rejection.
 */
const WEB_SEARCH_TOOL = {
  type: "web_search_20260209",
  name: "web_search",
  max_uses: 6,
} as const;

// ── The prompt ──────────────────────────────────────────────────────

export const EXPERIENCE_SYSTEM_PROMPT = `You are Otto's experience planner: dates, trips, days out — researched, decided, timed, and worth following.

DECIDE BY NAME
You are not offering options; you are the planner. Choose THE hotel, THE
restaurants, THE venues — one specific pick each, by name, with the
neighborhood and street address when you know it. At restaurants, say
what to order in the note ("order the corvina ceviche and patacones").
Use web_search when it's available to verify places are REAL and
currently operating and to ground prices in what things cost now. When
you cannot verify, recommend in honest generic terms — "a boutique hotel
in Casco Viejo, around $130 a night" — NEVER invent a specific name you
aren't confident exists.

THE CLOCK (the plan is an instruction sheet)
Every item except tips carries startTime, in order, so the user can
follow the day minute by minute. Drives and transfers are their own
transport items — "Drive to Miraflores" — with durationMin, the distance
in the note, and approximate gas or fare in estCost. Give durationMin
for dinners and activities too. Leave slack between items; nobody enjoys
a sprinted evening.

THE BUDGET ENVELOPE (cannot bend)
Commit AT MOST 85% of the stated budget; the rest stays back as buffer,
on purpose — that is the just-in-case margin, and it is a feature.
Estimate HIGH, not hopeful: taxes, tips, gas, the drink that isn't on
the menu photo. Every paid item carries estCost in whole units.

THE SHAPE
Trips: one entry per day, labeled ("Day 2 — Old Town"), stays and
transport included. Dates and outings: one "The evening" (or afternoon)
timeline. Items get ONE short note each.

THE CHAPTERS (the spoken presentation)
The device narrates chapters over sliding illustrations. Overview first,
budget last, 1-3 sentences each, under 160 words total. Speak judgment
with the names in it — "Dinner is Fonda Lo Que Hay at seven thirty;
order the corvina" — never read the full list. The budget chapter says
the planned number, that it lands under what they gave, and what the
buffer is for.

Call emit_experience exactly once when the plan is finished.`;

// ── Generation ──────────────────────────────────────────────────────

function extractText(response: Anthropic.Message): string {
  return response.content
    .filter((block): block is Anthropic.TextBlock => block.type === "text")
    .map((block) => block.text)
    .join(" ")
    .trim();
}

function emitBlock(response: Anthropic.Message): Anthropic.ToolUseBlock | undefined {
  return response.content.find(
    (block): block is Anthropic.ToolUseBlock =>
      block.type === "tool_use" && block.name === "emit_experience",
  );
}

export async function generateExperience(input: {
  userId: string;
  turnId: string;
  request: string;
  kind: ExperienceKind;
  statedBudget: number;
  currency: string;
  now: Date;
}): Promise<{ payload: ExperiencePayload; usedWebSearch: boolean }> {
  const brief = [
    `KIND: ${input.kind}`,
    `STATED BUDGET: ${input.statedBudget} ${input.currency} — commit at most ${Math.floor(
      input.statedBudget * BUDGET_ENVELOPE,
    )}`,
    `THE ASK (everything learned in the interview): ${input.request}`,
  ].join("\n");
  const messages: Anthropic.MessageParam[] = [{ role: "user", content: brief }];

  let webSearch = true;
  let nudged = false;
  let lastErrors: string[] = [];

  for (let round = 1; round <= 4; round += 1) {
    const startedAt = Date.now();
    let response: Anthropic.Message;
    try {
      response = await getAnthropicClient().messages.create({
        model: EXPERIENCE_MODEL,
        max_tokens: MAX_OUTPUT_TOKENS,
        system: EXPERIENCE_SYSTEM_PROMPT,
        messages,
        tools: webSearch
          ? [WEB_SEARCH_TOOL as unknown as Anthropic.Tool, EXPERIENCE_TOOL]
          : [EXPERIENCE_TOOL],
        thinking: { type: "disabled" },
        metadata: { user_id: input.userId },
      });
    } catch (err) {
      // Web search may not be enabled for this key/model — drop it once
      // and plan from honest estimates instead of failing the experience.
      if (webSearch) {
        logWarning("experience_web_search_unavailable", {
          userId: input.userId,
          error: err instanceof Error ? err.message.slice(0, 200) : "unknown",
        });
        webSearch = false;
        round -= 1;
        continue;
      }
      throw err;
    }
    await recordCostEvent({
      userId: input.userId,
      turnId: input.turnId,
      tier: "sonnet",
      model: EXPERIENCE_MODEL,
      purpose: "plan",
      inputTokens: response.usage.input_tokens,
      outputTokens: response.usage.output_tokens,
      cacheReadTokens: response.usage.cache_read_input_tokens ?? 0,
      cacheCreationTokens: response.usage.cache_creation_input_tokens ?? 0,
      latencyMs: Date.now() - startedAt,
    });

    const emit = emitBlock(response);
    if (emit === undefined) {
      // It researched and talked instead of emitting — one nudge.
      if (nudged) {
        throw new ExperienceGenerationError("model never emitted the experience", lastErrors);
      }
      nudged = true;
      messages.push(
        { role: "assistant", content: extractText(response) || "(researched)" },
        { role: "user", content: "Call emit_experience now, exactly once, with the finished experience." },
      );
      continue;
    }

    const result = validateExperience(emit.input, input.statedBudget);
    if (result.ok) {
      logInfo("experience_generated", {
        userId: input.userId,
        kind: result.payload.kind,
        days: result.payload.days.length,
        planned: plannedTotal(result.payload.days),
        stated: input.statedBudget,
        usedWebSearch: webSearch,
        round,
      });
      return { payload: result.payload, usedWebSearch: webSearch };
    }

    lastErrors = result.errors;
    logWarning("experience_validation_failed", {
      userId: input.userId,
      round,
      errors: result.errors.slice(0, 10),
    });
    messages.push(
      {
        role: "assistant",
        content: [
          { type: "tool_use", id: emit.id, name: "emit_experience", input: emit.input },
        ],
      },
      {
        role: "user",
        content: [
          {
            type: "tool_result",
            tool_use_id: emit.id,
            is_error: true,
            content: "Validation failed. Fix EXACTLY these and emit again:\n" + result.errors.join("\n"),
          },
        ],
      },
    );
  }

  throw new ExperienceGenerationError("experience generation failed after retries", lastErrors);
}
