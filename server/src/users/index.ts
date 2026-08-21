/**
 * User profiles — users/{uid}, one document per owner.
 *
 * The read path never writes: an absent or invalid document yields the
 * default profile (addressTerm "Boss"), and the document itself first
 * appears when a settings surface writes it.
 */
import { UserProfile } from "@otto/shared";

import { COLLECTIONS, db } from "../firestore.js";
import { errorFields, logWarning } from "../log.js";

export function defaultProfile(uid: string, now: Date): UserProfile {
  return { ownerId: uid, addressTerm: "Boss", createdAt: now.toISOString() };
}

/** The owner's profile, or defaults. Never throws. */
export async function loadUserProfile(uid: string, now: Date): Promise<UserProfile> {
  try {
    const snapshot = await db().collection(COLLECTIONS.users).doc(uid).get();
    const parsed = UserProfile.safeParse(snapshot.data());
    if (parsed.success && parsed.data.ownerId === uid) {
      return parsed.data;
    }
  } catch (err) {
    logWarning("user_profile_load_failed", { userId: uid, ...errorFields(err) });
  }
  return defaultProfile(uid, now);
}

/**
 * The user chose their term of address (or chose none). Marks it
 * confirmed so the ask-once nudge never fires again.
 */
export async function setAddressTerm(uid: string, term: string): Promise<void> {
  await db()
    .collection(COLLECTIONS.users)
    .doc(uid)
    .set({ addressTerm: term, addressTermSet: true }, { merge: true });
}
