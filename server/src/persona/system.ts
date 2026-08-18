/**
 * Otto's persona — the system prompt, assembled fresh every turn in two parts.
 *
 * PART A (static): the identity block. Byte-identical across every turn for a
 * given user, because it is the prompt-cache prefix; anything that varies —
 * clock, memories, tasks, the address-term gate — is banned from it. Tool
 * definitions (Step 2) join this cached prefix via the API's tools array.
 *
 * PART B (dynamic): current time, retrieved memories, active tasks, and this
 * turn's address-term ruling. Rebuilt per turn, never cached, and always
 * placed AFTER the cache breakpoint.
 *
 * The 1-in-3 address-term cadence is enforced here, server-side, by reading
 * the session's stored assistant turns — the model gets a binary instruction
 * each turn instead of being trusted to self-limit.
 */
import type {
  CalendarEvent,
  ConversationMessage,
  CurrentWeather,
  Memory,
  Task,
  UserProfile,
} from "@otto/shared";

import { estimateTokens } from "../router/selectModel.js";
import { wallDate, wallTime } from "../util/time.js";

/** addressTerm value meaning "no term of address, ever". */
export const NO_ADDRESS_TERM = "none";

/**
 * The identity block, verbatim from the product spec. {{ADDRESS_TERM}} is the
 * only substitution; nothing else in this text may vary per turn.
 */
const IDENTITY_TEMPLATE = `You are Otto, a personal assistant.

WHO YOU ARE
You work for one person. You know their schedule, their preferences, their
goals, and what they told you last week. You are competent, composed, and
unhurried. You are a professional employee — not a chatbot, not a friend,
not a therapist.

WHAT YOU DO
Whatever they ask. Answer ordinary questions — recipes, food, facts,
advice, ideas — from your own knowledge, the way any capable assistant
would. The tools are for ACTION: tasks, lists, reminders, memory, message
drafts. Never refuse a question because no tool fits it; a question needs
an answer, not a tool. If something is genuinely beyond you (sending
email, browsing the web), say so in one line and offer the nearest thing
you can do.

HOW YOU SPEAK
- Answer first. No preamble. Never restate the question.
- Spoken responses under 40 words. Over 60 requires a reason.
- No emoji. No exclamation marks. Never "Great question."
- "Understood" not "Got it!" — "I'll take care of it" not "Sure thing!"
- One apology maximum, then move on. Never grovel.
- Do not offer follow-up suggestions at the end of every turn.

{{ADDRESSING_SECTION}}

THE THREE-BEAT RESPONSE
1. ANSWER — first, always.
2. CONNECTION — what it means given their day, target, or history.
   Include ONLY if it changes what they do next.
3. OFFER — the one action worth taking, if there is one.

Beats 2 and 3 are conditional. "What time is it?" gets "4:15." Nothing more.
An assistant who ties every answer back to their goals is exhausting.

DISAGREEING
When they're wrong, say so plainly and without softening.
"You've blocked two hours for that. Last three times it took four."
Not "Sorry Boss, but I noticed..." Deferential in manner, direct in substance.

VOICE AND SCREEN
You are speaking out loud. Never read tables, lists, or breakdowns aloud —
those render on screen. Speak the answer and the one thing that matters.`;

const ADDRESSING_TEMPLATE = `ADDRESSING THE OWNER
Call them {{ADDRESS_TERM}}.
- At most one in three responses. Never twice in a row.
- Only in greetings, acknowledgments, and closings. Never mid-information.
- Never on one-word answers. "4:15." not "4:15, {{ADDRESS_TERM}}."
- Never when you are disagreeing with them.
- The dynamic context tells you each turn whether the term is available; when
  it says no, do not use it at all.`;

const NO_ADDRESSING_SECTION = `ADDRESSING THE OWNER
Do not address them by any name, title, or term of address.`;

export interface PersonaContext {
  now: Date;
  /** IANA timezone from the client; invalid values fall back to UTC. */
  timezone: string;
  /** Whether the address term may be used this turn (see addressTermAllowed). */
  addressAllowed: boolean;
  /** Today's and tomorrow's events from the client; [] when unavailable. */
  events: CalendarEvent[];
  /** Cached current conditions; null when unavailable. */
  weather: CurrentWeather | null;
}

export interface SystemPromptParts {
  /** PART A — cache this (cache_control on its block). */
  staticPrefix: string;
  /** PART B — never cached, always after the breakpoint. */
  dynamic: string;
}

/** The static identity block for a user. Pure function of addressTerm. */
export function buildStaticPrefix(addressTerm: string): string {
  const addressing =
    addressTerm === NO_ADDRESS_TERM
      ? NO_ADDRESSING_SECTION
      : ADDRESSING_TEMPLATE.replaceAll("{{ADDRESS_TERM}}", addressTerm);
  return IDENTITY_TEMPLATE.replace("{{ADDRESSING_SECTION}}", addressing);
}

/**
 * Server-side address-term cadence: allowed only when neither of the last two
 * assistant turns used the term. Combined with "this turn" usage that yields
 * at most one appearance in any three consecutive responses, and never two in
 * a row. "none" is never allowed.
 */
export function addressTermAllowed(addressTerm: string, messages: ConversationMessage[]): boolean {
  if (addressTerm === NO_ADDRESS_TERM) {
    return false;
  }
  const escaped = addressTerm.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const pattern = new RegExp(`(^|\\W)${escaped}(\\W|$)`, "i");
  return !messages
    .filter((message) => message.role === "assistant")
    .slice(-2)
    .some((message) => pattern.test(message.content));
}

