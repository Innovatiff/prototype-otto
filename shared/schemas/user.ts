import { z } from "zod";
import { isoDateTime, zId } from "./common.js";

/**
 * The owner's profile — one document per user, doc id = uid.
 *
 * addressTerm is how Otto addresses them: "Boss" (default), "Sir", "Ma'am",
 * "Chief", a first name, or "none" for no term of address at all. Free-form
 * string rather than an enum so a first name needs no schema change; "none"
 * is the one special value.
 */
export const UserProfile = z.object({
  ownerId: zId,
  addressTerm: z.string().min(1).max(40).default("Boss"),
  /** True once the USER chose the term (or chose none) — until then the
   *  default is in effect and Otto asks, once, what to call them. */
  addressTermSet: z.boolean().optional(),

  // ── Subscription (written ONLY by the RevenueCat webhook) ─────────
  /** Authoritative tier; absent = free. The server gates on THIS. */
  subscriptionTier: z.enum(["free", "lite", "pro", "max"]).optional(),
  /** First purchase instant — the billing anniversary the plan meter uses. */
  subscriptionAnchorAt: isoDateTime.optional(),
  subscriptionExpiresAt: isoDateTime.optional(),
  /** Max only: seat emails (lowercased). Members get Pro features and
   *  share the owner's plan allowance. */
  maxSeats: z.array(z.string().min(3).max(200)).max(3).optional(),

  // ── Third-party AI consent (required before ANY model call) ───────
  aiConsentVersion: z.string().max(20).optional(),
  aiConsentAt: isoDateTime.optional(),

  // ── Meters ────────────────────────────────────────────────────────
  /** Billing-period key ("p0", "p1"…) the plan counter belongs to. */
  plansPeriodKey: z.string().max(20).optional(),
  plansCreatedThisPeriod: z.number().int().min(0).optional(),
  /** Period key when the 80% heads-up was spoken — once per period. */
  planMeterMentionedPeriod: z.string().max(20).optional(),
  /** Fair-use signal only; never surfaced, never capped. */
  turnsMonthKey: z.string().max(10).optional(),
  turnsThisMonth: z.number().int().min(0).optional(),
  createdAt: isoDateTime,
  /**
   * Plan metering (subscriptions land in Phase 7; counting starts now).
   * Successful GENERATIONS only — adaptations never count. The month key
   * is UTC "YYYY-MM"; a new month resets the counter. No limit enforced.
   */
  plansCreatedThisMonth: z.number().int().min(0).optional(),
  plansCountMonth: z.string().optional(),
  /**
   * Quiet hours, local wall clock "HH:mm". Proactive automation pushes are
   * suppressed inside the window (defaults 22:00–07:00 when absent) unless
   * the automation itself was explicitly scheduled inside it.
   */
  quietHoursStart: z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/).optional(),
  quietHoursEnd: z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/).optional(),
  /**
   * How many CUSTOM automations currently exist (enabled or not — a cap
   * you can dodge by disabling is no cap). Built-ins never count.
   * Recounted from truth on every create/delete; enforcement (Lite: 3)
   * lands in Phase 7 with subscriptions.
   */
  customAutomationCount: z.number().int().min(0).optional(),
});
export type UserProfile = z.infer<typeof UserProfile>;
