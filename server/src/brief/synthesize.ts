/**
 * Brief synthesis. Sonnet-tier — multi-source synthesis is worth the better
 * model — with a dedicated system prompt (verbatim from the product spec).
 * The context reaches the model pre-digested: conflicts detected in Swift,
 * weather advice derived in code; the model's job is judgment and phrasing,
 * never computation.
 */
import { getAnthropicClient } from "../llm/anthropic.js";
import { TIER_MODELS } from "../router/selectModel.js";
import { wallTime } from "../util/time.js";
import type { BriefContext } from "./gather.js";

export const BRIEF_MODEL = TIER_MODELS.sonnet;
export const SUMMARY_MODEL = "claude-haiku-4-5";

/** Verbatim from the spec. */
export const BRIEF_SYSTEM_PROMPT = `You are writing Otto's morning brief. You are speaking it aloud.

STRUCTURE — in this order, skipping anything that doesn't apply:
1. Weather, as ADVICE not data. "Nine degrees and raining, and it's not
   clearing before noon — take the car." Never "the high today is 12."
2. Any schedule conflict, stated as a problem with a proposed fix.
   "That won't work. I'd push the dentist — want me to draft the reschedule?"
3. The two or three things that genuinely need them today. Not everything
   on the calendar — the things that matter.
4. Anything carried over: a goal they mentioned, a plan they're behind on,
   a task that's been sitting.
5. Close by handing control back. "That's the day. Where do you want to
   start?"

RULES
- Under 150 words spoken. This is the one place the 40-word limit is lifted.
- Have a view. "I'd push the dentist" — not "you have a conflict."
- Every problem you raise comes with a proposed next step.
- Reference something from a previous day when you can. Continuity is what
  separates an assistant from a notification.
- Never read a full list aloud. Counts only: "nineteen items on your
  Walmart list" not the items.
- No preamble. Start with the first real thing.`;

const SUMMARY_PROMPT =
  "Summarize this morning brief in at most 60 words of plain prose for " +
  "tomorrow's continuity: what was flagged, what was prioritized, what was " +
  "carried over. No greetings, no formatting.";

/** The gathered context, serialized compactly for the synthesis call. */
export function serializeContext(context: BriefContext): string {
  const tz = context.request.timezone;
  const lines: string[] = [`DATE: ${context.date} (${tz})`];

  if (context.weather !== null) {
    const w = context.weather;
    const advice = w.advice.length > 0 ? w.advice.join("+") : "none";
    lines.push(
      "WEATHER: " +
        `${w.temperatureC.toFixed(0)}C (feels ${w.apparentC.toFixed(0)}C), ` +
        `rain chance now ${w.precipitationProbability}%, wind ${w.windKmh.toFixed(0)}km/h, ` +
        `advice: ${advice}`,
    );
  } else {
    lines.push("WEATHER: unavailable");
  }

  const events = context.request.events;
  lines.push(`EVENTS (${events.length}):`);
  for (const event of events.slice(0, 20)) {
    const span = event.isAllDay
      ? "all day"
      : `${wallTime(event.startsAt, tz)}-${wallTime(event.endsAt, tz)}`;
    const where = event.location !== undefined ? ` @ ${event.location}` : "";
    lines.push(`- ${span} ${event.title}${where}`);
  }

  if (context.request.conflicts.length > 0) {
    lines.push("CONFLICTS (detected in code, trust them):");
    for (const conflict of context.request.conflicts.slice(0, 10)) {
      const label =
        conflict.kind === "overlap"
          ? `overlap by ${conflict.minutesShort}min`
          : `only ${Math.max(0, 30 - conflict.minutesShort)}min to travel between locations`;
      lines.push(
        `- ${conflict.eventA.title} (${wallTime(conflict.eventA.startsAt, tz)}) vs ` +
          `${conflict.eventB.title} (${wallTime(conflict.eventB.startsAt, tz)}): ${label}`,
      );
    }
  }

  if (context.dueTasks.length > 0) {
    lines.push("REMINDERS DUE TODAY:");
    for (const task of context.dueTasks.slice(0, 10)) {
      lines.push(`- ${task.title} at ${wallTime(task.at, tz)}`);
    }
  }

  if (context.lists.length > 0) {
    lines.push("OPEN LISTS (counts only):");
    for (const list of context.lists.slice(0, 10)) {
      const where = list.context !== undefined ? ` @ ${list.context}` : "";
      lines.push(`- ${list.title}${where}: ${list.openCount} open`);
    }
  }

  if (context.carried.length > 0) {
    lines.push("GOALS AND CONTEXT ON FILE:");
    for (const memory of context.carried) {
      lines.push(`- [${memory.category}] ${memory.content}`);
    }
  }

  lines.push(`YESTERDAY'S BRIEF: ${context.yesterdaySummary ?? "(none)"}`);
  return lines.join("\n");
}

export interface SynthesizedBrief {
  spoken: string;
  usage: {
    inputTokens: number;
    outputTokens: number;
    cacheReadTokens: number;
    cacheCreationTokens: number;
  };
}

function usageOf(response: {
  usage: {
    input_tokens: number;
    output_tokens: number;
    cache_read_input_tokens: number | null;
    cache_creation_input_tokens: number | null;
  };
}): SynthesizedBrief["usage"] {
  return {
    inputTokens: response.usage.input_tokens,
    outputTokens: response.usage.output_tokens,
    cacheReadTokens: response.usage.cache_read_input_tokens ?? 0,
    cacheCreationTokens: response.usage.cache_creation_input_tokens ?? 0,
  };
}

/** One sonnet call; plain text out. */
export async function synthesizeBrief(
  context: BriefContext,
  userId: string,
): Promise<SynthesizedBrief> {
  const response = await getAnthropicClient().messages.create({
    model: BRIEF_MODEL,
    max_tokens: 400,
    system: BRIEF_SYSTEM_PROMPT,
    messages: [{ role: "user", content: serializeContext(context) }],
    thinking: { type: "disabled" },
    metadata: { user_id: userId },
  });
  const spoken = response.content
    .filter((block) => block.type === "text")
    .map((block) => block.text)
    .join("")
    .trim();
  return { spoken, usage: usageOf(response) };
}

/** The 60-word continuity summary, on the cheap tier. */
export async function summarizeBrief(
  spoken: string,
  userId: string,
): Promise<{ summary: string; usage: SynthesizedBrief["usage"] }> {
  const response = await getAnthropicClient().messages.create({
    model: SUMMARY_MODEL,
    max_tokens: 150,
    system: SUMMARY_PROMPT,
    messages: [{ role: "user", content: spoken }],
    metadata: { user_id: userId },
  });
  const summary = response.content
    .filter((block) => block.type === "text")
    .map((block) => block.text)
    .join("")
    .trim();
  return { summary, usage: usageOf(response) };
}
