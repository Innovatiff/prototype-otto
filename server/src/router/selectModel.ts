/**
 * Tier selection: which brain answers a turn.
 *
 * local and pcc are destined for on-device / Apple Private Cloud Compute and
 * carry no model string. sonnet/opus are real server-side Anthropic calls as
 * of Phase 1. Until the on-device paths exist, /converse answers null-model
 * tiers with sonnet — that fallback lives in the route, not here, so the
 * routing decision itself stays honest.
 */
import { logInfo } from "../log.js";

export type Tier = "local" | "pcc" | "haiku" | "sonnet" | "opus";

export interface RouteInput {
  intent: string;
  utteranceLength: number;
  requiresMemory: boolean;
  requiresMultiStep: boolean;
  contextTokens: number;
}

/**
 * PCC's context window tops out at 32K tokens. 24K is the hard routing gate so
 * a turn never lands near the ceiling once memories and history are injected.
 */
export const PCC_CONTEXT_CEILING = 24_000;

/**
 * Structured, low-stakes intents that must NEVER reach sonnet — conversation
 * is the dominant cost, and these are mechanical. On-device handling covers
 * them eventually; until then the server answers them on haiku (see
 * fallbackModel). This set is the margin gate: keep it aggressive.
 */
const LOCAL_INTENTS: ReadonlySet<string> = new Set([
  "list_add",
  "list_query",
  "check_item",
  "complete_task",
  "time_query",
  "date_query",
  "simple_ack",
  "reminder_create",
  "weather_query",
  "calendar_lookup",
  "guidance_command",
  "capture",
]);

/**
 * Intents that want frontier drafting quality even when small enough for PCC.
 * The daily brief (purpose "brief") also synthesizes on sonnet in Phase 2.
 */
const DRAFTING_INTENTS: ReadonlySet<string> = new Set(["message_draft"]);

/**
 * The single place tiers map to model strings. local and pcc are on-device /
 * Apple Private Cloud Compute — there is no model string to call.
 */
export const TIER_MODELS = {
  local: null,
  pcc: null,
  haiku: "claude-haiku-4-5",
  sonnet: "claude-sonnet-5",
  opus: "claude-opus-5",
} as const satisfies Readonly<Record<Tier, string | null>>;

/**
 * What actually serves a tier TODAY. local's on-device path doesn't exist
 * yet, so its turns answer on haiku — cheap and entirely capable of "add
 * milk to the list". pcc turns are general conversation and keep sonnet
 * quality until Private Cloud Compute lands. The routed tier is still
 * logged and recorded, so the intended mix stays visible in telemetry.
 */
export function fallbackModel(tier: Tier): string {
  switch (tier) {
    case "local":
    case "haiku":
      return TIER_MODELS.haiku;
    case "pcc":
    case "sonnet":
      return TIER_MODELS.sonnet;
    case "opus":
      return TIER_MODELS.opus;
  }
}

export function selectTier(i: RouteInput): Tier {
  // Multi-step work (plan generation) is the only thing that justifies opus,
  // and it wins over everything else.
  if (i.requiresMultiStep) {
    return "opus";
  }
  if (LOCAL_INTENTS.has(i.intent)) {
    return "local";
  }
  if (DRAFTING_INTENTS.has(i.intent)) {
    return "sonnet";
  }
  // PCC handles everything else that fits under its hard gate; anything over
  // spills to sonnet.
  if (i.contextTokens < PCC_CONTEXT_CEILING) {
    return "pcc";
  }
  return "sonnet";
}

/** Rough token estimate: ~4 characters per token. Good enough for routing. */
export function estimateTokens(text: string): number {
  return Math.ceil(text.length / 4);
}

export interface RoutingDecision {
  tier: Tier;
  model: string | null;
}

/**
 * Selects a tier and logs the decision with every input that produced it —
 * all call sites route through here so no decision goes unlogged.
 */
export function route(input: RouteInput, context: { turnId: string; userId: string }): RoutingDecision {
  const tier = selectTier(input);
  const model = TIER_MODELS[tier];
  logInfo("routing_decision", { ...context, ...input, tier, model });
  return { tier, model };
}
