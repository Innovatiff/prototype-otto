/**
 * The weekly review's numbers — counted in code, never by the model. The
 * synthesis prompt receives these as THE WEEK'S FACTS and phrases them.
 */
import { Experience, SessionRecord } from "@otto/shared";

import { COLLECTIONS, db } from "../firestore.js";
import { errorFields, logWarning } from "../log.js";

export interface WeeklyFacts {
  sessionsDone: number;
  tasksCleared: number;
  voyagesPlanned: number;
  /** Sum of budget buffers on the week's voyages, in `currency`. */
  bufferKept: number;
  currency: string;
}

const WEEK_MS = 7 * 24 * 3600 * 1000;

export function weeklyFactsText(facts: WeeklyFacts): string {
  return [
    "THE WEEK'S FACTS (counted in code, trust them):",
    `- guided sessions completed: ${facts.sessionsDone}`,
    `- tasks completed: ${facts.tasksCleared}`,
    `- experiences planned: ${facts.voyagesPlanned}` +
      (facts.voyagesPlanned > 0
        ? ` (kept ${facts.bufferKept} ${facts.currency} back under budget)`
        : ""),
  ].join("\n");
}

/** Every source degrades to zero rather than failing the review. */
export async function gatherWeeklyFacts(uid: string, now: Date): Promise<WeeklyFacts> {
  const since = now.getTime() - WEEK_MS;

  let sessionsDone = 0;
  try {
    const snapshot = await db()
      .collection(COLLECTIONS.sessionRecords)
      .where("ownerId", "==", uid)
      .limit(300)
      .get();
    for (const doc of snapshot.docs) {
      const parsed = SessionRecord.safeParse(doc.data());
      if (parsed.success && new Date(parsed.data.completedAt).getTime() >= since) {
        sessionsDone += 1;
      }
    }
  } catch (err) {
    logWarning("weekly_sessions_failed", { userId: uid, ...errorFields(err) });
  }

  let tasksCleared = 0;
  try {
    const snapshot = await db()
      .collection(COLLECTIONS.tasks)
      .where("ownerId", "==", uid)
      .where("status", "==", "completed")
      .limit(200)
      .get();
    for (const doc of snapshot.docs) {
      const completedAt = (doc.data() as { completedAt?: string }).completedAt;
      if (completedAt !== undefined && new Date(completedAt).getTime() >= since) {
        tasksCleared += 1;
      }
    }
  } catch (err) {
    logWarning("weekly_tasks_failed", { userId: uid, ...errorFields(err) });
  }

  let voyagesPlanned = 0;
  let bufferKept = 0;
  let currency = "USD";
  try {
    const snapshot = await db()
      .collection(COLLECTIONS.experiences)
      .where("ownerId", "==", uid)
      .limit(100)
      .get();
    for (const doc of snapshot.docs) {
      const parsed = Experience.safeParse(doc.data());
      if (parsed.success && new Date(parsed.data.createdAt).getTime() >= since) {
        voyagesPlanned += 1;
        bufferKept += parsed.data.budget.buffer;
        currency = parsed.data.budget.currency;
      }
    }
  } catch (err) {
    logWarning("weekly_experiences_failed", { userId: uid, ...errorFields(err) });
  }

  return { sessionsDone, tasksCleared, voyagesPlanned, bufferKept, currency };
}
