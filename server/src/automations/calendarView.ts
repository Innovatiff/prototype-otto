/**
 * The server's copy of a user's next 48 hours — one document per user,
 * wholly replaced on every sync, expired 48 hours after upload.
 *
 * This is the ONLY calendar data Otto's server ever holds, and it is the
 * compressed shape by construction (CalendarSyncEvent: title, times,
 * location, attendee count). Retention is enforced twice: `loadCalendarView`
 * refuses to return an expired view even if the purge hasn't reached it
 * yet, and every scheduler tick deletes expired documents outright.
 */
import { CalendarSyncEvent } from "@otto/shared";
import { z } from "zod";

import { COLLECTIONS, db } from "../firestore.js";
import { logInfo, logWarning } from "../log.js";

/** How far ahead the stored view may reach. */
export const VIEW_WINDOW_MS = 48 * 60 * 60 * 1000;
/** How long a synced view lives server-side before it is purged. */
export const VIEW_TTL_MS = 48 * 60 * 60 * 1000;
/** Older than this and calendar-dependent automations stop trusting it. */
export const VIEW_STALE_MS = 24 * 60 * 60 * 1000;

const CalendarViewDoc = z.object({
  ownerId: z.string().min(1),
  syncedAt: z.string().min(1),
  timezone: z.string().min(1),
  events: z.array(CalendarSyncEvent),
});
export type CalendarViewDoc = z.infer<typeof CalendarViewDoc>;

/** What the tick and handlers see: the events plus how much to trust them. */
export interface CalendarView {
  readonly events: readonly CalendarSyncEvent[];
  readonly syncedAt: string;
  readonly timezone: string;
  readonly stale: boolean;
}

/**
 * Clamps a sync payload to the promised window: events already over are
 * dropped, events starting beyond 48 hours are dropped, the rest sorted by
 * start and capped. Timestamps are NORMALIZED to canonical UTC ISO here —
 * the schema admits offset forms ("10:00:00-04:00"), and normalizing once
 * at the boundary lets everything downstream compare strings safely.
 * Pure — the route applies it before storing.
 */
export function clampToWindow(
  events: readonly CalendarSyncEvent[],
  now: Date,
  cap = 100,
): CalendarSyncEvent[] {
  const horizon = now.getTime() + VIEW_WINDOW_MS;
  const kept: { event: CalendarSyncEvent; startMs: number }[] = [];
  for (const event of events) {
    const startMs = Date.parse(event.startsAt);
    const endMs = Date.parse(event.endsAt);
    if (Number.isNaN(startMs) || Number.isNaN(endMs)) {
      continue;
    }
    if (endMs <= now.getTime() || startMs > horizon) {
      continue;
    }
    kept.push({
      event: {
        ...event,
        startsAt: new Date(startMs).toISOString(),
        endsAt: new Date(endMs).toISOString(),
      },
      startMs,
    });
  }
  return kept
    .sort((a, b) => a.startMs - b.startMs)
    .slice(0, cap)
    .map((entry) => entry.event);
}

export function isViewStale(syncedAt: string, now: Date): boolean {
  const synced = Date.parse(syncedAt);
  if (Number.isNaN(synced)) {
    return true;
  }
  return now.getTime() - synced > VIEW_STALE_MS;
}

function viewsCollection() {
  return db().collection(COLLECTIONS.calendarViews);
}

/** Replaces the user's whole view. Document id IS the uid — one per user. */
export async function storeCalendarView(
  uid: string,
  events: readonly CalendarSyncEvent[],
  timezone: string,
  now: Date,
): Promise<void> {
  const doc: CalendarViewDoc = {
    ownerId: uid,
    syncedAt: now.toISOString(),
    timezone,
    events: [...events],
  };
  await viewsCollection().doc(uid).set(doc);
}

/**
 * The user's view, or null when there is none. An EXPIRED view (past its
 * 48-hour TTL) is treated as absent even before the purge deletes it; a
 * merely stale one (>24h) is returned with `stale: true` so callers skip
 * calendar-dependent decisions without losing the timezone signal.
 */
export async function loadCalendarView(uid: string, now: Date): Promise<CalendarView | null> {
  const snapshot = await viewsCollection().doc(uid).get();
  const data = snapshot.data();
  if (data === undefined) {
    return null;
  }
  const parsed = CalendarViewDoc.safeParse(data);
  if (!parsed.success) {
    logWarning("calendar_view_corrupt", { userId: uid });
    return null;
  }
  const synced = Date.parse(parsed.data.syncedAt);
  if (Number.isNaN(synced) || now.getTime() - synced > VIEW_TTL_MS) {
    return null;
  }
  return {
    events: parsed.data.events,
    syncedAt: parsed.data.syncedAt,
    timezone: parsed.data.timezone,
    stale: isViewStale(parsed.data.syncedAt, now),
  };
}

/** Deletes views past their TTL. Runs on every tick; bounded per pass. */
export async function purgeExpiredViews(now: Date, limit = 100): Promise<number> {
  const cutoff = new Date(now.getTime() - VIEW_TTL_MS).toISOString();
  const snapshot = await viewsCollection().where("syncedAt", "<", cutoff).limit(limit).get();
  if (snapshot.empty) {
    return 0;
  }
  const batch = db().batch();
  for (const doc of snapshot.docs) {
    batch.delete(doc.ref);
  }
  await batch.commit();
  logInfo("calendar_views_purged", { count: snapshot.size });
  return snapshot.size;
}
