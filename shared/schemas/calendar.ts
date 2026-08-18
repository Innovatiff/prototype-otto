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

/**
 * A calendar change the model PROPOSES. Nothing is written server-side:
 * the client renders a confirmation card, the user confirms by voice or
 * tap, the write goes through EventKit, and success is only ever reported
 * after reading the event back from the calendar.
 */
export const CalendarProposal = z.discriminatedUnion("kind", [
  z.object({
    kind: z.literal("create"),
    draft: EventDraft,
  }),
  z.object({
    kind: z.literal("move"),
    /** The event named by the user; the client resolves it fuzzily. */
    eventTitle: z.string().min(1),
    newStartsAt: isoDateTime,
    /** Absent = keep the event's current duration. */
    newEndsAt: isoDateTime.optional(),
  }),
]);
export type CalendarProposal = z.infer<typeof CalendarProposal>;
