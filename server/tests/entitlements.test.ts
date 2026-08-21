import { strict as assert } from "node:assert";
import { test } from "node:test";

import {
  billingPeriodKey,
  CUSTOM_AUTOMATION_ALLOWANCE,
  PLAN_ALLOWANCE,
  planCapLine,
  tierAllows,
  tierFromProfile,
} from "../src/entitlements/index.js";
import { mapWebhookEvent, tierFromEntitlements } from "../src/routes/revenuecat.js";

// ── The matrix ──────────────────────────────────────────────────────

test("experiences unlock at Pro; the ladder is ordered", () => {
  assert.equal(tierAllows("free", "experiences"), false);
  assert.equal(tierAllows("lite", "experiences"), false);
  assert.equal(tierAllows("pro", "experiences"), true);
  assert.equal(tierAllows("max", "experiences"), true);
  assert.equal(tierAllows("lite", "meeting_prep"), false);
  assert.equal(tierAllows("pro", "weekly_review"), true);
  // The numbers from the pricing model, pinned.
  assert.deepEqual(PLAN_ALLOWANCE, { free: 1, lite: 6, pro: 25, max: 50 });
  assert.equal(CUSTOM_AUTOMATION_ALLOWANCE.lite, 3);
});

test("an expired subscription stamp gates as free", () => {
  const now = new Date("2026-08-21T12:00:00.000Z");
  const base = { ownerId: "u1", addressTerm: "Boss", createdAt: "2026-01-01T00:00:00.000Z" };
  assert.equal(tierFromProfile({ ...base }, now), "free");
  assert.equal(
    tierFromProfile(
      { ...base, subscriptionTier: "pro", subscriptionExpiresAt: "2026-09-01T00:00:00.000Z" },
      now,
    ),
    "pro",
  );
  assert.equal(
    tierFromProfile(
      { ...base, subscriptionTier: "pro", subscriptionExpiresAt: "2026-08-01T00:00:00.000Z" },
      now,
    ),
    "free",
  );
});

// ── The billing-anniversary meter ───────────────────────────────────

test("periods run anniversary to anniversary, day clamped to 28", () => {
  const anchor = "2026-01-31T10:00:00.000Z"; // clamps to the 28th
  assert.equal(billingPeriodKey(anchor, new Date("2026-02-10T00:00:00.000Z")), "p0");
  assert.equal(billingPeriodKey(anchor, new Date("2026-02-28T00:00:00.000Z")), "p1");
  assert.equal(billingPeriodKey(anchor, new Date("2026-03-27T00:00:00.000Z")), "p1");
  assert.equal(billingPeriodKey(anchor, new Date("2026-03-28T00:00:00.000Z")), "p2");
  // No anchor (free): calendar months.
  assert.equal(billingPeriodKey(null, new Date("2026-08-21T00:00:00.000Z")), "m2026-08");
});

test("the cap upsell names both numbers", () => {
  assert.equal(
    planCapLine("lite", PLAN_ALLOWANCE.lite),
    "You're at 6 plans for the month. Pro gives you 25.",
  );
  assert.ok(planCapLine("max", PLAN_ALLOWANCE.max).includes("ceiling"));
});

// ── The webhook (the only writer of subscription truth) ─────────────

test("entitlement ids map to the highest tier present", () => {
  assert.equal(tierFromEntitlements(["lite"]), "lite");
  assert.equal(tierFromEntitlements(["lite", "pro"]), "pro");
  assert.equal(tierFromEntitlements(["Max"]), "max");
  assert.equal(tierFromEntitlements([]), "free");
  assert.equal(tierFromEntitlements(null), "free");
});

test("purchases set tier and anchor; expiration frees; cancellation waits", () => {
  const initial = mapWebhookEvent({
    event: {
      type: "INITIAL_PURCHASE",
      app_user_id: "u1",
      entitlement_ids: ["pro"],
      purchased_at_ms: Date.UTC(2026, 7, 21),
      expiration_at_ms: Date.UTC(2026, 8, 21),
    },
  });
  assert.equal(initial.noop, false);
  assert.equal(initial.updates["subscriptionTier"], "pro");
  assert.equal(initial.updates["subscriptionAnchorAt"], "2026-08-21T00:00:00.000Z");

  const renewal = mapWebhookEvent({
    event: {
      type: "RENEWAL",
      app_user_id: "u1",
      entitlement_ids: ["pro"],
      purchased_at_ms: Date.UTC(2026, 8, 21),
      expiration_at_ms: Date.UTC(2026, 9, 21),
    },
  });
  // Renewals never move the billing anniversary.
  assert.equal(renewal.updates["subscriptionAnchorAt"], undefined);

  const expired = mapWebhookEvent({
    event: { type: "EXPIRATION", app_user_id: "u1", entitlement_ids: [] },
  });
  assert.equal(expired.updates["subscriptionTier"], "free");

  const cancelled = mapWebhookEvent({
    event: { type: "CANCELLATION", app_user_id: "u1", entitlement_ids: ["pro"] },
  });
  assert.equal(cancelled.noop, true);
});
