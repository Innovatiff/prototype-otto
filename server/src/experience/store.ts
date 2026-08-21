/**
 * Experience persistence — the Voyages shelf. Server-authored, immutable
 * once saved; clients read their own through the API and can delete.
 * Queries are equality-only; sorting happens here.
 */
import { Experience, type ExperienceSummary } from "@otto/shared";

import { COLLECTIONS, db } from "../firestore.js";
import { logInfo } from "../log.js";

function experiencesCollection() {
  return db().collection(COLLECTIONS.experiences);
}

export function mintExperienceId(): string {
  return experiencesCollection().doc().id;
}

export async function saveExperience(experience: Experience): Promise<void> {
  await experiencesCollection().doc(experience.id).set(experience);
  logInfo("experience_saved", {
    userId: experience.ownerId,
    experienceId: experience.id,
    kind: experience.kind,
    days: experience.days.length,
    planned: experience.budget.planned,
  });
}

/** Newest first, capped — the Voyages list. */
export async function loadOwnerExperiences(uid: string): Promise<Experience[]> {
  const snapshot = await experiencesCollection().where("ownerId", "==", uid).limit(50).get();
  const experiences: Experience[] = [];
  for (const doc of snapshot.docs) {
    const parsed = Experience.safeParse(doc.data());
    if (parsed.success) {
      experiences.push(parsed.data);
    }
  }
  experiences.sort((a, b) => b.createdAt.localeCompare(a.createdAt));
  return experiences;
}

/** Ownership-checked read; null for missing and foreign alike. */
export async function loadOwnedExperience(id: string, uid: string): Promise<Experience | null> {
  const snapshot = await experiencesCollection().doc(id).get();
  const parsed = Experience.safeParse(snapshot.data());
  return parsed.success && parsed.data.ownerId === uid ? parsed.data : null;
}

export async function deleteExperienceDoc(id: string): Promise<void> {
  await experiencesCollection().doc(id).delete();
}

/** The list face of an experience — no itinerary, no chapters. */
export function summarize(experience: Experience): ExperienceSummary {
  return {
    id: experience.id,
    kind: experience.kind,
    title: experience.title,
    destination: experience.destination,
    ...(experience.vibe !== undefined ? { vibe: experience.vibe } : {}),
    dayCount: experience.days.length,
    budget: experience.budget,
    summary: experience.summary,
    createdAt: experience.createdAt,
  };
}
