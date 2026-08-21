/**
 * The entitlement matrix — one module, server-authoritative.
 *
 * The client hides UI; THIS decides. Tier comes from the user document
 * (written only by the RevenueCat webhook); every gate reads it through
 * effectiveTier so Max seats resolve too. Gated tool calls return a typed
 * refusal for the model AND an `entitlement` turn event so the client can
 * render a contextual upsell — never a generic "upgrade required".
 */
import type { UserProfile } from "@otto/shared";

import { COLLECTIONS, db } from "../firestore.js";
import { errorFields, logWarning } from "../log.js";
import { loadUserProfile } from "../users/index.js";

export type SubscriptionTier = "free" | "lite" | "pro" | "max";

export type GatedFeature =
  | "experiences"
  | "custom_automations"
  | "plans"
  | "meeting_prep"
  | "weekly_review";

const TIER_RANK: Record<SubscriptionTier, number> = { free: 0, lite: 1, pro: 2, max: 3 };

/** Plans per billing period. The ONLY hard meter in the product. */
export const PLAN_ALLOWANCE: Record<SubscriptionTier, number> = {
  free: 1,
  lite: 6,
  pro: 25,
  max: 50,
};

/** Custom automations that may exist at once. */
export const CUSTOM_AUTOMATION_ALLOWANCE: Record<SubscriptionTier, number> = {
  free: 1,
  lite: 3,
  pro: 1000,
  max: 1000,
};

/** The tier a feature unlocks at. */
export const FEATURE_TIER: Record<GatedFeature, SubscriptionTier> = {
  experiences: "pro",
  custom_automations: "free",
  plans: "free",
  meeting_prep: "pro",
  weekly_review: "pro",
};

export function tierAllows(tier: SubscriptionTier, feature: GatedFeature): boolean {
  return TIER_RANK[tier] >= TIER_RANK[FEATURE_TIER[feature]];
}

export interface Entitled {
  /** The tier gating decisions use. */
  tier: SubscriptionTier;
  /** Whose meters apply — the seat owner's for Max members, else the uid. */
  meterUid: string;
  /** The billing anniversary the plan meter anchors to, if any. */
  anchorAt: string | null;
  hasConsent: boolean;
}

export function tierFromProfile(profile: UserProfile, now: Date): SubscriptionTier {
  const tier = profile.subscriptionTier ?? "free";
  if (tier === "free") {
    return "free";
  }
  // Belt and braces: the webhook writes expirations, but an expired stamp
  // must never keep gating open.
  if (
    profile.subscriptionExpiresAt !== undefined &&
    new Date(profile.subscriptionExpiresAt).getTime() < now.getTime()
  ) {
    return "free";
  }
  return tier;
}

/**
 * The one tier question every gate asks. Seat resolution: a user whose
 * email sits in some Max subscriber's seat list gets Pro-level features and
 * shares that owner's plan allowance.
 */
export async function effectiveTier(
  uid: string,
  email: string | null,
  now: Date,
): Promise<Entitled> {
  const profile = await loadUserProfile(uid, now);
  return await resolveEntitled(profile, uid, email, now);
}

/** Same resolution for callers that already hold the profile (converse). */
export async function resolveEntitled(
  profile: UserProfile,
  uid: string,
  email: string | null,
  now: Date,
): Promise<Entitled> {
  const own = tierFromProfile(profile, now);
  const hasConsent = profile.aiConsentVersion !== undefined;
  if (own !== "free" || email === null) {
    return {
      tier: own,
      meterUid: uid,
      anchorAt: profile.subscriptionAnchorAt ?? null,
      hasConsent,
    };
  }
  try {
    const snapshot = await db()
      .collection(COLLECTIONS.users)
      .where("maxSeats", "array-contains", email.toLowerCase())
      .limit(1)
      .get();
    const ownerDoc = snapshot.docs[0];
    if (ownerDoc !== undefined) {
      const owner = ownerDoc.data() as {
        subscriptionTier?: string;
        subscriptionAnchorAt?: string;
        subscriptionExpiresAt?: string;
      };
      const active =
        owner.subscriptionTier === "max" &&
        (owner.subscriptionExpiresAt === undefined ||
          new Date(owner.subscriptionExpiresAt).getTime() >= now.getTime());
      if (active) {
        // Seat members ride at Pro; the plan meter is the OWNER's.
        return {
          tier: "pro",
          meterUid: ownerDoc.id,
          anchorAt: owner.subscriptionAnchorAt ?? null,
          hasConsent,
        };
      }
    }
  } catch (err) {
    logWarning("seat_lookup_failed", { userId: uid, ...errorFields(err) });
  }
  return { tier: "free", meterUid: uid, anchorAt: null, hasConsent };
}

/**
 * Billing-anniversary period key. With an anchor, periods run anniversary
 * to anniversary (day-of-month clamped to 28 so the 31st can't skip
 * February); without one (free users), calendar months.
 */
export function billingPeriodKey(anchorIso: string | null, now: Date): string {
  if (anchorIso === null) {
    return `m${now.toISOString().slice(0, 7)}`;
  }
  const anchor = new Date(anchorIso);
  const anchorDay = Math.min(anchor.getUTCDate(), 28);
  let months =
    (now.getUTCFullYear() - anchor.getUTCFullYear()) * 12 +
    (now.getUTCMonth() - anchor.getUTCMonth());
  if (now.getUTCDate() < anchorDay) {
    months -= 1;
  }
  return `p${Math.max(0, months)}`;
}

/** The upsell line when the plan cap lands — both numbers, by name. */
export function planCapLine(tier: SubscriptionTier, allowance: number): string {
  const next: Record<SubscriptionTier, string | null> = {
    free: `Lite gives you ${PLAN_ALLOWANCE.lite} a month.`,
    lite: `Pro gives you ${PLAN_ALLOWANCE.pro}.`,
    pro: `Max gives you ${PLAN_ALLOWANCE.max}.`,
    max: null,
  };
  const upsell = next[tier];
  return (
    `You're at ${allowance} plan${allowance === 1 ? "" : "s"} for the month.` +
    (upsell !== null ? ` ${upsell}` : " That's the ceiling — it resets on your billing date.")
  );
}
