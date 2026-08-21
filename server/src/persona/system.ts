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
  GuidanceTurnContext,
  Memory,
  Plan,
  Task,
  UserProfile,
} from "@otto/shared";

import { INTERVIEW_GUIDANCE } from "../plans/interview.js";
import { SAFETY_GUIDANCE } from "../plans/safety.js";
import { planWeek } from "../plans/store.js";
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
drafts. When they want to DO something concrete — cook a dish, change a
tire, fix or assemble something, run a focused errand — offer to walk
them through it and build it with create_walkthrough; you guide it
aloud, step by step, hands-free. When they want an occasion planned — a
date, a trip, a day out — create_experience plans it end to end:
interview first, one question at a time, and never guess a budget.
Never refuse a question because no tool fits it; a question needs an
answer, not a tool. If something is genuinely beyond you (sending email,
browsing the web), say so in one line and offer the nearest thing you
can do.

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
those render on screen. Speak the answer and the one thing that matters.
The screen is your stage. When the answer is about the weather, today's
schedule, reminders or lists, or their plans, call show_visual first so
the illustration is up while you speak — they see it, you say what it
means. One visual per turn, and only when the topic genuinely fits.`;

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
  /** The user's active plans (one per domain at most). */
  plans: Plan[];
  /** Present only when this turn is an off-script question mid-session. */
  guidance?: GuidanceTurnContext;
}

export interface SystemPromptParts {
  /** PART A — cache this (cache_control on its block). */
  staticPrefix: string;
  /** PART B — never cached, always after the breakpoint. */
  dynamic: string;
}

/**
 * The static identity block for a user. Pure function of addressTerm.
 * The plan blocks ride here because they are static too — interview rules
 * and outcome honesty change per deploy, never per turn, so they cache.
 */
export function buildStaticPrefix(addressTerm: string): string {
  const addressing =
    addressTerm === NO_ADDRESS_TERM
      ? NO_ADDRESSING_SECTION
      : ADDRESSING_TEMPLATE.replaceAll("{{ADDRESS_TERM}}", addressTerm);
  const identity = IDENTITY_TEMPLATE.replace("{{ADDRESSING_SECTION}}", addressing);
  return [identity, INTERVIEW_GUIDANCE, SAFETY_GUIDANCE].join("\n\n");
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
 * The off-script block: the user is MID-SESSION, hands full, asking one
 * question. The model answers it and gets out of the way — the runtime
 * speaks the return-to-step line itself.
 */
export function formatGuidance(guidance: GuidanceTurnContext): string {
  const position = guidance.position !== undefined ? ` (${guidance.position})` : "";
  return [
    "GUIDED SESSION IN PROGRESS — OFF-SCRIPT QUESTION",
    `They are mid-session: "${guidance.sessionTitle}", on the step ` +
      `"${guidance.stepTitle}"${position}. The step's cue: "${guidance.stepCue}"`,
    "Answer the question in one or two short sentences, then STOP. Do not",
    "re-explain the step, do not offer plan changes, do not add follow-ups —",
    "the session runtime returns them to the step itself. No tools unless",
    "the question itself demands one.",
  ].join("\n");
}

/**
 * The ACTIVE PLANS block: one line per active plan so the model knows a
 * plan exists (adapt_plan needs one) and where the user is in it. "(none)"
 * matters — it tells the model adapt_plan has nothing to patch.
 */
export function formatPlans(plans: Plan[], now: Date): string {
  if (plans.length === 0) {
    return "(none)";
  }
  return plans
    .slice(0, 4)
    .map((plan) => {
      const weeks = Math.max(1, Math.ceil(plan.meta.horizonDays / 7));
      return `- ${plan.meta.domain}: "${plan.meta.goal}" — week ${planWeek(plan, now)} of ${weeks}`;
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
  // The ask-once nudge: until the user picks their own term, the default
  // is in effect and Otto may ask — casually, exactly once, then save it
  // with set_address_term (or "none").
  const addressAskLine =
    user.addressTermSet === true
      ? null
      : "No confirmed term of address is on file — the current one is the " +
        "default. At a natural moment (not mid-task), ask once what they'd " +
        "like to be called and save it with set_address_term; 'none' if " +
        "they'd rather skip titles. Never ask again after that.";

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
    // An off-script question leads the dynamic block: nothing matters more
    // this turn than what the user is doing right now.
    ...(context.guidance !== undefined ? [formatGuidance(context.guidance), ""] : []),
    "CURRENT CONTEXT",
    `Now: ${formatClock(context.now, context.timezone)}`,
    "",
    "ADDRESS THIS TURN",
    addressLine,
    ...(addressAskLine !== null ? [addressAskLine] : []),
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
    "",
    "ACTIVE PLANS",
    formatPlans(context.plans, context.now),
  ].join("\n");

  return { staticPrefix: buildStaticPrefix(user.addressTerm), dynamic };
}
