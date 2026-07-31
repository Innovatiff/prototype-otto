/**
 * The server's one Anthropic API surface.
 *
 * Streaming agent loop: text deltas are handed to the caller the moment they
 * arrive — the sub-800ms voice budget leaves no room for buffering — and
 * tool_use blocks are executed between iterations, their results fed back,
 * until the model stops talking or the iteration cap trips. The API key
 * comes from getSecret, so nothing here may run before loadSecrets() has
 * completed at cold start.
 */
import Anthropic, { APIUserAbortError } from "@anthropic-ai/sdk";

import { getSecret } from "../secrets/index.js";
import { OTTO_TOOLS } from "../tools/definitions.js";
import type { ToolExecution } from "../tools/execute.js";

/**
 * Hard output cap per iteration. The persona keeps spoken answers under 40
 * words (~60 tokens); 512 leaves headroom for drafting turns while bounding
 * a runaway response to under a cent.
 */
const MAX_OUTPUT_TOKENS = 512;

/**
 * Tool iterations per turn. A voice turn legitimately needs one or two
 * (query then answer); four means something is looping.
 */
const MAX_TOOL_ITERATIONS = 4;

let client: Anthropic | null = null;

/**
 * Lazy so the server can boot without the key configured; the first call that
 * actually needs it surfaces getSecret's typed 500 instead. Shared by the
 * converse stream and the background extraction pass.
 */
export function getAnthropicClient(): Anthropic {
  if (client === null) {
    client = new Anthropic({ apiKey: getSecret("ANTHROPIC_API_KEY") });
  }
  return client;
}

/** Real token accounting for one turn, summed across tool iterations. */
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
  /** Tool calls executed across the turn. */
  toolCalls: number;
}

/** One line of conversation context, oldest first, ending with the new user turn. */
export interface LlmMessage {
  role: "user" | "assistant";
  content: string;
}

export interface LlmTurnInput {
  model: string;
  /**
   * The two-part system prompt from persona/system.ts. staticPrefix carries
   * the cache_control breakpoint and must be byte-identical across a user's
   * turns; dynamic goes after it and is rebuilt every turn.
   */
  system: { staticPrefix: string; dynamic: string };
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
  /** Executes one tool call; must not throw (return is_error instead). */
  onToolUse: (name: string, input: unknown, toolUseId: string) => Promise<ToolExecution>;
}

/** In-flight assembly of one streamed content block. */
interface PendingBlock {
  type: "text" | "tool_use";
  text: string;
  toolUseId: string;
  toolName: string;
  inputJson: string;
}

/**
 * One user turn, streamed, with tools.
 *
 * - Thinking is explicitly disabled: Sonnet 5 defaults to adaptive thinking,
 *   which can spend seconds before the first text token — unusable inside
 *   the 800ms first-audio budget for short conversational turns.
 * - Prompt order is load-bearing for caching: [tools] → [cached static
 *   prefix] → [dynamic context] → [history]. Later tool iterations within
 *   the same turn read the same cache.
 * - An abort mid-stream is a normal outcome, not an error: consumed tokens
 *   still return for cost recording, with a character-count estimate filling
 *   in when the final usage event never arrived.
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
  let toolCalls = 0;

  const conversation: Anthropic.MessageParam[] = input.messages.map((message) => ({
    role: message.role,
    content: message.content,
  }));

  for (let iteration = 0; iteration < MAX_TOOL_ITERATIONS && !aborted; iteration += 1) {
    const stream = getAnthropicClient().messages.stream(
      {
        model: input.model,
        max_tokens: MAX_OUTPUT_TOKENS,
        tools: [...OTTO_TOOLS],
        tool_choice: { type: "auto" },
        system: [
          {
            type: "text",
            text: input.system.staticPrefix,
            cache_control: { type: "ephemeral" },
          },
          {
            type: "text",
            text: input.system.dynamic,
          },
        ],
        messages: conversation,
        thinking: { type: "disabled" },
        metadata: { user_id: input.userId },
      },
      { signal: input.signal },
    );

    const blocks: PendingBlock[] = [];
    let current: PendingBlock | null = null;
    let sawFinalUsage = false;
    let charsThisIteration = 0;
    stopReason = null;

    try {
      for await (const event of stream) {
        if (event.type === "message_start") {
          usage.inputTokens += event.message.usage.input_tokens;
          usage.cacheReadTokens += event.message.usage.cache_read_input_tokens ?? 0;
          usage.cacheCreationTokens += event.message.usage.cache_creation_input_tokens ?? 0;
        } else if (event.type === "content_block_start") {
          if (event.content_block.type === "text") {
            current = { type: "text", text: "", toolUseId: "", toolName: "", inputJson: "" };
          } else if (event.content_block.type === "tool_use") {
            current = {
              type: "tool_use",
              text: "",
              toolUseId: event.content_block.id,
              toolName: event.content_block.name,
              inputJson: "",
            };
          } else {
            current = null;
          }
        } else if (event.type === "content_block_delta") {
          if (event.delta.type === "text_delta") {
            charsThisIteration += event.delta.text.length;
            if (current?.type === "text") {
              current.text += event.delta.text;
            }
            input.onToken(event.delta.text);
          } else if (event.delta.type === "input_json_delta" && current?.type === "tool_use") {
            current.inputJson += event.delta.partial_json;
          }
        } else if (event.type === "content_block_stop") {
          if (current !== null) {
            blocks.push(current);
            current = null;
          }
        } else if (event.type === "message_delta") {
          usage.outputTokens += event.usage.output_tokens;
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
      usage.outputTokens += Math.ceil(charsThisIteration / 4);
    }

    const toolUses = blocks.filter((block) => block.type === "tool_use");
    if (aborted || stopReason !== "tool_use" || toolUses.length === 0) {
      break;
    }

    // Feed the assistant's blocks back verbatim, then execute each tool and
    // answer with tool_result blocks in the same order.
    const assistantContent: Anthropic.ContentBlockParam[] = blocks.map((block) =>
      block.type === "text"
        ? { type: "text", text: block.text }
        : {
            type: "tool_use",
            id: block.toolUseId,
            name: block.toolName,
            input: safeParseJson(block.inputJson),
          },
    );
    conversation.push({ role: "assistant", content: assistantContent });

    const results: Anthropic.ToolResultBlockParam[] = [];
    for (const use of toolUses) {
      if (input.signal.aborted) {
        aborted = true;
        break;
      }
      toolCalls += 1;
      const parsedInput = tryParseJson(use.inputJson);
      const execution: ToolExecution =
        parsedInput.ok === false
          ? { result: JSON.stringify({ error: "Malformed tool input JSON." }), isError: true }
          : await input.onToolUse(use.toolName, parsedInput.value, use.toolUseId);
      results.push({
        type: "tool_result",
        tool_use_id: use.toolUseId,
        content: execution.result,
        ...(execution.isError === true ? { is_error: true } : {}),
      });
    }
    if (aborted) {
      break;
    }
    conversation.push({ role: "user", content: results });
  }

  return { usage, stopReason, aborted, toolCalls };
}

function tryParseJson(json: string): { ok: true; value: unknown } | { ok: false } {
  try {
    return { ok: true, value: json.trim().length === 0 ? {} : JSON.parse(json) };
  } catch {
    return { ok: false };
  }
}

function safeParseJson(json: string): unknown {
  const parsed = tryParseJson(json);
  return parsed.ok ? parsed.value : {};
}
