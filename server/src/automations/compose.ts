/**
 * The one model call an automation handler may make: sonnet, thinking off,
 * facts in, short prose out, cost recorded. A failure THROWS — the tick
 * frame records "failed" and nothing is delivered. There is no fallback
 * text: a half-generated message is worse than silence.
 */
import { getAnthropicClient } from "../llm/anthropic.js";
import { TIER_MODELS } from "../router/selectModel.js";
import { recordCostEvent } from "../telemetry/cost.js";

export const AUTOMATION_MODEL = TIER_MODELS.sonnet;

/**
 * The shared voice for every automation message. Individual handlers add
 * task-specific structure on top.
 */
export const AUTOMATION_STYLE =
  "You write short proactive messages from Otto, a personal assistant, to " +
  "its owner. Under 60 words. No exclamation marks. No greetings, no " +
  "sign-offs, no preamble — start with the first real thing. Plain prose, " +
  "no lists or formatting. Use only the facts provided; never invent. " +
  "Times are already in the owner's timezone.";

export async function composeAutomationText(opts: {
  uid: string;
  turnId: string;
  system: string;
  facts: string;
  maxTokens?: number;
}): Promise<string> {
  const startedAt = Date.now();
  const response = await getAnthropicClient().messages.create({
    model: AUTOMATION_MODEL,
    max_tokens: opts.maxTokens ?? 200,
    system: `${AUTOMATION_STYLE}\n\n${opts.system}`,
    messages: [{ role: "user", content: opts.facts }],
    thinking: { type: "disabled" },
    metadata: { user_id: opts.uid },
  });
  const text = response.content
    .filter((block) => block.type === "text")
    .map((block) => block.text)
    .join("")
    .trim();
  await recordCostEvent({
    userId: opts.uid,
    turnId: opts.turnId,
    tier: "background",
    model: AUTOMATION_MODEL,
    purpose: "automation",
    inputTokens: response.usage.input_tokens,
    outputTokens: response.usage.output_tokens,
    cacheReadTokens: response.usage.cache_read_input_tokens ?? 0,
    cacheCreationTokens: response.usage.cache_creation_input_tokens ?? 0,
    latencyMs: Date.now() - startedAt,
  });
  if (text.length === 0) {
    throw new Error("Automation composition returned no text.");
  }
  return text;
}
