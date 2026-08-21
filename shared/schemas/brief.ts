import { z } from "zod";
import { CalendarEvent, Conflict } from "./calendar.js";
import { isoDateTime, zId } from "./common.js";
import { CurrentWeather } from "./weather.js";

/**
 * What the client sends to POST /brief. Calendar data comes FROM THE CLIENT
 * (EventKit lives on-device), conflicts already computed deterministically
 * in Swift. Coordinates are an optional explicit setting — never location
 * services, which are out of scope; the server falls back to a default.
 */
/**
 * Which bookend this is. Morning is the classic brief (stored for
 * continuity and served instantly when pre-generated); evening closes the
 * day (tomorrow's first thing, what slipped, one line of closure); weekly
 * is Sunday's mirror (the week's numbers, spoken kindly).
 */
export const BriefMode = z.enum(["morning", "evening", "weekly"]);
export type BriefMode = z.infer<typeof BriefMode>;

export const BriefRequest = z.object({
  events: z.array(CalendarEvent).max(100),
  conflicts: z.array(Conflict).max(50),
  /** IANA timezone, e.g. "America/Toronto". */
  timezone: z.string().min(1),
  lat: z.number().min(-90).max(90).optional(),
  lon: z.number().min(-180).max(180).optional(),
  /** Absent = "morning". */
  mode: BriefMode.optional(),
});
export type BriefRequest = z.infer<typeof BriefRequest>;

/** A reminder firing today, for the card. */
export const BriefDueTask = z.object({
  taskId: zId,
  title: z.string(),
  at: isoDateTime,
});
export type BriefDueTask = z.infer<typeof BriefDueTask>;

/** An open list, counted — contents never ride in the brief. */
export const BriefListCount = z.object({
  taskId: zId,
  title: z.string(),
  context: z.string().optional(),
  openCount: z.number().int().min(0),
});
export type BriefListCount = z.infer<typeof BriefListCount>;

/** A plan session falling on today — what the plans chapter shows. */
export const BriefPlanSession = z.object({
  planId: zId,
  sessionId: zId,
  sessionTitle: z.string(),
  domain: z.string(),
  /** 1-indexed week of the plan this occurrence falls in. */
  week: z.number().int().min(1),
  /** Local wall-clock time when the schedule pins one, e.g. "08:00". */
  timeOfDay: z.string().optional(),
  /** Already completed today — spoken as banked, shown checked. */
  completed: z.boolean(),
});
export type BriefPlanSession = z.infer<typeof BriefPlanSession>;

/**
 * The structured half of the brief — what renders on screen while the
 * spoken half plays. Detail lives here; the voice is the summary.
 */
export const BriefCard = z.object({
  /** Wall date in the user's timezone, YYYY-MM-DD. */
  date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
  weather: CurrentWeather.optional(),
  events: z.array(CalendarEvent),
  conflicts: z.array(Conflict),
  dueTasks: z.array(BriefDueTask),
  lists: z.array(BriefListCount),
  /** Today's plan sessions; empty when nothing falls today. */
  planSessions: z.array(BriefPlanSession).optional(),
});
export type BriefCard = z.infer<typeof BriefCard>;

/**
 * One chapter of the spoken brief. The client plays chapters in order,
 * sliding the matching visual (weather tile, calendar list, reminders) in
 * while each one is being spoken — the words and the screen move together.
 */
export const BriefChapterKind = z.enum([
  "intro",
  "weather",
  "calendar",
  "plans",
  "reminders",
  "outro",
]);
export type BriefChapterKind = z.infer<typeof BriefChapterKind>;

export const BriefChapter = z.object({
  kind: BriefChapterKind,
  /** This chapter's sentences, spoken style. */
  spoken: z.string().min(1).max(600),
});
export type BriefChapter = z.infer<typeof BriefChapter>;

export const BriefResponse = z.object({
  /** The full text Otto says — the chapters joined, for storage and search. */
  spoken: z.string().min(1),
  card: BriefCard,
  /** The same speech, segmented for the synced visual tour. */
  chapters: z.array(BriefChapter).max(8).optional(),
});
export type BriefResponse = z.infer<typeof BriefResponse>;

/**
 * One brief as stored (briefs/{ownerId}_{date}, server-only by rules).
 * `summary` is what tomorrow's brief reads for continuity.
 */
export const BriefRecord = z.object({
  ownerId: zId,
  date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
  spoken: z.string(),
  summary: z.string(),
  createdAt: isoDateTime,
  /**
   * The full playable brief, when the wake-time automation pre-generated
   * it — POST /brief serves these instantly instead of regenerating, so a
   * push tap goes straight to voice.
   */
  chapters: z.array(BriefChapter).max(8).optional(),
  card: BriefCard.optional(),
});
export type BriefRecord = z.infer<typeof BriefRecord>;
