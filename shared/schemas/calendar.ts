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

/*
 * ── Calendar sync (Phase 6 automations) ─────────────────────────────
 *
 * The device pushes a COMPRESSED 48-hour view so server-side automations
 * (meeting prep, briefs) can see the shape of the user's day. The shape is
 * the privacy contract: title, times, location, and an attendee COUNT —
 * never notes, never descriptions, never attendee names or emails. Those
 * fields don't exist on this type, so they cannot leak by accident, and
 * the server's parse strips them if a client ever sends extras. Synced
 * views expire server-side 48 hours after upload.
 */

/** One event as the sync view carries it. Deliberately not CalendarEvent. */
export const CalendarSyncEvent = z.object({
  id: zId,
  title: z.string().min(1).max(200),
  startsAt: isoDateTime,
  endsAt: isoDateTime,
  location: z.string().min(1).max(200).optional(),
  /** Participant count only — identities never leave the device. */
  attendeeCount: z.number().int().min(0).max(500),
});
export type CalendarSyncEvent = z.infer<typeof CalendarSyncEvent>;

export const CalendarSyncRequest = z.object({
  /** The next 48 hours, capped; the server re-clamps to its own window. */
  events: z.array(CalendarSyncEvent).max(100),
  /**
   * The device's current IANA zone. Keeps every automation's stored
   * timezone honest — landing in Tokyo re-anchors the 07:00 brief on the
   * next sync.
   */
  timezone: z.string().min(1),
});
export type CalendarSyncRequest = z.infer<typeof CalendarSyncRequest>;

export const CalendarSyncResponse = z.object({
  /** Events actually stored after the server's window clamp. */
  stored: z.number().int().min(0),
  /** Automations whose nextRunAt or timezone this sync updated. */
  rearmed: z.number().int().min(0),
});
export type CalendarSyncResponse = z.infer<typeof CalendarSyncResponse>;

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
