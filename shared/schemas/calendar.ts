import { z } from "zod";
import { isoDateTime, zId } from "./common.js";

/**
 * A calendar event as Otto sees it — a clean domain type. EKEvent never
 * leaves the iOS service layer; this shape is what crosses to the server
 * (brief context, conversation context) and back.
 */
export const CalendarEvent = z.object({
  id: zId,
  title: z.string().min(1),
  startsAt: isoDateTime,
  endsAt: isoDateTime,
  isAllDay: z.boolean().default(false),
  location: z.string().optional(),
  notes: z.string().optional(),
});
export type CalendarEvent = z.infer<typeof CalendarEvent>;

/** What Otto needs to create an event. */
export const EventDraft = z.object({
  title: z.string().min(1),
  startsAt: isoDateTime,
  endsAt: isoDateTime,
  location: z.string().optional(),
  notes: z.string().optional(),
});
export type EventDraft = z.infer<typeof EventDraft>;

/**
 * A schedule problem, detected DETERMINISTICALLY in Swift — never by the
 * model (it misses some and invents others).
 *   - overlap: the two events share time; minutesShort is the overlap length.
 *   - travel: back-to-back at different locations with under 30 minutes
 *     between them; minutesShort is how many of those 30 are missing.
 */
export const ConflictKind = z.enum(["overlap", "travel"]);
export type ConflictKind = z.infer<typeof ConflictKind>;

export const Conflict = z.object({
  eventA: CalendarEvent,
  eventB: CalendarEvent,
  kind: ConflictKind,
  minutesShort: z.number().int().min(0),
});
export type Conflict = z.infer<typeof Conflict>;
