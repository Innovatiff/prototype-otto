/**
 * DELETE /account — the one-way door. Verifies the caller's token, erases
 * every document Otto holds for them, then deletes the auth user. The
 * client signs out locally when this returns.
 */
import { Router, type Request, type Response } from "express";

import { deleteAccount } from "../account/delete.js";
import { requireUid } from "../middleware/auth.js";

export const accountRouter = Router();

accountRouter.delete("/", async (req: Request, res: Response): Promise<void> => {
  const uid = requireUid(req);
  await deleteAccount(uid);
  res.json({ deleted: true });
});
