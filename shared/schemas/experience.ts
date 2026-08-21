import { z } from "zod";
import { isoDateTime, zId } from "./common.js";

/**
 * Experiences — planned occasions Otto researches, budgets, and presents:
 * a trip, a date, a day out. Built through a short spoken interview, always
 * planned UNDER the stated budget (the 85% envelope is enforced in code),
 * presented as an illustrated spoken tour, and kept in the user's Voyages.
 */
export const ExperienceKind = z.enum(["trip", "date", "outing"]);
export type ExperienceKind = z.infer<typeof ExperienceKind>;

/** What an itinerary item is — drives the illustration, never prose. */
export const ExperienceItemKind = z.enum(["stay", "food", "activity", "transport", "tip"]);
export type ExperienceItemKind = z.infer<typeof ExperienceItemKind>;

export const ExperienceItem = z.object({
  kind: ExperienceItemKind,
  /** The name — "Hotel La Compañía", "Fonda Lo Que Hay". */
  title: z.string().min(1).max(120),
  /** One short line: why it's here, what to order, when to go. */
  note: z.string().max(200).optional(),
  /** Neighborhood or area, for orientation. */
  area: z.string().max(80).optional(),
  /** Street address when known — the itinerary is an instruction sheet. */
  address: z.string().max(160).optional(),
  /** Wall-clock start, 24h "HH:mm". Required for everything but tips. */
  startTime: z.string().regex(/^\d{2}:\d{2}$/).optional(),
  /** How long it takes — drives, activities, dinner. */
  durationMin: z.number().int().min(1).max(1440).optional(),
  /** Estimated cost in whole currency units; omit for free things. */
  estCost: z.number().int().min(0).optional(),
});
export type ExperienceItem = z.infer<typeof ExperienceItem>;

export const ExperienceDay = z.object({
  /** "Day 1 — Casco Viejo" for trips; "The evening" for a date. */
  label: z.string().min(1).max(80),
  items: z.array(ExperienceItem).min(1).max(10),
});
export type ExperienceDay = z.infer<typeof ExperienceDay>;

export const ExperienceBudget = z.object({
  /** What the user said. */
  stated: z.number().int().min(1),
  /** Sum of item estimates — computed server-side, ≤ 85% of stated. */
  planned: z.number().int().min(0),
  /** stated − planned: the just-in-case margin, shown proudly. */
  buffer: z.number().int().min(0),
  /** ISO 4217, e.g. "USD". */
  currency: z.string().min(3).max(3),
});
export type ExperienceBudget = z.infer<typeof ExperienceBudget>;

/** One chapter of the spoken presentation, matched to a visual. */
export const ExperienceChapterKind = z.enum([
  "overview",
  "stay",
  "food",
  "activities",
  "transport",
  "budget",
]);
export type ExperienceChapterKind = z.infer<typeof ExperienceChapterKind>;

export const ExperienceChapter = z.object({
  kind: ExperienceChapterKind,
  /** Spoken style, 1–3 sentences — judgment, never a read-out list. */
  spoken: z.string().min(1).max(500),
});
export type ExperienceChapter = z.infer<typeof ExperienceChapter>;

export const Experience = z.object({
  id: zId,
  ownerId: zId,
  kind: ExperienceKind,
  /** Short name — "Panama, Five Days", "Anniversary Evening". */
  title: z.string().min(1).max(120),
  destination: z.string().min(1).max(120),
  /** The scene it wears — "beach", "city", "romantic", "nature", … */
  vibe: z.string().max(40).optional(),
  days: z.array(ExperienceDay).min(1).max(14),
  budget: ExperienceBudget,
  /** The spoken tour, in presentation order. */
  chapters: z.array(ExperienceChapter).min(2).max(8),
  /** One line for lists — "Five days, two people, under $1,700." */
  summary: z.string().min(1).max(200),
  createdAt: isoDateTime,
});
export type Experience = z.infer<typeof Experience>;

/** What GET /experiences lists — the card face, not the whole itinerary. */
export const ExperienceSummary = z.object({
  id: zId,
  kind: ExperienceKind,
  title: z.string(),
  destination: z.string(),
  vibe: z.string().optional(),
  dayCount: z.number().int().min(1),
  budget: ExperienceBudget,
  summary: z.string(),
  createdAt: isoDateTime,
});
export type ExperienceSummary = z.infer<typeof ExperienceSummary>;

export const ExperienceListResponse = z.object({
  experiences: z.array(ExperienceSummary),
});
export type ExperienceListResponse = z.infer<typeof ExperienceListResponse>;
