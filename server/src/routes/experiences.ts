/**
 * The Voyages shelf: list, detail, delete. Experiences are created only by
 * the create_experience tool mid-conversation; these routes just let the
 * Account tab browse and prune what Otto holds.
 */
import { Router, type Request, type Response } from "express";
import type { ExperienceListResponse } from "@otto/shared";

import { AppError, IdParam, parseOrThrow } from "../errors.js";
import { requireUid } from "../middleware/auth.js";
import {
  deleteExperienceDoc,
  loadOwnedExperience,
  loadOwnerExperiences,
  summarize,
} from "../experience/store.js";

export const experiencesRouter = Router();

experiencesRouter.get("/", async (req: Request, res: Response): Promise<void> => {
  const uid = requireUid(req);
  const experiences = await loadOwnerExperiences(uid);
  const payload: ExperienceListResponse = { experiences: experiences.map(summarize) };
  res.json(payload);
});

experiencesRouter.get("/:id", async (req: Request, res: Response): Promise<void> => {
  const uid = requireUid(req);
  const id = parseOrThrow(IdParam, req.params.id, "experience id");
  const experience = await loadOwnedExperience(id, uid);
  if (experience === null) {
    throw new AppError(404, "not_found", "Experience not found.");
  }
  res.json(experience);
});

experiencesRouter.delete("/:id", async (req: Request, res: Response): Promise<void> => {
  const uid = requireUid(req);
  const id = parseOrThrow(IdParam, req.params.id, "experience id");
  const experience = await loadOwnedExperience(id, uid);
  if (experience === null) {
    throw new AppError(404, "not_found", "Experience not found.");
  }
  await deleteExperienceDoc(experience.id);
  res.json({ deleted: true });
});
