/**
 * Automation persistence for the tick.
 *
 * Two invariants live here:
 *
 *   - The due query is `nextRunAt <= now` ALONE. Firestore's type
 *     bracketing keeps explicit-null nextRunAt (disabled / dormant) out of
 *     a string range match, so no composite index is needed; `enabled` is
 *     re-checked in memory and inside the claim transaction.
 *
 *   - Every write is a targeted `update()`, never a full-doc `set()`. The
 *     document carries scheduler-internal fields (`lockedUntil`, later the
 *     suppression counters) that are deliberately outside the shared
 *     Automation schema — a full-doc write of a parsed Automation would
 *     silently erase them.
 */
import { Automation, type AutomationRunResult } from "@otto/shared";
import { FieldValue } from "firebase-admin/firestore";

import { COLLECTIONS, db } from "../firestore.js";
import { logWarning } from "../log.js";

/** How long one tick owns a claimed automation before the claim expires. */
export const LOCK_MS = 2 * 60 * 1000;

function automationsCollection() {
  return db().collection(COLLECTIONS.automations);
}

export function mintAutomationId(): string {
  return automationsCollection().doc().id;
}

/**
 * Oldest-due first (the range field is Firestore's implicit sort), capped.
 * Parse failures are logged and skipped — one corrupt document must not
 * stall every other user's automations.
 */
export async function loadDueAutomations(now: Date, limit: number): Promise<Automation[]> {
  const snapshot = await automationsCollection()
    .where("nextRunAt", "<=", now.toISOString())
    .limit(limit)
    .get();
  const due: Automation[] = [];
  for (const doc of snapshot.docs) {
    const parsed = Automation.safeParse(doc.data());
    if (!parsed.success) {
      logWarning("automation_doc_corrupt", { automationId: doc.id });
      continue;
    }
    if (parsed.data.enabled) {
      due.push(parsed.data);
    }
  }
  return due;
}

/**
 * Whether raw document data is claimable at `now`, and the parsed
 * Automation if so. Pure — the transaction below applies it.
 *
 * `lockedUntil` is read off the raw data because it is scheduler-internal
 * and intentionally not part of the shared schema.
 */
export function evaluateClaim(data: unknown, now: Date): Automation | null {
  const parsed = Automation.safeParse(data);
  if (!parsed.success) {
    return null;
  }
  const automation = parsed.data;
  if (!automation.enabled) {
    return null;
  }
  const nowIso = now.toISOString();
  if (typeof automation.nextRunAt !== "string" || automation.nextRunAt > nowIso) {
    return null;
  }
  const lockedUntil = (data as Record<string, unknown>)["lockedUntil"];
  if (typeof lockedUntil === "string" && lockedUntil > nowIso) {
    return null;
  }
  return automation;
}

/**
 * Transactionally claims one due automation against a racing tick (two
 * scheduler fires, or overlapping revisions): re-check due-ness and the
 * lock under the transaction, then stamp `lockedUntil` two minutes out.
 * Null means someone else owns it (or its state changed) — skip silently.
 */
export async function claimAutomation(id: string, now: Date): Promise<Automation | null> {
  const ref = automationsCollection().doc(id);
  const lockExpiry = new Date(now.getTime() + LOCK_MS).toISOString();
  return await db().runTransaction(async (tx) => {
    const snapshot = await tx.get(ref);
    const data = snapshot.data();
    if (data === undefined) {
      return null;
    }
    const claim = evaluateClaim(data, now);
    if (claim === null) {
      return null;
    }
    tx.update(ref, { lockedUntil: lockExpiry });
    return claim;
  });
}

/** Every automation the user owns. Equality-only query; counts are small. */
export async function loadOwnerAutomations(uid: string): Promise<Automation[]> {
  const snapshot = await automationsCollection().where("ownerId", "==", uid).get();
  const automations: Automation[] = [];
  for (const doc of snapshot.docs) {
    const parsed = Automation.safeParse(doc.data());
    if (parsed.success) {
      automations.push(parsed.data);
    } else {
      logWarning("automation_doc_corrupt", { automationId: doc.id });
    }
  }
  return automations;
}

/** Applies one rearm/toggle update — targeted fields only, locks untouched. */
export async function updateAutomationScheduling(
  id: string,
  fields: { timezone?: string; nextRunAt?: string | null; enabled?: boolean },
): Promise<void> {
  await automationsCollection().doc(id).update({ ...fields });
}

/** Writes a freshly built automation document. */
export async function saveAutomation(automation: Automation): Promise<void> {
  await automationsCollection().doc(automation.id).set(automation);
}

/** Permanent removal (custom automations only; callers enforce that). */
export async function deleteAutomationDoc(id: string): Promise<void> {
  await automationsCollection().doc(id).delete();
}

export interface RunCompletion {
  readonly lastRunAt: string;
  readonly lastResult: AutomationRunResult;
  /** Null parks the automation (dormant / event-driven with no event). */
  readonly nextRunAt: string | null;
}

/** Records a finished run and releases the lock, in one targeted update. */
export async function completeAutomationRun(id: string, completion: RunCompletion): Promise<void> {
  await automationsCollection().doc(id).update({
    lastRunAt: completion.lastRunAt,
    lastResult: completion.lastResult,
    nextRunAt: completion.nextRunAt,
    lockedUntil: FieldValue.delete(),
  });
}
