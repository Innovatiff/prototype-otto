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
