import { z } from "zod";
import { CalendarEvent } from "./calendar.js";
import { isoDateTime, zId } from "./common.js";

/** A single user utterance sent to /converse. */
export const TurnRequest = z.object({
  turnId: zId,
  text: z.string().min(1),
  clientTimestamp: isoDateTime,
  /** IANA timezone identifier, e.g. "America/Toronto". */
  timezone: z.string().min(1),
  /**
   * The conversation to continue. When absent, unknown, expired, or owned by
   * someone else, the server starts a fresh session and returns the effective
   * id in the `done` event data — clients adopt whatever comes back.
   */
  sessionId: zId.optional(),
  /**
   * Today's and tomorrow's calendar events, attached by the client ONLY when
   * calendar permission already exists (context never prompts). The server
   * compresses them into the dynamic prompt so schedule questions need no
   * tool call.
   */
  events: z.array(CalendarEvent).max(60).optional(),
});
export type TurnRequest = z.infer<typeof TurnRequest>;

/** The kind of event emitted on the /converse SSE stream. */
export const TurnEventType = z.enum([
  "token",
  "task_created",
  "task_updated",
  /** A message draft: { recipientName, body }. Never sent server-side. */
  "draft",
  /** A CalendarProposal: confirmed, written, and read back on-device. */
  "calendar_proposal",
  /**
   * Plan generation progress: { stage: "designing" | "scheduling" }.
   * Generation runs 30-60s — these drive the on-screen progress state
   * (never a spinner) and keep the SSE stream warm.
   */
  "plan_progress",
  /** The full generated Plan. Renders on screen; NEVER spoken in full. */
  "plan_ready",
  /** Generation failed after its retry; the client clears progress UI. */
  "plan_failed",
  "done",
  "error",
]);
export type TurnEventType = z.infer<typeof TurnEventType>;

/**
 * One event on the streamed response.
 *
 * `data` is intentionally `unknown`: its shape depends on `type` (a token
 * string, a Task, an error body, …). Consumers narrow it per event type.
 */
export const TurnEvent = z.object({
  type: TurnEventType,
  data: z.unknown(),
});
export type TurnEvent = z.infer<typeof TurnEvent>;
