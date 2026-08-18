/**
 * Plan safety guardrails. Applied to fitness plans now; nutrition joins in
 * Phase 8.
 *
 * Three layers, per spec:
 * 1. Refuse-and-reframe lives in the PROMPT (SAFETY_GUIDANCE, wired into the
 *    conversation prompt with the interview guidance).
 * 2. Hard limits are checked HERE, in TypeScript, after generation — the
 *    model is never trusted to self-audit. Failures reject the plan and feed
 *    the regeneration retry.
 * 3. Risk-signal detection routes the generation itself to a
 *    performance-framed plan (PERFORMANCE_FRAMING) and logs for review.
 */
import type { GeneratedPlanPayload } from "./generate.js";
import type { PlanConstraints } from "./interview.js";

// ── Prompt blocks ───────────────────────────────────────────────────

/**
 * Conversation-prompt block: how Otto talks about outcomes. Injected
 * alongside INTERVIEW_GUIDANCE when plan tools are wired (Step 6).
 */
export const SAFETY_GUIDANCE = `PLAN SAFETY (fitness)
- NEVER promise a body outcome by a date — not abs, not a number on the
  scale, not a size. When they ask for one: acknowledge the goal and the
  deadline honestly, state what the timeframe can realistically deliver,
  then offer the real program. The tone to hit:
  "Eight weeks of solid training will make a real, visible difference in
  how you look and how you carry yourself. Visible abs depend a lot on
  where you're starting from, and I'd rather set you up to win than
  promise you something I can't control."
- If they push rapid loss, extreme deficits, or restriction: say plainly
  what is realistic, keep all the warmth, and offer a performance-framed
  plan instead — strength, capacity, consistency. Never provide calorie
  targets or crash protocols.`;

/**
 * Appended to the generation user message when risk signals fire: the plan
 * itself gets performance framing, not just the conversation around it.
 */
export const PERFORMANCE_FRAMING = `PERFORMANCE FRAMING — REQUIRED
This request carried risk signals (rapid loss, extreme deficit, restriction
language, or a body target tied to an event). Build the plan around
performance instead:
- NO appearance goals anywhere — no abs, leanness, weight, or size targets.
- NO calorie targets, deficits, or eating restriction of any kind.
- Goals are strength, capacity, and consistency: loads, reps, minutes,
  sessions completed.
- Progression stays conservative. The plan must be sustainable well past
  any event or date they mentioned.`;

// ── Deterministic post-generation checks ────────────────────────────

/** A plan longer than this (5 weeks) must contain a deload week. */
export const DELOAD_REQUIRED_ABOVE_DAYS = 35;
/** An entry counts toward a deload week at or below this multiplier. */
export const DELOAD_MAX_MULTIPLIER = 0.8;
/** Week-over-week load growth beyond this factor is rejected. */
export const WEEKLY_PROGRESSION_CAP = 1.1;
/** Sessions may exceed the stated available time by at most 15%. */
export const SESSION_TIME_TOLERANCE = 1.15;

export type SafetyRule =
  | "domain-mismatch"
  | "missing-deload"
  | "progression-too-fast"
  | "session-too-long"
  | "equipment-violation";

export interface SafetyViolation {
  rule: SafetyRule;
  detail: string;
}

function checkDeload(payload: GeneratedPlanPayload): SafetyViolation[] {
  if (payload.meta.horizonDays <= DELOAD_REQUIRED_ABOVE_DAYS) return [];
  const weeks = new Map<number, number[]>();
  for (const entry of payload.schedule) {
    const week = Math.floor(entry.dayOffset / 7);
    const multipliers = weeks.get(week) ?? [];
    multipliers.push(entry.progression?.loadMultiplier ?? 1.0);
    weeks.set(week, multipliers);
  }
  for (const multipliers of weeks.values()) {
    if (multipliers.every((m) => m <= DELOAD_MAX_MULTIPLIER)) return [];
  }
  const totalWeeks = Math.ceil(payload.meta.horizonDays / 7);
  return [
    {
      rule: "missing-deload",
      detail:
        `${totalWeeks}-week plan has no deload week. Add one week where EVERY ` +
        `entry has progression.loadMultiplier ≤ ${DELOAD_MAX_MULTIPLIER} ` +
        `(use ~0.6 with note "deload week — keep it light").`,
    },
  ];
}

