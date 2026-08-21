/**
 * Account deletion — App Store Guideline 5.1.1(v) and basic decency: one
 * call erases everything Otto holds for a user, then the auth user itself.
 *
 * DELETION_SPECS is the census: every collection in COLLECTIONS must be
 * accounted for here (a meta-test enforces it), so a future collection
 * cannot silently survive deletion. Data goes first, the auth user last —
 * every step is idempotent, so a failed run is safely retried.
 */
import { FieldPath } from "firebase-admin/firestore";

import { COLLECTIONS, db, firebaseAuth } from "../firestore.js";
import { logInfo } from "../log.js";

export type DeletionSpec =
  /** Docs found by an owner field ("ownerId" / "userId"). */
  | { collection: string; field: string }
  /** One doc keyed directly by the uid. */
  | { collection: string; docId: "uid" }
  /** Docs keyed `${uid}_...` (e.g. cost_daily's `${userId}_${date}`). */
  | { collection: string; idPrefix: "uid_" };

export const DELETION_SPECS: readonly DeletionSpec[] = [
  { collection: COLLECTIONS.tasks, field: "ownerId" },
  { collection: COLLECTIONS.memories, field: "ownerId" },
  { collection: COLLECTIONS.sessions, field: "ownerId" },
  { collection: COLLECTIONS.briefs, field: "ownerId" },
  { collection: COLLECTIONS.plans, field: "ownerId" },
  { collection: COLLECTIONS.experiences, field: "ownerId" },
  { collection: COLLECTIONS.sessionRecords, field: "ownerId" },
  { collection: COLLECTIONS.automations, field: "ownerId" },
  { collection: COLLECTIONS.deliveries, field: "ownerId" },
  { collection: COLLECTIONS.costEvents, field: "userId" },
  { collection: COLLECTIONS.costDaily, idPrefix: "uid_" },
  { collection: COLLECTIONS.calendarViews, docId: "uid" },
  { collection: COLLECTIONS.users, docId: "uid" },
];

const CHUNK = 200;

async function deleteByQuery(
  query: FirebaseFirestore.Query,
): Promise<number> {
  let deleted = 0;
  for (;;) {
    const snapshot = await query.limit(CHUNK).get();
    if (snapshot.empty) {
      return deleted;
    }
    const batch = db().batch();
    for (const doc of snapshot.docs) {
      batch.delete(doc.ref);
    }
    await batch.commit();
    deleted += snapshot.size;
    if (snapshot.size < CHUNK) {
      return deleted;
    }
  }
}

/** Erases every document the specs name. Idempotent; safe to retry. */
export async function deleteAccountData(uid: string): Promise<Record<string, number>> {
  const counts: Record<string, number> = {};
  for (const spec of DELETION_SPECS) {
    if ("field" in spec) {
      counts[spec.collection] = await deleteByQuery(
        db().collection(spec.collection).where(spec.field, "==", uid),
      );
    } else if ("idPrefix" in spec) {
      counts[spec.collection] = await deleteByQuery(
        db()
          .collection(spec.collection)
          .where(FieldPath.documentId(), ">=", `${uid}_`)
          .where(FieldPath.documentId(), "<=", `${uid}_\uf8ff`),
      );
    } else {
      await db().collection(spec.collection).doc(uid).delete();
      counts[spec.collection] = 1;
    }
  }
  return counts;
}

/** Data first, then the auth user — the account is gone when this returns. */
export async function deleteAccount(uid: string): Promise<void> {
  const counts = await deleteAccountData(uid);
  try {
    await firebaseAuth().deleteUser(uid);
  } catch (err) {
    // Already deleted (a retry) is success; anything else surfaces.
    const code = (err as { code?: string }).code;
    if (code !== "auth/user-not-found") {
      throw err;
    }
  }
  logInfo("account_deleted", { userId: uid, ...counts });
}
