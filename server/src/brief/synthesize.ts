/**
 * Brief synthesis. Sonnet-tier — multi-source synthesis is worth the better
 * model — with a dedicated system prompt (verbatim from the product spec).
 * The context reaches the model pre-digested: conflicts detected in Swift,
 * weather advice derived in code; the model's job is judgment and phrasing,
 * never computation.
 */
import { BriefChapter } from "@otto/shared";
import { z } from "zod";

import { getAnthropicClient } from "../llm/anthropic.js";
import { TIER_MODELS } from "../router/selectModel.js";
import { wallTime } from "../util/time.js";
import type { BriefContext } from "./gather.js";

export const BRIEF_MODEL = TIER_MODELS.sonnet;
export const SUMMARY_MODEL = "claude-haiku-4-5";

/** The spec's voice, restructured into chapters the screen can follow. */
export const BRIEF_SYSTEM_PROMPT = `You are writing Otto's morning brief. You are speaking it aloud, and the screen shows each chapter's visual while you speak it — so emit the brief as CHAPTERS via emit_brief, in this order:

1. "weather" — ALWAYS present. Weather as ADVICE not data: "Nine degrees
   and raining, and it's not clearing before noon — take the car." Never
   "the high today is 12." If weather is unavailable, one calm line
   saying so.
2. "calendar" — ALWAYS present. Any conflict first, stated as a problem
   with a proposed fix ("That won't work. I'd push the dentist — want me
   to draft the reschedule?"), then the two or three commitments that
   genuinely need them. If the calendar is empty, SAY it's empty, kindly:
   "Calendar's clear — the day is yours."
3. "plans" — include whenever the user has ANY active plan. What's on
   the plan today, with a view ("Push day, week two — thirty-five
   minutes when you're ready."). A session already done today is
   acknowledged as banked. Nothing scheduled today: one kind line —
   rest is part of the program. No active plans at all: OMIT this
   chapter entirely.
4. "reminders" — ALWAYS present. What's due today, plus list counts only
   ("nineteen items on the Walmart list" — never the items). If nothing
   is due, say so in one line.
5. "outro" — usually worth including. Anything carried over (a goal,
   something flagged yesterday), then close by handing control back:
   "That's the day. Where do you want to start?"

An "intro" chapter before weather is allowed but rarely needed — no
preamble; start with the first real thing.

RULES
- Under 150 words TOTAL across all chapters. This is the one place the
  40-word limit is lifted.
- Each chapter is 1–3 spoken sentences. Plain speech — no headers, no
  bullet points, no formatting.
- Have a view. "I'd push the dentist" — not "you have a conflict."
- Every problem you raise comes with a proposed next step.
- Reference something from a previous day when you can. Continuity is
  what separates an assistant from a notification.`;

/** The forced tool: chapters in, nothing else out. */
export const BRIEF_TOOL = {
  name: "emit_brief",
  description: "Emit the morning brief as ordered spoken chapters.",
  input_schema: {
    type: "object" as const,
    properties: {
      chapters: {
        type: "array",
        items: {
          type: "object",
          properties: {
            kind: {
              type: "string",
              enum: ["intro", "weather", "calendar", "plans", "reminders", "outro"],
            },
            spoken: { type: "string", description: "This chapter's sentences, spoken style." },
          },
          required: ["kind", "spoken"],
        },
      },
    },
    required: ["chapters"],
  },
};

const ChaptersPayload = z.object({
  chapters: z.array(BriefChapter).min(1).max(8),
});

/** Tool input → validated chapters, or null. Exported for tests. */
export function parseChapters(input: unknown): BriefChapter[] | null {
  const parsed = ChaptersPayload.safeParse(input);
  return parsed.success ? parsed.data.chapters : null;
}

/** The chapters as one flowing text — storage, summaries, legacy clients. */
export function joinChapters(chapters: readonly BriefChapter[]): string {
  return chapters
    .map((chapter) => chapter.spoken.trim())
    .filter((spoken) => spoken.length > 0)
    .join(" ");
}

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

  if (context.hasActivePlans) {
    lines.push(`PLAN SESSIONS TODAY (${context.planSessions.length}):`);
    for (const session of context.planSessions.slice(0, 6)) {
      const when = session.timeOfDay !== undefined ? ` at ${session.timeOfDay}` : "";
      const done = session.completed ? " — ALREADY DONE today" : "";
      lines.push(
        `- ${session.sessionTitle} (${session.domain}, week ${session.week})${when}${done}`,
      );
    }
    if (context.planSessions.length === 0) {
      lines.push("- none scheduled today");
    }
  } else {
    lines.push("ACTIVE PLANS: none (omit the plans chapter)");
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
  /** Ordered chapters — what the client plays, sliding visuals per chapter. */
  chapters: BriefChapter[];
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

/** One sonnet call; the forced emit_brief tool yields ordered chapters. */
export async function synthesizeBrief(
  context: BriefContext,
  userId: string,
): Promise<SynthesizedBrief> {
  const response = await getAnthropicClient().messages.create({
    model: BRIEF_MODEL,
    max_tokens: 700,
    system: BRIEF_SYSTEM_PROMPT,
    messages: [{ role: "user", content: serializeContext(context) }],
    tools: [BRIEF_TOOL],
    tool_choice: { type: "tool", name: "emit_brief" },
    thinking: { type: "disabled" },
    metadata: { user_id: userId },
  });

  const toolBlock = response.content.find((block) => block.type === "tool_use");
  const chapters = toolBlock !== undefined ? parseChapters(toolBlock.input) : null;
  if (chapters !== null) {
    return { spoken: joinChapters(chapters), chapters, usage: usageOf(response) };
  }

  // The tool is forced, so this is the unhappy path — but if the model
  // slipped and answered in prose, the brief still speaks as one chapter.
  const text = response.content
    .filter((block) => block.type === "text")
    .map((block) => block.text)
    .join("")
    .trim();
  if (text.length === 0) {
    throw new Error("brief synthesis returned neither chapters nor text");
  }
  const fallback: BriefChapter[] = [{ kind: "intro", spoken: text }];
  return { spoken: text, chapters: fallback, usage: usageOf(response) };
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