function checkProgression(payload: GeneratedPlanPayload): SafetyViolation[] {
  const violations: SafetyViolation[] = [];
  const bySession = new Map<string, { dayOffset: number; multiplier: number }[]>();
  for (const entry of payload.schedule) {
    const entries = bySession.get(entry.sessionId) ?? [];
    entries.push({
      dayOffset: entry.dayOffset,
      multiplier: entry.progression?.loadMultiplier ?? 1.0,
    });
    bySession.set(entry.sessionId, entries);
  }
  for (const [sessionId, entries] of bySession) {
    entries.sort((a, b) => a.dayOffset - b.dayOffset);
    // Peak-based: post-deload returns to a prior peak are fine; the cap
    // compounds over skipped weeks. 1.0 is the template as written.
    let peak = 1.0;
    let peakWeek = Math.floor((entries[0]?.dayOffset ?? 0) / 7);
    for (const entry of entries) {
      const week = Math.floor(entry.dayOffset / 7);
      const allowed = peak * WEEKLY_PROGRESSION_CAP ** Math.max(1, week - peakWeek);
      if (entry.multiplier > allowed + 1e-9) {
        violations.push({
          rule: "progression-too-fast",
          detail:
            `session "${sessionId}": loadMultiplier ${entry.multiplier} at day ` +
            `${entry.dayOffset} exceeds 10%/week growth (allowed ≤ ${allowed.toFixed(3)}). ` +
            `Progress 2.5-5% per week.`,
        });
      }
      if (entry.multiplier > peak) {
        peak = entry.multiplier;
        peakWeek = week;
      }
    }
  }
  return violations;
}

function checkSessionTime(
  payload: GeneratedPlanPayload,
  constraints: PlanConstraints,
): SafetyViolation[] {
  const stated = constraints.minutesPerSession;
  if (stated === undefined) return [];
  const cap = stated * SESSION_TIME_TOLERANCE;
  return payload.sessions
    .filter((session) => session.estimatedMinutes > cap)
    .map((session) => ({
      rule: "session-too-long" as const,
      detail:
        `session "${session.id}" is ${session.estimatedMinutes} min; they have ` +
        `${stated} (max ${Math.floor(cap)} with 15% tolerance). Cut volume, ` +
        `not rest.`,
    }));
}

/**
 * Equipment detection is keyword-based over titles and cues — deterministic
 * and best-effort: it catches every explicit mention, which is what the
 * guidance makes the model write ("dumbbell at your chest").
 */
const EQUIPMENT_TERMS: { term: string; pattern: RegExp }[] = [
  { term: "barbell", pattern: /\bbarbells?\b|\btrap bar\b|\bez bar\b/i },
  { term: "dumbbell", pattern: /\bdumbbells?\b/i },
  { term: "kettlebell", pattern: /\bkettlebells?\b/i },
  { term: "cable", pattern: /\bcables?\b/i },
  { term: "machine", pattern: /\bmachines?\b/i },
  { term: "bench", pattern: /\bbench\b/i },
  { term: "pull-up bar", pattern: /\b(?:pull|chin)[- ]?up bar\b/i },
  { term: "band", pattern: /\bbands?\b/i },
  { term: "rack", pattern: /\b(?:squat |power )?racks?\b/i },
  { term: "treadmill", pattern: /\btreadmills?\b/i },
  { term: "rower", pattern: /\browers?\b|\browing machine\b/i },
  { term: "bike", pattern: /\bbikes?\b|\bcycling\b/i },
  { term: "box", pattern: /\bbox jumps?\b|\bplyo box\b/i },
  { term: "sled", pattern: /\bsleds?\b/i },
  { term: "medicine ball", pattern: /\b(?:medicine|med) balls?\b|\bslam balls?\b/i },
  { term: "jump rope", pattern: /\bjump rope\b|\bskipping rope\b/i },
];

const GYM_WILDCARD = /\bgym\b|\beverything\b/i;
const NO_EQUIPMENT = /^(?:none|nothing|bodyweight(?: only)?|no equipment)$/i;

function checkEquipment(
  payload: GeneratedPlanPayload,
  constraints: PlanConstraints,
): SafetyViolation[] {
  const equipment = constraints.equipment;
  if (equipment === undefined || equipment.length === 0) return [];
  if (equipment.some((item) => GYM_WILDCARD.test(item))) return [];
  const owned = equipment.every((item) => NO_EQUIPMENT.test(item.trim()))
    ? ""
    : equipment.join(", ").toLowerCase();

  const violations: SafetyViolation[] = [];
  for (const session of payload.sessions) {
    const text = [session.title, ...session.steps.flatMap((s) => [s.title, s.cue])].join("\n");
    for (const { term, pattern } of EQUIPMENT_TERMS) {
      if (pattern.test(text) && !pattern.test(owned)) {
        violations.push({
          rule: "equipment-violation",
          detail:
            `session "${session.id}" uses ${term}, but they only have: ` +
            `${equipment.join(", ")}. Substitute the movement.`,
        });
      }
    }
  }
  return violations;
}

/**
 * All deterministic checks. Gated on the CONSTRAINTS domain (ground truth
 * from the interview), not the emitted one — so a mislabeled emission can't
 * dodge the fitness checks. Returns [] when the plan passes.
 */
