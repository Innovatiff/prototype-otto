import { z } from "zod";
import { isoDateTime, zId } from "./common.js";

/*
 * NOTE: Phase 4 consumes these schemas. No behavior is implemented here.
 * They are defined now purely so the Swift models generate once and never
 * churn when planning lands.
 */

/** How a step is measured / paced. */
export const StepType = z.enum(["timed", "counted", "checklist", "prompt"]);
export type StepType = z.infer<typeof StepType>;

/** How a step is marked complete. */
export const StepCompletion = z.enum(["auto", "manual", "voice"]);
export type StepCompletion = z.infer<typeof StepCompletion>;

/** Optional quantitative targets for a step. */
export const StepTarget = z.object({
  sets: z.number().int().optional(),
  reps: z.number().int().optional(),
  /** Load/weight — kept as a floating value to allow e.g. 2.5 kg. */
  load: z.number().optional(),
  durationSec: z.number().int().optional(),
});
export type StepTarget = z.infer<typeof StepTarget>;

/** A single instruction within a session. */
export const Step = z.object({
  id: zId,
  type: StepType,
  title: z.string(),
  /** The spoken instruction. */
  cue: z.string(),
  target: StepTarget.optional(),
  mediaUrl: z.string().url().optional(),
  completion: StepCompletion,
});
export type Step = z.infer<typeof Step>;

/** An ordered collection of steps done in one sitting. */
export const Session = z.object({
  id: zId,
  title: z.string(),
  estimatedMinutes: z.number().int(),
  steps: z.array(Step),
});
export type Session = z.infer<typeof Session>;

/** Places a session on the calendar relative to plan start. */
export const ScheduledSession = z.object({
  sessionId: zId,
  dayOffset: z.number().int(),
  /** Local wall-clock time, e.g. "08:00". */
  timeOfDay: z.string().optional(),
});
export type ScheduledSession = z.infer<typeof ScheduledSession>;

/** Descriptive metadata for a plan. */
export const PlanMeta = z.object({
  domain: z.string(),
  goal: z.string(),
  horizonDays: z.number().int(),
  version: z.number().int(),
});
export type PlanMeta = z.infer<typeof PlanMeta>;

/** A structured, multi-week program Otto generates and guides the user through. */
export const Plan = z.object({
  id: zId,
  ownerId: zId,
  meta: PlanMeta,
  constraints: z.record(z.string(), z.unknown()),
  schedule: z.array(ScheduledSession),
  sessions: z.array(Session),
  supersedes: zId.optional(),
  createdAt: isoDateTime,
});
export type Plan = z.infer<typeof Plan>;
