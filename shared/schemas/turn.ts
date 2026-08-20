import { z } from "zod";
import { CalendarEvent } from "./calendar.js";
import { isoDateTime, zId } from "./common.js";

/**
 * Attached when the user asks something OFF-SCRIPT mid-guided-session
 * ("how much salt?"). The model needs to know exactly what they're doing
 * right now, and to answer briefly — the runtime returns them to the step.
 * Ephemeral context for one turn; never persisted.
 */
export const GuidanceTurnContext = z.object({
  sessionTitle: z.string().min(1),
  stepTitle: z.string().min(1),
  /** The step's spoken cue, verbatim — often contains the answer's context. */
  stepCue: z.string(),
  /** Where they are: "set 2 of 3, 8 reps" / "4 minutes 10 left". */
  position: z.string().optional(),
});
export type GuidanceTurnContext = z.infer<typeof GuidanceTurnContext>;

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
  /** Present only for off-script questions during a guided session. */
  guidance: GuidanceTurnContext.optional(),
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
  /**
   * A StageVisual: the illustration to show while Otto speaks — weather,
   * calendar, reminders, plans, a build in progress, an armed automation.
   */
  "stage",
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
