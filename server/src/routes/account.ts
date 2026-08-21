/**
 * DELETE /account — the one-way door. Verifies the caller's token, erases
 * every document Otto holds for them, then deletes the auth user. The
 * client signs out locally when this returns.
 */
import { Router, type Request, type Response } from "express";
import { z } from "zod";

import { deleteAccount } from "../account/delete.js";
import { effectiveTier } from "../entitlements/index.js";
import { AppError, parseOrThrow } from "../errors.js";
import { COLLECTIONS, db } from "../firestore.js";
import { requireUid } from "../middleware/auth.js";
import { setAddressTerm } from "../users/index.js";

export const accountRouter = Router();

accountRouter.delete("/", async (req: Request, res: Response): Promise<void> => {
  const uid = requireUid(req);
  await deleteAccount(uid);
  res.json({ deleted: true });
});

const AddressTermBody = z.object({ term: z.string().min(1).max(40) });

/** Onboarding's "what should I call you?" answer, spoken then saved. */
accountRouter.post("/address-term", async (req: Request, res: Response): Promise<void> => {
  const uid = requireUid(req);
  const body = parseOrThrow(AddressTermBody, req.body, "address term");
  const term = body.term.trim();
  await setAddressTerm(uid, term.toLowerCase() === "none" ? "none" : term);
  res.json({ saved: true });
});

const SeatsBody = z.object({
  emails: z.array(z.string().email().max(200)).max(3),
});

/**
 * Max family seats: up to three emails. Members resolve to Pro features
 * and share the owner's plan allowance; removing an email releases the
 * seat immediately (resolution is read-time).
 */
accountRouter.post("/seats", async (req: Request, res: Response): Promise<void> => {
  const uid = requireUid(req);
  const body = parseOrThrow(SeatsBody, req.body, "seats");
  const entitled = await effectiveTier(uid, req.userEmail ?? null, new Date());
  if (entitled.tier !== "max") {
    throw new AppError(403, "entitlement_required", "Family seats are part of Max.", {
      feature: "seats",
      requiredTier: "max",
    });
  }
  await db()
    .collection(COLLECTIONS.users)
    .doc(uid)
    .set({ maxSeats: body.emails.map((email) => email.toLowerCase()) }, { merge: true });
  res.json({ saved: true, seats: body.emails.length });
});