function formatClock(now: Date, timezone: string): string {
  const options: Intl.DateTimeFormatOptions = {
    weekday: "long",
    year: "numeric",
    month: "long",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
    hour12: true,
  };
  try {
    return `${new Intl.DateTimeFormat("en-US", { ...options, timeZone: timezone }).format(now)} (${timezone})`;
  } catch {
    return `${new Intl.DateTimeFormat("en-US", { ...options, timeZone: "UTC" }).format(now)} (UTC)`;
  }
}

const MAX_TODAY_EVENTS = 12;
const MAX_TOMORROW_EVENTS = 8;
const MAX_TITLE_CHARS = 40;

function truncate(text: string, max: number): string {
  return text.length <= max ? text : `${text.slice(0, max - 1)}…`;
}

function eventLine(event: CalendarEvent, timezone: string): string {
  const span = event.isAllDay
    ? "all day"
    : `${wallTime(event.startsAt, timezone)}-${wallTime(event.endsAt, timezone)}`;
  const where = event.location !== undefined ? ` @ ${truncate(event.location, 24)}` : "";
  return `- ${span} ${truncate(event.title, MAX_TITLE_CHARS)}${where}`;
}

/**
 * Today's and tomorrow's events, one compressed line each — no IDs, no
 * descriptions. Hard-capped per day so the block stays small; answers like
 * "am I free Thursday afternoon?" come from here with no tool call.
 */
export function formatSchedule(events: CalendarEvent[], now: Date, timezone: string): string {
  const today = wallDate(now, timezone);
  const tomorrow = wallDate(new Date(now.getTime() + 24 * 3600 * 1000), timezone);
  const byDay = (day: string): CalendarEvent[] =>
    events
      .filter((event) => wallDate(new Date(event.startsAt), timezone) === day)
      .sort((a, b) => a.startsAt.localeCompare(b.startsAt));

  const lines: string[] = [];
  for (const [label, day, cap] of [
    ["Today", today, MAX_TODAY_EVENTS],
    ["Tomorrow", tomorrow, MAX_TOMORROW_EVENTS],
  ] as const) {
    const dayEvents = byDay(day);
    lines.push(`${label}:`);
    if (dayEvents.length === 0) {
      lines.push("(no events)");
    } else {
      for (const event of dayEvents.slice(0, cap)) {
        lines.push(eventLine(event, timezone));
      }
      if (dayEvents.length > cap) {
        lines.push(`(+${dayEvents.length - cap} more)`);
      }
    }
  }
  return lines.join("\n");
}

/** One line of current conditions, advice included. */
export function formatWeatherLine(weather: CurrentWeather | null): string {
  if (weather === null) {
    return "(unavailable)";
  }
  const advice = weather.advice.length > 0 ? ` [advice: ${weather.advice.join("+")}]` : "";
  return (
    `${weather.temperatureC.toFixed(0)}C feels ${weather.apparentC.toFixed(0)}C, ` +
    `rain ${weather.precipitationProbability}%, wind ${weather.windKmh.toFixed(0)}km/h${advice}`
  );
}

/** `- [category] content` lines, or an explicit empty marker. */
export function formatMemories(memories: Memory[]): string {
  if (memories.length === 0) {
    return "(nothing retrieved)";
  }
  return memories.map((memory) => `- [${memory.category}] ${memory.content}`).join("\n");
}

/** One line per task: title, intent, item progress. */
export function formatTasks(tasks: Task[]): string {
  if (tasks.length === 0) {
    return "(none)";
  }
  return tasks
    .map((task) => {
      const open = task.items.filter((item) => !item.checked).length;
      const items = task.items.length > 0 ? `, ${task.items.length} items (${open} open)` : "";
      const where = task.context !== undefined ? ` @ ${task.context}` : "";
      return `- ${task.title}${where} [${task.intent}${items}]`;
    })
    .join("\n");
}

/**
 * Assembles both parts. The static part depends only on the user's address
 * term; everything with a clock or a database read goes in dynamic.
 */
export function buildSystemPrompt(
  user: UserProfile,
  memories: Memory[],
  tasks: Task[],
  context: PersonaContext,
): SystemPromptParts {
  const addressLine =
    user.addressTerm !== NO_ADDRESS_TERM && context.addressAllowed
      ? `You may address them as ${user.addressTerm} this turn, within the rules above.`
      : "Do not use any term of address this turn.";

  // The schedule+weather block answers "am I free Thursday afternoon?" and
  // "what's the weather like?" with no tool call. Budgeted: the per-day caps
  // keep it well under 400 tokens; the guard below is the backstop.
  let scheduleBlock = formatSchedule(context.events, context.now, context.timezone);
  const weatherLine = formatWeatherLine(context.weather);
  if (estimateTokens(scheduleBlock) + estimateTokens(weatherLine) > 400) {
    scheduleBlock = `${scheduleBlock
      .split("\n")
      .slice(0, 24)
      .join("\n")}\n(truncated)`;
  }

  const dynamic = [
    "CURRENT CONTEXT",
    `Now: ${formatClock(context.now, context.timezone)}`,
    "",
    "ADDRESS THIS TURN",
    addressLine,
    "",
    "SCHEDULE (from the device calendar; conflicts are detected on-device)",
    scheduleBlock,
    "",
    "WEATHER NOW",
    weatherLine,
    "",
    "MEMORIES",
    formatMemories(memories),
    "",
    "ACTIVE TASKS",
    formatTasks(tasks),
  ].join("\n");

  return { staticPrefix: buildStaticPrefix(user.addressTerm), dynamic };
}
