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
export const BriefRequest = z.object({
  events: z.array(CalendarEvent).max(100),
  conflicts: z.array(Conflict).max(50),
  /** IANA timezone, e.g. "America/Toronto". */
  timezone: z.string().min(1),
  lat: z.number().min(-90).max(90).optional(),
  lon: z.number().min(-180).max(180).optional(),
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
});
export type BriefCard = z.infer<typeof BriefCard>;

export const BriefResponse = z.object({
  /** The text Otto says. Capped at ~150 words by the synthesis prompt. */
  spoken: z.string().min(1),
  card: BriefCard,
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
});
export type BriefRecord = z.infer<typeof BriefRecord>;
