/**
 * The server's one Anthropic API surface.
 *
 * Streaming only: every text delta is handed to the caller the moment it
 * arrives — the sub-800ms voice budget leaves no room for buffering a full
 * response server-side. The API key comes from getSecret, so nothing here may
 * run before loadSecrets() has completed at cold start.
 */
import Anthropic, { APIUserAbortError } from "@anthropic-ai/sdk";

import { getSecret } from "../secrets/index.js";

/**
 * Phase 1 persona, verbatim from the spec — the full persona and memory
 * injection land in Phase 2. Kept as one static block so the cache_control
 * breakpoint below covers exactly the stable prefix.
 */
export const OTTO_SYSTEM_PROMPT =
  "You are Otto, a personal assistant. Answer briefly and directly. Spoken " +
  "responses should be under 40 words. Never use emoji or exclamation marks. " +
  "Do not offer follow-up questions unless the user asked for options.";

/**
 * Hard output cap. The persona keeps spoken answers under 40 words (~60
 * tokens); 512 leaves headroom for drafting turns while bounding a runaway
 * response to under a cent.
 */
const MAX_OUTPUT_TOKENS = 512;

let client: Anthropic | null = null;

/**
 * Lazy so the server can boot without the key configured; the first turn that
 * actually needs it surfaces getSecret's typed 500 instead.
 */
function getClient(): Anthropic {
  if (client === null) {
    client = new Anthropic({ apiKey: getSecret("ANTHROPIC_API_KEY") });
  }
  return client;
}

/** Real token accounting for one call, from the API's usage fields. */
export interface LlmUsage {
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cacheCreationTokens: number;
}

export interface LlmTurnResult {
  usage: LlmUsage;
  stopReason: string | null;
  /** True when the caller's signal cancelled the stream mid-response. */
  aborted: boolean;
}

/** One line of conversation context, oldest first, ending with the new user turn. */
export interface LlmMessage {
  role: "user" | "assistant";
  content: string;
}

export interface LlmTurnInput {
  model: string;
  /**
   * Full conversation: session history plus the current user message last.
   * Sent in its entirety — the model has no other memory of prior turns.
   */
  messages: LlmMessage[];
  /** Forwarded as metadata.user_id for Anthropic-side abuse attribution. */
  userId: string;
  /** Abort to stop generation (client disconnected or barged in). */
  signal: AbortSignal;
  /** Called once per text delta, in order, the moment each arrives. */
  onToken: (text: string) => void;
}

/**
 * One user turn against the Anthropic API, streamed.
 *
 * - Thinking is explicitly disabled: Sonnet 5 defaults to adaptive thinking,
 *   which can spend seconds before the first text token — unusable inside the
 *   800ms first-audio budget for short conversational turns.
 * - The system block carries a cache_control breakpoint now, per the spec.
 *   The Phase 1 prefix is ~50 tokens, far below Sonnet 5's 1024-token cache
 *   minimum, so the API will report zero cache activity until the Phase 2
 *   persona+memory prefix grows past it; the plumbing is in place already.
 * - An abort mid-stream is a normal outcome, not an error: the tokens that
 *   were consumed still get returned for cost recording. If the final usage
 *   event never arrived, output falls back to a character-count estimate.
 */
export async function streamAssistantTurn(input: LlmTurnInput): Promise<LlmTurnResult> {
  const usage: LlmUsage = {
    inputTokens: 0,
    outputTokens: 0,
    cacheReadTokens: 0,
    cacheCreationTokens: 0,
  };
  let stopReason: string | null = null;
  let aborted = false;
  let sawFinalUsage = false;
  let streamedChars = 0;

  // Prompt order is load-bearing for caching: [cached static prefix] →
  // [dynamic context (persona+memories, Phase 2) — after the breakpoint] →
  // [conversation history]. History changes every turn, so everything that
  // varies must sit after the cache_control marker or hits are impossible.
  const stream = getClient().messages.stream(
    {
      model: input.model,
      max_tokens: MAX_OUTPUT_TOKENS,
      system: [
        {
          type: "text",
          text: OTTO_SYSTEM_PROMPT,
          cache_control: { type: "ephemeral" },
        },
      ],
      messages: input.messages,
      thinking: { type: "disabled" },
      metadata: { user_id: input.userId },
    },
    { signal: input.signal },
  );

  try {
    for await (const event of stream) {
      if (event.type === "message_start") {
        usage.inputTokens = event.message.usage.input_tokens;
        usage.cacheReadTokens = event.message.usage.cache_read_input_tokens ?? 0;
        usage.cacheCreationTokens = event.message.usage.cache_creation_input_tokens ?? 0;
      } else if (event.type === "content_block_delta" && event.delta.type === "text_delta") {
        streamedChars += event.delta.text.length;
        input.onToken(event.delta.text);
      } else if (event.type === "message_delta") {
        usage.outputTokens = event.usage.output_tokens;
        stopReason = event.delta.stop_reason;
        sawFinalUsage = true;
      }
    }
  } catch (err) {
    if (err instanceof APIUserAbortError || input.signal.aborted) {
      aborted = true;
    } else {
      throw err;
    }
  }

  if (!sawFinalUsage) {
    // Cut off before the final usage event; ~4 chars per token, the same
    // heuristic the router uses.
    usage.outputTokens = Math.ceil(streamedChars / 4);
  }
  return { usage, stopReason, aborted };
}
