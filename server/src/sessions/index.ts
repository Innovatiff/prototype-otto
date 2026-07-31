/**
 * Conversation sessions — Otto's rolling short-term memory.
 *
 * One Firestore document per session (doc id = sessionId), server-only by
 * rules. The route loads the session before the model call and appends the
 * finished exchange after it; a session that has been idle past the timeout
 * is never resumed — the turn silently starts a fresh one.
 *
 * Failure posture: memory is a quality feature, never turn-critical. A
 * Firestore hiccup degrades to an empty history / a skipped append, logged,
 * and the user's turn proceeds.
 */
import { randomUUID } from "node:crypto";

import { ConversationSession, type ConversationMessage } from "@otto/shared";

import { COLLECTIONS, db } from "../firestore.js";
import { errorFields, logInfo, logWarning } from "../log.js";

/** A session is dead after this much inactivity. */
export const SESSION_IDLE_MS = 30 * 60 * 1000;

/** History cap, in user/assistant pairs; oldest pairs fall off first. */
export const MAX_HISTORY_PAIRS = 20;

export interface LoadedSession {
  sessionId: string;
  /** ISO timestamp preserved across appends; set at creation. */
  startedAt: string;
  messages: ConversationMessage[];
}

/** True while the session's last turn is within the idle window. */
export function isSessionLive(lastTurnAt: string, now: Date): boolean {
  const last = Date.parse(lastTurnAt);
  return Number.isFinite(last) && now.getTime() - last < SESSION_IDLE_MS;
}

/**
 * Newest MAX_HISTORY_PAIRS pairs. Appends always come in user/assistant
 * pairs so the length stays even, but a corrupted document must not poison a
 * model call: after capping, anything before the first user message drops so
 * history always starts with "user".
 */
export function capHistory(messages: ConversationMessage[]): ConversationMessage[] {
  const capped = messages.slice(Math.max(0, messages.length - MAX_HISTORY_PAIRS * 2));
  const firstUser = capped.findIndex((message) => message.role === "user");
  return firstUser <= 0 ? capped : capped.slice(firstUser);
}

/**
 * Resumes `requestedId` when it exists, is the caller's own, and is still
 * live; otherwise mints a fresh empty session (nothing is written until the
 * first exchange is appended). Never throws.
 */
export async function loadOrCreateSession(
  userId: string,
  requestedId: string | undefined,
  now: Date,
): Promise<LoadedSession> {
  if (requestedId !== undefined) {
    try {
      const snapshot = await db().collection(COLLECTIONS.sessions).doc(requestedId).get();
      const parsed = ConversationSession.safeParse(snapshot.data());
      if (parsed.success) {
        const session = parsed.data;
        if (session.ownerId !== userId) {
          // Someone else's session id. Do not resume, do not explain.
          logWarning("session_owner_mismatch", { userId, requestedId });
        } else if (isSessionLive(session.lastTurnAt, now)) {
          return {
            sessionId: session.sessionId,
            startedAt: session.startedAt,
            messages: capHistory(session.messages),
          };
        } else {
          logInfo("session_expired", { userId, requestedId });
        }
      }
    } catch (err) {
      logWarning("session_load_failed", { userId, requestedId, ...errorFields(err) });
    }
  }
  return { sessionId: randomUUID(), startedAt: now.toISOString(), messages: [] };
}

export interface ExchangeInput {
  session: LoadedSession;
  userId: string;
  userText: string;
  assistantText: string;
  now: Date;
}

/**
 * Appends one finished user/assistant exchange and persists the whole
 * (capped) session document. Never throws.
 */
export async function appendExchange(input: ExchangeInput): Promise<void> {
  const nowIso = input.now.toISOString();
  const messages = capHistory([
    ...input.session.messages,
    { role: "user", content: input.userText, timestamp: nowIso },
    { role: "assistant", content: input.assistantText, timestamp: nowIso },
  ]);
  const document: ConversationSession = {
    sessionId: input.session.sessionId,
    ownerId: input.userId,
    startedAt: input.session.startedAt,
    lastTurnAt: nowIso,
    messages,
  };
  try {
    await db().collection(COLLECTIONS.sessions).doc(input.session.sessionId).set(document);
  } catch (err) {
    logWarning("session_append_failed", {
      userId: input.userId,
      sessionId: input.session.sessionId,
      ...errorFields(err),
    });
  }
}
