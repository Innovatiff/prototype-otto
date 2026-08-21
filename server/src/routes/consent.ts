/**
 * Third-party AI consent: explicit grant with version + timestamp, revocable.
 * The consent middleware enforces it on every model-calling route; these
 * endpoints just record the user's choice.
 */
import { FieldValue } from "firebase-admin/firestore";
import { Router, type Request, type Response } from "express";
import { z } from "zod";

import { parseOrThrow } from "../errors.js";
import { COLLECTIONS, db } from "../firestore.js";
import { logInfo } from "../log.js";
import { invalidateConsentCache } from "../middleware/consent.js";
import { requireUid } from "../middleware/auth.js";

const ConsentGrant = z.object({
  version: z.string().min(1).max(20),
});

export const consentRouter = Router();

consentRouter.post("/", async (req: Request, res: Response): Promise<void> => {
  const uid = requireUid(req);
  const grant = parseOrThrow(ConsentGrant, req.body, "consent");
  await db()
    .collection(COLLECTIONS.users)
    .doc(uid)
    .set(
      { aiConsentVersion: grant.version, aiConsentAt: new Date().toISOString() },
      { merge: true },
    );
  invalidateConsentCache(uid);
  logInfo("ai_consent_granted", { userId: uid, version: grant.version });
  res.json({ granted: true });
});

consentRouter.delete("/", async (req: Request, res: Response): Promise<void> => {
  const uid = requireUid(req);
  await db()
    .collection(COLLECTIONS.users)
    .doc(uid)
    .set(
      { aiConsentVersion: FieldValue.delete(), aiConsentAt: FieldValue.delete() },
      { merge: true },
    );
  invalidateConsentCache(uid);
  logInfo("ai_consent_revoked", { userId: uid });
  res.json({ revoked: true });
});
