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

/**
 * Overrides a schedule entry applies to its session template.
 *
 * The core generation rule depends on this: an 8-week program is 4-6
 * DISTINCT session templates in sessions[], referenced from schedule[] with
 * progression overrides — never 32 expanded sessions. This is how real
 * programs are written, it keeps generation to one reasonable call, and it
 * makes adaptation cheap.
 */
export const Progression = z.object({
  /** Multiplies every step load in the template; 1.0 = as written. */
  loadMultiplier: z.number().positive().optional(),
  /** Added to every counted step's reps. */
  repsDelta: z.number().int().optional(),
  /** Added to every counted step's sets. */
  setsDelta: z.number().int().optional(),
  /** e.g. "deload week — keep it light". */
  note: z.string().optional(),
});
export type Progression = z.infer<typeof Progression>;

/** Places a session on the calendar relative to plan start. */
export const ScheduledSession = z.object({
  sessionId: zId,
  dayOffset: z.number().int(),
  /** Local wall-clock time, e.g. "08:00". */
  timeOfDay: z.string().optional(),
  /** Overrides applied to the referenced template for this occurrence. */
  progression: Progression.optional(),
});
export type ScheduledSession = z.infer<typeof ScheduledSession>;

/**
 * Domains a one-shot walkthrough can wear — free of the multi-week plan
 * domains; these drive the client's illustrations and nothing else.
 */
export const WalkthroughDomain = z.enum([
  "cooking",
  "repair",
  "errand",
  "fitness",
  "chores",
  "learning",
  "other",
]);
export type WalkthroughDomain = z.infer<typeof WalkthroughDomain>;

/**
 * A one-shot guided walkthrough: a single session Otto builds on the spot
 * — cook this dish, change this tire, fix the faucet — and talks the user
 * through step by step. Never persisted: it rides the turn stream as a
 * walkthrough_ready event and lives in the guidance runtime.
 */
export const Walkthrough = z.object({
  domain: WalkthroughDomain,
  session: Session,
});
export type Walkthrough = z.infer<typeof Walkthrough>;

/** Descriptive metadata for a plan. */
export const PlanMeta = z.object({
  domain: z.string(),
  goal: z.string(),
  horizonDays: z.number().int(),
  version: z.number().int(),
});
export type PlanMeta = z.infer<typeof PlanMeta>;

/**
 * Lifecycle. Plans are IMMUTABLE once created: a change produces a new plan
 * document with `supersedes` pointing at this one and meta.version + 1; the
 * old one flips to "superseded". At most one active plan per domain.
 */
export const PlanStatus = z.enum(["active", "superseded"]);
export type PlanStatus = z.infer<typeof PlanStatus>;

/**
 * Links one scheduled occurrence to the calendar event created for it.
 * Written by the server after the DEVICE has created the event via EventKit
 * and verified it by read-back — so adaptation can move real events later.
 */
export const PlanCalendarEvent = z.object({
  sessionId: zId,
  dayOffset: z.number().int(),
  /** The EventKit event identifier from the verified write. */
  eventId: z.string().min(1),
});
export type PlanCalendarEvent = z.infer<typeof PlanCalendarEvent>;

/** A structured, multi-week program Otto generates and guides the user through. */
export const Plan = z.object({
  id: zId,
  ownerId: zId,
  meta: PlanMeta,
  constraints: z.record(z.string(), z.unknown()),
  schedule: z.array(ScheduledSession),
  sessions: z.array(Session),
  status: PlanStatus,
  supersedes: zId.optional(),
  /** Verified calendar links; absent until the user schedules the plan. */
  calendarEvents: z.array(PlanCalendarEvent).optional(),
  createdAt: isoDateTime,
});
export type Plan = z.infer<typeof Plan>;

/** POST /plans/:planId/calendar-events — the device reports verified writes. */
export const PlanCalendarEventsRequest = z.object({
  events: z.array(PlanCalendarEvent).min(1).max(200),
});
export type PlanCalendarEventsRequest = z.infer<typeof PlanCalendarEventsRequest>;

/**
 * A plan without its body — what GET /plans lists. Full sessions and
 * schedule come from GET /plans/:id; summaries keep the list light and are
 * all the version-history UI needs.
 */
export const PlanSummary = z.object({
  id: zId,
  meta: PlanMeta,
  status: PlanStatus,
  supersedes: zId.optional(),
  sessionCount: z.number().int().min(0),
  scheduleEntryCount: z.number().int().min(0),
  createdAt: isoDateTime,
});
export type PlanSummary = z.infer<typeof PlanSummary>;

/** GET /plans response. */
export const PlanListResponse = z.object({
  plans: z.array(PlanSummary),
});
export type PlanListResponse = z.infer<typeof PlanListResponse>;

/**
 * What the device reports when a guided session ends — POST
 * /plans/:planId/sessions. Written from the runtime's snapshot; queued
 * on-device and retried when offline (a basement session must lose
 * nothing).
 */
export const SessionRecordUpload = z.object({
  /** The session TEMPLATE id within the plan. */
  sessionId: zId,
  /** The scheduled occurrence this run was for, when known. */
  scheduledDate: isoDateTime.optional(),
  startedAt: isoDateTime,
  completedAt: isoDateTime,
  completedSteps: z.array(zId).max(100),
  skippedSteps: z.array(zId).max(100),
  /** stepId → what actually happened, verbatim ("135 pounds"). */
  loggedValues: z.record(z.string(), z.string()),
  /** Wall-clock, start to end. */
  durationSec: z.number().int().min(0),
  endedEarly: z.boolean(),
});
export type SessionRecordUpload = z.infer<typeof SessionRecordUpload>;

/** A stored session record — the upload plus server-owned identity. */
export const SessionRecord = z.object({
  id: zId,
  ownerId: zId,
  planId: zId,
  sessionId: zId,
  scheduledDate: isoDateTime.optional(),
  startedAt: isoDateTime,
  completedAt: isoDateTime,
  completedSteps: z.array(zId).max(100),
  skippedSteps: z.array(zId).max(100),
  loggedValues: z.record(z.string(), z.string()),
  durationSec: z.number().int().min(0),
  endedEarly: z.boolean(),
});
export type SessionRecord = z.infer<typeof SessionRecord>;

/** A step skipped in 2+ sessions — flagged for substitution. */
export const SubstitutionCandidate = z.object({
  stepId: zId,
  skips: z.number().int().min(2),
});
export type SubstitutionCandidate = z.infer<typeof SubstitutionCandidate>;

/**
 * GET /plans/:planId/summary — the adaptation loop's aggregate view.
 * Progressive overload reads latestLoggedValues (what actually happened,
 * newest wins); repeatedly skipped steps surface as substitution
 * candidates; missedThisWeek feeds Phase 6's proactive check-in.
 */
export const PlanProgressSummary = z.object({
  planId: zId,
  records: z.number().int().min(0),
  /** Scheduled occurrences whose day has fully passed. */
  scheduledToDate: z.number().int().min(0),
  missedToDate: z.number().int().min(0),
  /** Rolling 7 days: scheduled minus attended. ≥2 triggers a check-in. */
  missedThisWeek: z.number().int().min(0),
  lastCompletedAt: isoDateTime.optional(),
  /** Steps skipped in 2+ sessions — flag for substitution. */
  substitutionCandidates: z.array(SubstitutionCandidate),
  /** stepId → most recent logged value across records. */
  latestLoggedValues: z.record(z.string(), z.string()),
});
export type PlanProgressSummary = z.infer<typeof PlanProgressSummary>;
