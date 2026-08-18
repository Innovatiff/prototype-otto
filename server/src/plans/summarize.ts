/**
 * The spoken summary's raw material — computed from the plan, never asked of
 * a model. The tool result hands these facts to the conversation model,
 * which phrases them aloud; the plan itself never enters the tool result, so
 * reading a full plan aloud is structurally impossible.
 */
import { DELOAD_MAX_MULTIPLIER } from "./safety.js";

/** Structural: accepts both a GeneratedPlanPayload and a stamped Plan. */
interface PlanShape {
  meta: { horizonDays: number };
  sessions: readonly { title: string; estimatedMinutes: number }[];
  schedule: readonly { dayOffset: number; progression?: { loadMultiplier?: number } }[];
}

export interface PlanSummaryFacts {
  weeks: number;
  /** Typical sessions per week (the most common weekly count). */
  daysPerWeek: number;
  /** "45" or "30-60" when templates vary. */
  minutes: string;
  /** 1-indexed week whose entries all sit at deload load, or null. */
  deloadWeek: number | null;
  templateTitles: string[];
}

export function summarizeFacts(plan: PlanShape): PlanSummaryFacts {
  const weeks = Math.max(1, Math.ceil(plan.meta.horizonDays / 7));

  const perWeek = new Map<number, number>();
  for (const entry of plan.schedule) {
    const week = Math.floor(entry.dayOffset / 7);
    perWeek.set(week, (perWeek.get(week) ?? 0) + 1);
  }
  const countFrequency = new Map<number, number>();
  for (const count of perWeek.values()) {
    countFrequency.set(count, (countFrequency.get(count) ?? 0) + 1);
  }
  let daysPerWeek = 0;
  let bestFrequency = 0;
  for (const [count, frequency] of countFrequency) {
    if (frequency > bestFrequency || (frequency === bestFrequency && count > daysPerWeek)) {
      daysPerWeek = count;
      bestFrequency = frequency;
    }
  }

  const allMinutes = plan.sessions.map((session) => session.estimatedMinutes);
  const shortest = Math.min(...allMinutes);
  const longest = Math.max(...allMinutes);
  const minutes = shortest === longest ? `${longest}` : `${shortest}-${longest}`;

  let deloadWeek: number | null = null;
  for (const [week, count] of perWeek) {
    const entries = plan.schedule.filter((e) => Math.floor(e.dayOffset / 7) === week);
    const allLight =
      count > 0 &&
      entries.every((e) => (e.progression?.loadMultiplier ?? 1.0) <= DELOAD_MAX_MULTIPLIER);
    if (allLight && (deloadWeek === null || week + 1 < deloadWeek)) {
      deloadWeek = week + 1;
    }
  }

  return {
    weeks,
    daysPerWeek,
    minutes,
    deloadWeek,
    templateTitles: plan.sessions.map((session) => session.title),
  };
}

/** One compact line the model speaks from, e.g.
 *  "8 weeks · 4 sessions/week · ~45 min · deload week 5 · templates: …" */
export function summaryLine(plan: PlanShape): string {
  const facts = summarizeFacts(plan);
  const parts = [
    `${facts.weeks} weeks`,
    `${facts.daysPerWeek} sessions/week`,
    `~${facts.minutes} min`,
  ];
  if (facts.deloadWeek !== null) {
    parts.push(`deload week ${facts.deloadWeek}`);
  }
  parts.push(`templates: ${facts.templateTitles.join(", ")}`);
  return parts.join(" · ");
}
