/**
 * Plan persistence. Plans are IMMUTABLE: nothing here updates a plan's
 * content, ever — a change writes a NEW document (version + supersedes) and
 * flips the old one's status. At most one active plan per domain, enforced
 * transactionally. Clients get read-only access via rules; every write goes
 * through this module on the server.
 */
import { Plan, SessionRecord } from "@otto/shared";

import { COLLECTIONS, db } from "../firestore.js";
import { logInfo } from "../log.js";

function plansCollection() {
  return db().collection(COLLECTIONS.plans);
}

/** Mints a plans doc id (generate.ts stamps it before validation). */
export function mintPlanId(): string {
  return plansCollection().doc().id;
}

/**
 * Writes a plan and supersedes any other active plan in its domain — one
 * transaction, so two racing generations can't both stay active.
 */
export async function saveNewPlan(plan: Plan): Promise<void> {
  await db().runTransaction(async (tx) => {
    const active = await tx.get(
      plansCollection()
        .where("ownerId", "==", plan.ownerId)
        .where("meta.domain", "==", plan.meta.domain)
        .where("status", "==", "active"),
    );
    for (const doc of active.docs) {
      if (doc.id !== plan.id) {
        tx.update(doc.ref, { status: "superseded" });
      }
    }
    tx.set(plansCollection().doc(plan.id), plan);
  });
  logInfo("plan_saved", {
    userId: plan.ownerId,
    planId: plan.id,
    domain: plan.meta.domain,
    version: plan.meta.version,
    supersedes: plan.supersedes ?? null,
  });
}

/** The single active plan for a domain, or null. */
export async function loadActivePlan(uid: string, domain: string): Promise<Plan | null> {
  const snapshot = await plansCollection()
    .where("ownerId", "==", uid)
    .where("meta.domain", "==", domain)
    .where("status", "==", "active")
    .get();
  const plans = parseAll(snapshot.docs);
  // The transaction keeps this at one; if data ever disagrees, newest wins.
  return plans.sort((a, b) => b.createdAt.localeCompare(a.createdAt))[0] ?? null;
}

/** Every active plan, all domains — the dynamic prompt's ACTIVE PLANS block. */
export async function loadActivePlans(uid: string): Promise<Plan[]> {
  const snapshot = await plansCollection()
    .where("ownerId", "==", uid)
    .where("status", "==", "active")
    .get();
  return parseAll(snapshot.docs);
}

function parseAll(docs: FirebaseFirestore.QueryDocumentSnapshot[]): Plan[] {
  const plans: Plan[] = [];
  for (const doc of docs) {
    const parsed = Plan.safeParse(doc.data());
    if (parsed.success) {
      plans.push(parsed.data);
    }
  }
  return plans;
}

// ── Session records (the adaptation loop's raw material) ────────────

export async function saveSessionRecord(record: SessionRecord): Promise<void> {
  await db().collection(COLLECTIONS.sessionRecords).doc(record.id).set(record);
  logInfo("session_record_saved", {
    userId: record.ownerId,
    planId: record.planId,
    sessionId: record.sessionId,
    durationSec: record.durationSec,
    endedEarly: record.endedEarly,
  });
}

/** Newest first. Equality-only query; sorted here (per-plan counts are small). */
export async function loadSessionRecords(
  uid: string,
  planId: string,
  limit = 50,
): Promise<SessionRecord[]> {
  const snapshot = await db()
    .collection(COLLECTIONS.sessionRecords)
    .where("ownerId", "==", uid)
    .where("planId", "==", planId)
    .limit(500)
    .get();
  const records: SessionRecord[] = [];
  for (const doc of snapshot.docs) {
    const parsed = SessionRecord.safeParse(doc.data());
    if (parsed.success) {
      records.push(parsed.data);
    }
  }
  records.sort((a, b) => b.completedAt.localeCompare(a.completedAt));
  return records.slice(0, limit);
}

// ── Metering (count only; enforcement is Phase 7's) ─────────────────

/** UTC month key, e.g. "2026-08". Metering months roll over in UTC. */
export function meterMonthKey(now: Date): string {
  return now.toISOString().slice(0, 7);
}

/**
 * The counter's next value: same month increments, a new month (or absent /
 * corrupt data) restarts at 1. Pure; the transaction below applies it.
 */
export function nextMeterValue(
  stored: { month?: unknown; count?: unknown },
  month: string,
): number {
  if (stored.month !== month) {
    return 1;
  }
  const count = typeof stored.count === "number" && Number.isFinite(stored.count)
    ? Math.max(0, Math.floor(stored.count))
    : 0;
  return count + 1;
}

/**
 * Counts one successful plan GENERATION on the user document. Adaptations
 * never call this; neither does anything else. Returns the new count.
 */
export async function recordPlanCreation(uid: string, now: Date): Promise<number> {
  const month = meterMonthKey(now);
  const ref = db().collection(COLLECTIONS.users).doc(uid);
  return await db().runTransaction(async (tx) => {
    const snapshot = await tx.get(ref);
    const data = snapshot.data() ?? {};
    const count = nextMeterValue(
      { month: data["plansCountMonth"], count: data["plansCreatedThisMonth"] },
      month,
    );
    tx.set(ref, { plansCreatedThisMonth: count, plansCountMonth: month }, { merge: true });
    return count;
  });
}

/** 1-indexed week the user is in, clamped to the plan's span. */
export function planWeek(plan: Plan, now: Date): number {
  const elapsedDays = Math.floor(
    (now.getTime() - new Date(plan.createdAt).getTime()) / 86_400_000,
  );
  const week = Math.floor(Math.max(0, elapsedDays) / 7) + 1;
  return Math.min(week, Math.max(1, Math.ceil(plan.meta.horizonDays / 7)));
}
