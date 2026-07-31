import { z } from "zod";
import { isoDateTime, zId } from "./common.js";

/** Who said a line in a conversation. */
export const ConversationRole = z.enum(["user", "assistant"]);
export type ConversationRole = z.infer<typeof ConversationRole>;

/** One line of a conversation, as stored on the session document. */
export const ConversationMessage = z.object({
  role: ConversationRole,
  content: z.string().min(1),
  timestamp: isoDateTime,
});
export type ConversationMessage = z.infer<typeof ConversationMessage>;

/**
 * A conversation session — Otto's rolling short-term memory for /converse.
 * (Named ConversationSession because plan.ts already claims `Session` for
 * workout sessions.)
 *
 * One Firestore document per session, doc id = sessionId, server-only:
 * firestore.rules deny all client access, same as the telemetry collections.
 * A session goes stale 30 minutes after its last turn; the server then starts
 * a fresh one rather than resuming. History is capped to the newest 20
 * user/assistant pairs — summarization of older turns comes later.
 */
export const ConversationSession = z.object({
  sessionId: zId,
  ownerId: zId,
  startedAt: isoDateTime,
  lastTurnAt: isoDateTime,
  messages: z.array(ConversationMessage),
});
export type ConversationSession = z.infer<typeof ConversationSession>;
