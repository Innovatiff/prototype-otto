/**
 * The RevenueCat webhook — the ONLY writer of subscription truth. Events
 * arrive with a shared secret in the Authorization header; the mapped tier
 * lands on the user document, and every gate reads from there. The client's
 * entitlement view is cosmetic; this is the authority.
 */
import { Router, type Request, type Response } from "express";
import { z } from "zod";

import { AppError } from "../errors.js";
import { COLLECTIONS, db } from "../firestore.js";
import { logInfo, logWarning } from "../log.js";

const WebhookBody = z.object({
  event: z.object({
    type: z.string(),
    app_user_id: z.string().min(1),
    entitlement_ids: z.array(z.string()).nullish(),
    purchased_at_ms: z.number().nullish(),
    expiration_at_ms: z.number().nullish(),
    period_type: z.string().nullish(),
  }),
});

export type MappedTier = "free" | "lite" | "pro" | "max";

/** Highest entitlement wins; unknown ids are ignored. */
export function tierFromEntitlements(ids: readonly string[] | null | undefined): MappedTier {
  const set = new Set((ids ?? []).map((id) => id.toLowerCase()));
  if (set.has("max")) return "max";
  if (set.has("pro")) return "pro";
  if (set.has("lite")) return "lite";
  return "free";
}

export interface WebhookOutcome {
  uid: string;
  updates: Record<string, unknown>;
  /** Events that change nothing (cancellation notice, billing issue). */
  noop: boolean;
}

/** Pure event → user-document update mapping. Exported for tests. */
export function mapWebhookEvent(body: z.infer<typeof WebhookBody>): WebhookOutcome {
  const event = body.event;
  const uid = event.app_user_id;
  const expiresAt =
    event.expiration_at_ms != null ? new Date(event.expiration_at_ms).toISOString() : null;

  switch (event.type) {
    case "INITIAL_PURCHASE":
    case "RENEWAL":
    case "UNCANCELLATION":
    case "PRODUCT_CHANGE":
    case "NON_RENEWING_PURCHASE": {
      const updates: Record<string, unknown> = {
        subscriptionTier: tierFromEntitlements(event.entitlement_ids),
      };
      if (expiresAt !== null) {
        updates["subscriptionExpiresAt"] = expiresAt;
      }
      // The billing anniversary anchors the plan meter — set once, at the
      // first purchase, and never moved by renewals.
      if (event.type === "INITIAL_PURCHASE" && event.purchased_at_ms != null) {
        updates["subscriptionAnchorAt"] = new Date(event.purchased_at_ms).toISOString();
      }
      return { uid, updates, noop: false };
    }
    case "EXPIRATION":
      // Lapsed: features lock, nothing is deleted.
      return { uid, updates: { subscriptionTier: "free" }, noop: false };
    case "CANCELLATION":
    case "BILLING_ISSUE":
    case "SUBSCRIPTION_PAUSED":
      // Still entitled until expiration; Apple handles recovery flows.
      return { uid, updates: {}, noop: true };
    default:
      return { uid, updates: {}, noop: true };
  }
}

export const revenuecatRouter = Router();

revenuecatRouter.post("/webhook", async (req: Request, res: Response): Promise<void> => {
  const secret = process.env["REVENUECAT_WEBHOOK_SECRET"];
  if (secret === undefined || secret.length === 0) {
    // Fail closed: an unconfigured webhook must not accept writes.
    throw new AppError(503, "internal", "Webhook not configured.");
  }
  const header = req.header("authorization") ?? "";
  if (header !== secret && header !== `Bearer ${secret}`) {
    throw new AppError(401, "unauthenticated", "Bad webhook credentials.");
  }
  const parsed = WebhookBody.safeParse(req.body);
  if (!parsed.success) {
    // Acknowledge unknown shapes so RevenueCat doesn't retry forever, but
    // record that something unexpected arrived.
    logWarning("revenuecat_unparsed_event", {});
    res.json({ ok: true });
    return;
  }
  const outcome = mapWebhookEvent(parsed.data);
  if (!outcome.noop) {
    await db().collection(COLLECTIONS.users).doc(outcome.uid).set(outcome.updates, { merge: true });
  }
  logInfo("revenuecat_event", {
    userId: outcome.uid,
    type: parsed.data.event.type,
    noop: outcome.noop,
    tier: (outcome.updates["subscriptionTier"] as string | undefined) ?? null,
  });
  res.json({ ok: true });
});
