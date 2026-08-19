/**
 * FCM delivery — the transport under the deliverer.
 *
 * Tokens live on the user document (`fcmTokens`, most-recent-last, capped
 * at five devices); invalid ones are pruned on every send so a factory-
 * reset phone stops costing sends forever. The push carries REAL content —
 * the sanitized body IS the notification — plus a data payload (deepLink,
 * deliveryId) so the tap lands somewhere and the open can be reported.
 *
 * Transport is best-effort by design: the delivery record is already
 * stored, so a dead token or an FCM hiccup logs and moves on — it never
 * converts a produced delivery into a failed run.
 */
import { getMessaging, type MulticastMessage } from "firebase-admin/messaging";

import { COLLECTIONS, db } from "../firestore.js";
import { errorFields, logInfo, logWarning } from "../log.js";

/** Devices per user; oldest falls off when a sixth registers. */
export const MAX_DEVICE_TOKENS = 5;

/** The notification category the iOS client registers Snooze/Not today on. */
export const PUSH_CATEGORY = "OTTO_AUTOMATION";

/** New token list after a registration: dedupe, append, cap (most recent last). */
export function nextTokens(current: readonly string[], added: string): string[] {
  const kept = current.filter((token) => token !== added && token.length > 0);
  kept.push(added);
  return kept.slice(-MAX_DEVICE_TOKENS);
}

/** FCM error codes that mean "this token is dead — remove it". */
const DEAD_TOKEN_CODES = new Set([
  "messaging/invalid-registration-token",
  "messaging/registration-token-not-registered",
  "messaging/invalid-argument",
]);

export function isDeadTokenCode(code: string | undefined): boolean {
  return code !== undefined && DEAD_TOKEN_CODES.has(code);
}

export interface PushInput {
  readonly title: string;
  readonly body: string;
  readonly deepLink: string;
  readonly deliveryId: string;
  readonly automationId: string;
  readonly automationType: string;
}

/**
 * The multicast message, pure. Meeting prep is time-sensitive (it expires
 * with the meeting); everything else interrupts at normal priority.
 * Data values must all be strings — FCM rejects anything else.
 */
export function buildPushMessage(tokens: readonly string[], input: PushInput): MulticastMessage {
  return {
    tokens: [...tokens],
    notification: { title: input.title, body: input.body },
    data: {
      deepLink: input.deepLink,
      deliveryId: input.deliveryId,
      automationId: input.automationId,
      automationType: input.automationType,
    },
    apns: {
      payload: {
        aps: {
          category: PUSH_CATEGORY,
          sound: "default",
          "interruption-level": input.automationType === "meeting_prep" ? "time-sensitive" : "active",
          "thread-id": input.automationType,
        },
      },
    },
  };
}

function userRef(uid: string) {
  return db().collection(COLLECTIONS.users).doc(uid);
}

/** Registers (or refreshes) one device token. Read-modify-write; no lock —
 * a lost race between two of the user's own devices is harmless. */
export async function registerDeviceToken(uid: string, token: string): Promise<number> {
  const snapshot = await userRef(uid).get();
  const current = readTokens(snapshot.data());
  const updated = nextTokens(current, token);
  await userRef(uid).set({ fcmTokens: updated }, { merge: true });
  return updated.length;
}

function readTokens(data: FirebaseFirestore.DocumentData | undefined): string[] {
  const raw = data?.["fcmTokens"];
  if (!Array.isArray(raw)) {
    return [];
  }
  return raw.filter((token): token is string => typeof token === "string" && token.length > 0);
}

export async function loadDeviceTokens(uid: string): Promise<string[]> {
  const snapshot = await userRef(uid).get();
  return readTokens(snapshot.data());
}

export type PushOutcome = "sent" | "no_tokens" | "all_failed";

/**
 * Sends to every registered device and prunes the dead. Never throws.
 */
export async function sendAutomationPush(uid: string, input: PushInput): Promise<PushOutcome> {
  let tokens: string[];
  try {
    tokens = await loadDeviceTokens(uid);
  } catch (err) {
    logWarning("push_tokens_load_failed", { userId: uid, ...errorFields(err) });
    return "no_tokens";
  }
  if (tokens.length === 0) {
    logInfo("push_skipped_no_tokens", { userId: uid, automationId: input.automationId });
    return "no_tokens";
  }
  try {
    const response = await getMessaging().sendEachForMulticast(buildPushMessage(tokens, input));
    const dead: string[] = [];
    response.responses.forEach((result, index) => {
      const token = tokens[index];
      if (!result.success && token !== undefined && isDeadTokenCode(result.error?.code)) {
        dead.push(token);
      }
    });
    if (dead.length > 0) {
      const remaining = tokens.filter((token) => !dead.includes(token));
      await userRef(uid)
        .set({ fcmTokens: remaining }, { merge: true })
        .catch((err: unknown) => {
          logWarning("push_token_prune_failed", { userId: uid, ...errorFields(err) });
        });
    }
    logInfo("push_sent", {
      userId: uid,
      automationId: input.automationId,
      automationType: input.automationType,
      successes: response.successCount,
      failures: response.failureCount,
      pruned: dead.length,
    });
    return response.successCount > 0 ? "sent" : "all_failed";
  } catch (err) {
    logWarning("push_send_failed", { userId: uid, automationId: input.automationId, ...errorFields(err) });
    return "all_failed";
  }
}
