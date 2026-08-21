/**
 * Brief persistence — one document per user per wall date
 * (briefs/{ownerId}_{date}, server-only by rules). The stored summary is
 * what gives tomorrow's brief its continuity.
 */
import { BriefRecord } from "@otto/shared";

import { COLLECTIONS, db } from "../firestore.js";
import { errorFields, logWarning } from "../log.js";

export async function loadBriefSummary(uid: string, date: string): Promise<string | null> {
  const snapshot = await db().collection(COLLECTIONS.briefs).doc(`${uid}_${date}`).get();
  const parsed = BriefRecord.safeParse(snapshot.data());
  if (!parsed.success || parsed.data.summary.trim().length === 0) {
    return null;
  }
  return parsed.data.summary;
}

/** The full record for a date — the instant-serve path reads this. */
export async function loadBrief(uid: string, date: string): Promise<BriefRecord | null> {
  const snapshot = await db().collection(COLLECTIONS.briefs).doc(`${uid}_${date}`).get();
  const parsed = BriefRecord.safeParse(snapshot.data());
  return parsed.success ? parsed.data : null;
}

/**
 * Whether a stored record can be served as the day's brief without
 * regenerating: it must carry the playable halves (chapters + card) and be
 * from today's world — a record older than 18 hours is yesterday's news.
 */
export function isServableBrief(
  record: BriefRecord,
  now: Date,
): record is BriefRecord & { chapters: NonNullable<BriefRecord["chapters"]>; card: NonNullable<BriefRecord["card"]> } {
  if (record.chapters === undefined || record.chapters.length === 0) {
    return false;
  }
  if (record.card === undefined) {
    return false;
  }
  const ageMs = now.getTime() - new Date(record.createdAt).getTime();
  return ageMs >= 0 && ageMs < 18 * 3600 * 1000;
}

/** Never throws — a failed store costs tomorrow's continuity, not today's brief. */
export async function storeBrief(record: BriefRecord): Promise<void> {
  try {
    await db()
      .collection(COLLECTIONS.briefs)
      .doc(`${record.ownerId}_${record.date}`)
      .set(record);
  } catch (err) {
    logWarning("brief_store_failed", { userId: record.ownerId, ...errorFields(err) });
  }
}
