/**
 * Where automation output goes.
 *
 * Handlers produce an AutomationDelivery — REAL content, never a teaser —
 * and hand it to the deliverer. Step 3's deliverer stores it in the
 * server-only `deliveries` collection (the delivery log doubles as the
 * engagement record meeting-prep suppression reads); Step 5 pushes the same
 * shape through FCM and reports opens back into it.
 *
 * This module is also the persona choke point: every body that leaves here
 * is capped at 60 words, loses its exclamation marks, and is trimmed at a
 * sentence boundary. A handler cannot ship an overrun by accident.
 */
import { COLLECTIONS, db } from "../firestore.js";
import { logInfo, logWarning } from "../log.js";

export const BODY_WORD_CAP = 60;

export interface AutomationDelivery {
  readonly title: string;
  /** The message itself — useful without opening the app. */
  readonly body: string;
  /** Where a tap lands, e.g. "otto://brief". */
  readonly deepLink: string;
  /** "silent" updates state without a visible notification (Step 5). */
  readonly channel: "push" | "silent";
  /** Meeting-prep only: the normalized meeting title, for engagement. */
  readonly titleKey?: string;
}

export interface DeliveryRecord {
  readonly id: string;
  readonly ownerId: string;
  readonly automationId: string;
  readonly automationType: string;
  readonly title: string;
  readonly body: string;
  readonly deepLink: string;
  readonly channel: "push" | "silent";
  readonly titleKey: string | null;
  /** Stamped by the open report (Step 5); null = never opened. */
  readonly openedAt: string | null;
  readonly createdAt: string;
}

export type Deliverer = (
  uid: string,
  automation: { id: string; type: string },
  delivery: AutomationDelivery,
) => Promise<void>;

/** No exclamation marks, ≤60 words, trimmed at a sentence boundary. */
export function sanitizeBody(text: string, cap = BODY_WORD_CAP): string {
  const calm = text.replace(/!+/g, ".").replace(/\.{2,}/g, ".").trim();
  const words = calm.split(/\s+/).filter((word) => word.length > 0);
  if (words.length <= cap) {
    return calm;
  }
  // Keep whole sentences while they fit; fall back to a hard cut.
  const sentences = calm.match(/[^.?]+[.?]?/g) ?? [calm];
  let kept = "";
  let count = 0;
  for (const sentence of sentences) {
    const sentenceWords = sentence.trim().split(/\s+/).filter((word) => word.length > 0).length;
    if (count + sentenceWords > cap) {
      break;
    }
    kept += sentence;
    count += sentenceWords;
  }
  const result = kept.trim();
  if (result.length > 0) {
    return result;
  }
  return `${words.slice(0, cap).join(" ")}.`;
}

/**
 * A meeting title reduced to its identity — "Weekly Sync (Q3)" and
 * "weekly sync Q3" count as the same recurring meeting.
 */
export function titleKey(title: string): string {
  return title
    .toLowerCase()
    .replace(/[^a-z0-9\s]/g, "")
    .trim()
    .replace(/\s+/g, "_")
    .slice(0, 60);
}

/**
 * The ignored-recurring-meeting rule: three preps sent for this title, not
 * one opened — stop prepping it. (Opens arrive with Step 5's deep-link
 * report; until then a fourth prep for an untouched title stays silent,
 * which errs on the quiet side — the side Otto errs on.)
 */
export function shouldSuppressIgnoredTitle(
  deliveries: readonly DeliveryRecord[],
  key: string,
): boolean {
  const sent = deliveries.filter((delivery) => delivery.titleKey === key);
  if (sent.length < 3) {
    return false;
  }
  return !sent.some((delivery) => delivery.openedAt !== null);
}

function deliveriesCollection() {
  return db().collection(COLLECTIONS.deliveries);
}

/** Newest first. Equality-only query; sorted and capped in memory. */
export async function loadRecentDeliveries(
  uid: string,
  automationId: string,
  limit = 40,
): Promise<DeliveryRecord[]> {
  const snapshot = await deliveriesCollection()
    .where("ownerId", "==", uid)
    .where("automationId", "==", automationId)
    .limit(200)
    .get();
  const records: DeliveryRecord[] = [];
  for (const doc of snapshot.docs) {
    const data = doc.data() as Partial<DeliveryRecord>;
    if (typeof data.body === "string" && typeof data.createdAt === "string") {
      records.push(data as DeliveryRecord);
    } else {
      logWarning("delivery_doc_corrupt", { deliveryId: doc.id });
    }
  }
  records.sort((a, b) => b.createdAt.localeCompare(a.createdAt));
  return records.slice(0, limit);
}

/**
 * The Step 3 deliverer: sanitize, store, log. Step 5 layers FCM on top of
 * the same record.
 */
export const storeDeliverer: Deliverer = async (uid, automation, delivery) => {
  const ref = deliveriesCollection().doc();
  const record: DeliveryRecord = {
    id: ref.id,
    ownerId: uid,
    automationId: automation.id,
    automationType: automation.type,
    title: delivery.title,
    body: sanitizeBody(delivery.body),
    deepLink: delivery.deepLink,
    channel: delivery.channel,
    titleKey: delivery.titleKey ?? null,
    openedAt: null,
    createdAt: new Date().toISOString(),
  };
  await ref.set(record);
  logInfo("automation_delivered", {
    userId: uid,
    automationId: automation.id,
    automationType: automation.type,
    channel: record.channel,
    bodyChars: record.body.length,
  });
};
