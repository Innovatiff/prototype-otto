import { z } from "zod";
import { isoDateTime, zId } from "./common.js";

/** What the user is trying to do. */
export const TaskIntent = z.enum(["reminder", "list", "capture", "message"]);
export type TaskIntent = z.infer<typeof TaskIntent>;

/**
 * When / how often a task fires. Discriminated on `type`.
 *   - none:      no scheduling (e.g. a passive list or capture)
 *   - time:      one-shot at an absolute instant
 *   - recurring: RFC-5545 RRULE plus the pre-computed next fire instant
 */
export const Trigger = z.discriminatedUnion("type", [
  z.object({ type: z.literal("none") }),
  z.object({
    type: z.literal("time"),
    at: isoDateTime,
  }),
  z.object({
    type: z.literal("recurring"),
    rrule: z.string().min(1),
    nextFire: isoDateTime,
  }),
]);
export type Trigger = z.infer<typeof Trigger>;

/**
 * How strongly Otto must confirm before an action takes effect.
 *   - none:          reads and queries
 *   - inline:        reversible writes — show a confirmation card
 *   - voice_confirm: costly actions — read back and require a spoken "yes"
 *   - system_sheet:  messages — hand off to the OS compose sheet
 */
export const Verification = z.enum([
  "none",
  "inline",
  "voice_confirm",
  "system_sheet",
]);
export type Verification = z.infer<typeof Verification>;

/** Lifecycle state of a task. */
export const TaskStatus = z.enum(["active", "completed", "dismissed"]);
export type TaskStatus = z.infer<typeof TaskStatus>;

/** A single entry in a list-style task. */
export const ListItem = z.object({
  id: zId,
  text: z.string(),
  checked: z.boolean().default(false),
  /** Free-text quantity so voice input like "a dozen" or "2 lbs" survives. */
  quantity: z.string().optional(),
  addedAt: isoDateTime,
});
export type ListItem = z.infer<typeof ListItem>;

/** The core unit of work Otto manages on the user's behalf. */
export const Task = z.object({
  id: zId,
  ownerId: zId,
  intent: TaskIntent,
  title: z.string(),
  items: z.array(ListItem).default([]),
  /** e.g. "Walmart", "Home Depot", "work". */
  context: z.string().optional(),
  /** Message drafts. */
  body: z.string().optional(),
  recipient: z.string().optional(),
  trigger: Trigger,
  verification: Verification,
  status: TaskStatus,
  /** Set when a Plan generated this Task. */
  sourcePlanId: zId.optional(),
  createdAt: isoDateTime,
  completedAt: isoDateTime.optional(),
});
export type Task = z.infer<typeof Task>;