export function checkPlanSafety(
  payload: GeneratedPlanPayload,
  constraints: PlanConstraints,
): SafetyViolation[] {
  const violations: SafetyViolation[] = [];
  if (payload.meta.domain !== constraints.domain) {
    violations.push({
      rule: "domain-mismatch",
      detail:
        `plan domain "${payload.meta.domain}" does not match the requested ` +
        `domain "${constraints.domain}".`,
    });
  }
  if (constraints.domain === "fitness") {
    violations.push(
      ...checkDeload(payload),
      ...checkProgression(payload),
      ...checkSessionTime(payload, constraints),
      ...checkEquipment(payload, constraints),
    );
  }
  return violations.slice(0, 20);
}

// ── Risk-signal detection ───────────────────────────────────────────

export type RiskSignalKind =
  | "rapid-loss"
  | "extreme-deficit"
  | "restriction"
  | "event-body-target";

export interface RiskSignal {
  kind: RiskSignalKind;
  match: string;
}

const RAPID_LOSS_PATTERNS = [
  // An amount of weight tied to a timeframe.
  /\b(?:lose|drop|shed|cut)\b[^.!?]{0,40}?\b\d+(?:\.\d+)?\s*(?:kg|kilos?|lbs?|pounds?)\b[^.!?]{0,40}?\b(?:in|by|before|until|within)\b/i,
  /\b(?:as (?:fast|quickly) as (?:possible|i can)|crash diet|rapid(?:ly)? (?:lose|loss|cut)|(?:lose|drop) weight fast)\b/i,
];

const RESTRICTION_PATTERN =
  /\b(?:skip(?:ping)? meals?|stop eating|barely eat(?:ing)?|starv(?:e|ing|ation)|no food|one meal a day|omad|water fast(?:ing)?|fast(?:ing)? all day|punish(?:ing)? myself|burn off (?:what|everything))\b/i;

const EVENT_PATTERN =
  /\b(?:wedding|beach|vacation|holiday|reunion|photo\s?shoot|graduation|prom|summer|party|competition weigh[- ]?in)\b/i;
const BODY_PATTERN =
  /\b(?:abs|six[- ]?pack|shredded|ripped|lean(?:er)?|toned?|skinny|slim(?:mer)?|weight|fat|look (?:good|great|amazing))\b/i;

const CALORIE_MENTION = /(\d{3,4})\s*(?:k?cals?|calories?)\b/gi;
const INTAKE_BEFORE =
  /\b(?:eat(?:ing)?|diet|only|under|less than|limit(?:ing)?|stick(?:ing)? to|live on|on|have|having)\b[^.!?]{0,30}$/i;
const BURN_BEFORE = /\b(?:burn(?:ing|s)?|torch(?:ing)?)\b[^.!?]{0,30}$/i;
const PER_DAY_AFTER = /^\s*(?:a day|per day|daily|diets?\b)/i;
const DEFICIT_AFTER = /^\s*deficit\b/i;

function detectExtremeDeficit(text: string): string | null {
  for (const match of text.matchAll(CALORIE_MENTION)) {
    const index = match.index;
    const amount = Number.parseInt(match[1] ?? "", 10);
    const before = text.slice(Math.max(0, index - 40), index);
    const after = text.slice(index + match[0].length, index + match[0].length + 20);
    if (BURN_BEFORE.test(before)) continue; // "burn 500 calories" is a workout, not a diet
    const statedIntake =
      amount < 1200 && (INTAKE_BEFORE.test(before) || PER_DAY_AFTER.test(after));
    const hugeDeficit = amount >= 1000 && DEFICIT_AFTER.test(after);
    if (statedIntake || hugeDeficit) {
      return text.slice(Math.max(0, index - 20), index + match[0].length).trim();
    }
  }
  return null;
}

/** Deterministic scan; first match per kind. A false positive is safe — it
 * only performance-frames a plan that would have been fine anyway. */
export function detectRiskSignals(text: string): RiskSignal[] {
  const signals: RiskSignal[] = [];

  for (const pattern of RAPID_LOSS_PATTERNS) {
    const match = pattern.exec(text);
    if (match !== null) {
      signals.push({ kind: "rapid-loss", match: match[0] });
      break;
    }
  }

  const deficit = detectExtremeDeficit(text);
  if (deficit !== null) {
    signals.push({ kind: "extreme-deficit", match: deficit });
  }

  const restriction = RESTRICTION_PATTERN.exec(text);
  if (restriction !== null) {
    signals.push({ kind: "restriction", match: restriction[0] });
  }

  const event = EVENT_PATTERN.exec(text);
  const body = BODY_PATTERN.exec(text);
  if (event !== null && body !== null) {
    signals.push({ kind: "event-body-target", match: `${event[0]} + ${body[0]}` });
  }

  return signals;
}

/** The free-text constraint fields worth scanning — where intent lives. */
export function constraintsRiskText(constraints: PlanConstraints): string {
  return [
    constraints.goal,
    constraints.notes,
    constraints.monthGoal,
    constraints.motivation,
    constraints.targetDate,
  ]
    .filter((part): part is string => part !== undefined)
    .join("\n");
}
