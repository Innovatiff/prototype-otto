/**
 * Phase 0 intent classification: ordered keyword/pattern rules, no model call.
 *
 * First matching rule wins, so specific intents sit above generic ones —
 * `list_query` and `time_query` must fire before the catch-all `question`
 * rule ("what's on my walmart list", "what time is it").
 */

export const INTENTS = [
  "list_add",
  "list_query",
  "check_item",
  "complete_task",
  "reminder_create",
  "message_draft",
  "capture",
  "time_query",
  "date_query",
  "simple_ack",
  "weather_query",
  "calendar_lookup",
  "question",
  "plan_request",
  "unknown",
] as const;

export type Intent = (typeof INTENTS)[number];

interface Rule {
  readonly intent: Intent;
  readonly patterns: readonly RegExp[];
}

// All patterns are non-global (a global regex keeps lastIndex state across
// calls) and are matched against trimmed, lowercased text.
const RULES: readonly Rule[] = [
  {
    // Before reminder/question: "make me a training plan" must not fall
    // through, but a bare mention of "plan" ("what's the plan today") must.
    intent: "plan_request",
    patterns: [
      /\b(?:make|build|create|generate|design|draft|put together)\b[\s\S]{0,50}\b(?:plan|program|routine|regimen)\b/,
      /\b(?:meal|workout|training|study|savings|reading)\s+(?:plan|program)\b/,
    ],
  },
  {
    intent: "reminder_create",
    patterns: [
      /\bremind me\b/,
      /\bset (?:a |an )?(?:reminder|alarm|timer)\b/,
      /\bdon'?t let me forget\b/,
      /\bremember to\b/,
    ],
  },
  {
    // "tell me..." is a question, not a message — hence the lookahead.
    intent: "message_draft",
    patterns: [
      /^(?:text|message|email|reply to)\b/,
      /^tell (?!me\b)/,
      /\b(?:draft|send|write)\b[\s\S]{0,30}\b(?:text|message|email|reply)\b/,
    ],
  },
  {
    intent: "check_item",
    patterns: [
      /\b(?:check|tick|cross)(?:ed)?(?: that| it| this)? off\b/,
      /\bmark\b[\s\S]{0,40}\b(?:done|complete|completed|off)\b/,
      /\b(?:got|bought|picked up|grabbed) (?:the|some|those|my)\b/,
    ],
  },
  {
    intent: "list_add",
    patterns: [
      /^add\b/,
      /\badd\b[\s\S]{0,50}\b(?:to|on)\b[\s\S]{0,30}\blist\b/,
      /\bput\b[\s\S]{0,40}\bon (?:the |my )?[\s\S]{0,20}list\b/,
    ],
  },
  {
    intent: "list_query",
    patterns: [
      /\bwhat(?:'?s| is)? (?:on|in)\b[\s\S]{0,30}\blist\b/,
      /\b(?:read|show|see)\b[\s\S]{0,30}\blist\b/,
    ],
  },
  {
    intent: "time_query",
    patterns: [
      /\bwhat time\b/,
      /\btime is it\b/,
      /\bwhat(?:'?s| is) the (?:time|date|day)\b/,
      /\bwhat day is (?:it|today)\b/,
      /\btoday'?s date\b/,
    ],
  },
  {
    intent: "capture",
    patterns: [
      /\b(?:note|jot|write) (?:this |that |it )?down\b/,
      /\btake a note\b/,
      /\bnote to self\b/,
      /\bcapture\b/,
      /\bremember that\b/,
    ],
  },
  {
    // "I'm done with the report" / "finished the workout" — task closure.
    intent: "complete_task",
    patterns: [
      /\b(?:i'?m|i am) (?:done|finished) with\b/,
      /\b(?:finished|completed) (?:the|my|that)\b/,
      /\bmark (?:the |my |that )?task[\s\S]{0,20}\b(?:done|complete)\b/,
    ],
  },
  {
    // Before question's what-catch-all: the answer is already in the
    // dynamic context — this must never cost a sonnet turn.
    intent: "weather_query",
    patterns: [
      /\bweather\b/,
      /\bforecast\b/,
      /\b(?:is it|will it) (?:going to |gonna )?(?:rain|snow)\b/,
      /\bhow (?:hot|cold|warm) is it\b/,
      /\b(?:temperature|degrees) (?:outside|today|out)\b/,
    ],
  },
  {
    // Schedule questions answer from the CALENDAR context block.
    intent: "calendar_lookup",
    patterns: [
      /\bwhat(?:'?s| is) on (?:my|the) (?:calendar|schedule|agenda)\b/,
      /\bam i free\b/,
      /\bmy (?:next|first) (?:meeting|appointment|event)\b/,
      /\bdo i have (?:any(?:thing)?|meetings|appointments|plans)\b/,
      /\bhow(?:'?s| is) my (?:day|schedule|calendar|week) look/,
      /\bwhat(?:'?s| does) my (?:day|schedule|week) look/,
    ],
  },
  {
    intent: "date_query",
    patterns: [
      /\bwhat(?:'?s| is) (?:the date|today'?s date)\b/,
      /\bwhat (?:day|date) is (?:it|today|tomorrow)\b/,
      /\bwhat month is\b/,
    ],
  },
  {
    // Bare acknowledgments — never worth a frontier model. Anchored to the
    // WHOLE utterance so "thanks, and also…" falls through to the real
    // intent behind it.
    intent: "simple_ack",
    patterns: [
      /^(?:ok(?:ay)?|k|sure|yes|yep|yeah|no|nope|nah|thanks|thank you|thanks otto|got it|sounds good|perfect|great|cool|nice|alright|all right|never ?mind|stop|cancel)[.!]?$/,
    ],
  },
  {
    intent: "question",
    patterns: [
      /\?\s*$/,
      /^(?:who|what|when|where|why|how|is|are|am|was|were|do|does|did|can|could|will|would|should|tell me)\b/,
    ],
  },
];

export function classify(utterance: string): Intent {
  const text = utterance.trim().toLowerCase();
  if (text.length === 0) {
    return "unknown";
  }
  for (const rule of RULES) {
    if (rule.patterns.some((pattern) => pattern.test(text))) {
      return rule.intent;
    }
  }
  return "unknown";
}
