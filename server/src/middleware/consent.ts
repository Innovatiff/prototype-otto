/**
 * Third-party AI consent, enforced where it matters: no model call without
 * a stored grant. The client hides UI; THIS refuses. A 60-second cache
 * keeps the per-turn cost to one Firestore read a minute per user.
 */
import type { NextFunction, Request, Response } from "express";

import { AppError } from "../errors.js";
import { COLLECTIONS, db } from "../firestore.js";
import { requireUid } from "./auth.js";

const CACHE_TTL_MS = 60_000;
const cache = new Map<string, { hasConsent: boolean; at: number }>();

/** Grant/revoke routes call this so changes take effect immediately. */
export function invalidateConsentCache(uid: string): void {
  cache.delete(uid);
}

async function hasConsent(uid: string): Promise<boolean> {
  const cached = cache.get(uid);
  if (cached !== undefined && Date.now() - cached.at < CACHE_TTL_MS) {
    return cached.hasConsent;
  }
  const snapshot = await db().collection(COLLECTIONS.users).doc(uid).get();
  const granted = typeof snapshot.data()?.["aiConsentVersion"] === "string";
  cache.set(uid, { hasConsent: granted, at: Date.now() });
  return granted;
}

export async function requireConsent(
  req: Request,
  _res: Response,
  next: NextFunction,
): Promise<void> {
  try {
    const uid = requireUid(req);
    if (!(await hasConsent(uid))) {
      next(
        new AppError(
          403,
          "consent_required",
          "Third-party AI consent has not been granted for this account.",
        ),
      );
      return;
    }
    next();
  } catch (err) {
    next(err);
  }
}
