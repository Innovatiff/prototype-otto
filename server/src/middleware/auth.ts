/**
 * Firebase ID-token verification for every request.
 *
 * `requireAuth` rejects with a typed 401 body when the bearer token is missing
 * or invalid, and attaches the verified uid to the request otherwise. Nothing
 * downstream ever sees an unauthenticated request.
 */
import type { NextFunction, Request, Response } from "express";

import { AppError } from "../errors.js";
import { firebaseAuth } from "../firestore.js";

declare global {
  namespace Express {
    interface Request {
      /** Firebase uid of the authenticated caller. Set by `requireAuth`. */
      uid?: string;
    }
  }
}

const BEARER_PREFIX = "bearer ";

export async function requireAuth(req: Request, _res: Response, next: NextFunction): Promise<void> {
  const header = req.header("authorization");
  if (header === undefined || !header.toLowerCase().startsWith(BEARER_PREFIX)) {
    next(new AppError(401, "unauthenticated", "Missing bearer token."));
    return;
  }
  const token = header.slice(BEARER_PREFIX.length).trim();
  if (token.length === 0) {
    next(new AppError(401, "unauthenticated", "Missing bearer token."));
    return;
  }
  try {
    const decoded = await firebaseAuth().verifyIdToken(token);
    req.uid = decoded.uid;
    next();
  } catch {
    // Never echo verification internals (or the token) back to the client.
    next(new AppError(401, "unauthenticated", "Invalid or expired token."));
  }
}

/**
 * The authenticated uid for a request that already passed `requireAuth`.
 * Throws 500 rather than ever letting an unscoped query run.
 */
export function requireUid(req: Request): string {
  const { uid } = req;
  if (uid === undefined) {
    throw new AppError(500, "internal", "Request reached a handler without an authenticated uid.");
  }
  return uid;
}
