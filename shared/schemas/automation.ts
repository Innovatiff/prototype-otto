import { z } from "zod";
import { isoDateTime, zId } from "./common.js";

/*
 * Automations — recurring workflows that run without the app being opened.
 *
 * Phase 6 consumes these. The shapes are defined before any behavior exists
 * so the Swift models generate once and never churn as the scheduler,
 * handlers, and management UI land.
 *
 * Server-internal scheduling state (the tick's `lockedUntil` claim, ignore
 * counters for suppression) deliberately does NOT appear here: it never
 * crosses to the device, and keeping it out of the shared contract means the
 * server must update those fields with targeted `update()` calls — a full-doc
 * write of a parsed Automation would erase them.
 */

/**
 * Built-in automations are typed so their handlers, default schedules, and
 * settings UI are code, not configuration. Everything the user invents by
 * voice is "custom".
 */
export const AutomationType = z.enum([
  "morning_brief",
  "evening_shutdown",
  "weekly_review",
  "meeting_prep",
  "plan_checkin",
  "custom",
]);
export type AutomationType = z.infer<typeof AutomationType>;

/**
 * Narrows which calendar events a relative schedule fires for. An empty
 * filter matches every event; meeting_prep ships with
 * `{ minAttendees: 2 }` so solo blocks never trigger prep.
 */
export const AutomationEventFilter = z.object({
  minAttendees: z.number().int().min(1).optional(),
  /** Case-insensitive title match; any hit qualifies. */
  keywords: z.array(z.string().min(1)).max(10).optional(),
});
export type AutomationEventFilter = z.infer<typeof AutomationEventFilter>;

/** Local wall-clock "HH:mm", zero-padded, 24-hour. */
const timeOfDay = z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/);

/**
 * When an automation fires.
 *
 *   - fixed: an RRULE (e.g. "FREQ=WEEKLY;BYDAY=FR") plus a local wall-clock
 *     time, both interpreted in the automation's timezone. The next fire
 *     instant is recomputed from these on EVERY run — never stored as a UTC
 *     offset — so DST transitions cannot drift it.
 *   - relative_to_event: N minutes before any synced calendar event the
 *     filter matches.
 *
 * Variant fields are all REQUIRED (send `eventFilter: {}` to match
 * everything): the generated Swift union decodes each payload with a plain
 * `decode`, so an absent key inside a variant would throw at runtime.
 */
export const AutomationSchedule = z.discriminatedUnion("kind", [
  z.object({
    kind: z.literal("fixed"),
    rrule: z.string().min(1),
    timeOfDay,
  }),
  z.object({
    kind: z.literal("relative_to_event"),
    minutesBefore: z.number().int().min(1).max(1440),
    eventFilter: AutomationEventFilter,
  }),
]);
export type AutomationSchedule = z.infer<typeof AutomationSchedule>;

/**
 * What an automation does when it fires. `kind` selects a server-side
 * handler; built-ins mirror their AutomationType, custom automations carry
 * the parsed intent ("send a text", a composite prompt) in params.
 */
export const AutomationAction = z.object({
  kind: z.string().min(1),
  params: z.record(z.string(), z.unknown()).default({}),
});
export type AutomationAction = z.infer<typeof AutomationAction>;

/**
 * How the last firing ended. "suppressed" is a SUCCESS state — the engine
 * ran, found nothing worth saying, and correctly said nothing.
 */
export const AutomationRunResult = z.enum(["delivered", "suppressed", "failed"]);
export type AutomationRunResult = z.infer<typeof AutomationRunResult>;

/**
 * A recurring workflow Otto runs on its own schedule.
 *
 * The three run-state fields are `.nullable().optional()` — a deliberate
 * exception to the omit-only rule the rest of the wire contract keeps:
 * Firestore stores them as explicit nulls until the first run, and the
 * generated Swift decodes explicit null and absent key identically (nil).
 */
/** Registers this device for automation pushes. */
export const DeviceTokenRequest = z.object({
  /** The FCM registration token. */
  token: z.string().min(1).max(512),
});
export type DeviceTokenRequest = z.infer<typeof DeviceTokenRequest>;

/**
 * How the user answered a delivered push. "opened" is the tap-through
 * (meeting-prep engagement reads it); "snoozed" re-fires the automation in
 * 30 minutes; "dismissed" is the explicit "Not today".
 */
export const DeliveryAction = z.enum(["opened", "snoozed", "dismissed"]);
export type DeliveryAction = z.infer<typeof DeliveryAction>;

export const DeliveryResponseRequest = z.object({
  deliveryId: zId,
  action: DeliveryAction,
});
export type DeliveryResponseRequest = z.infer<typeof DeliveryResponseRequest>;

export const Automation = z.object({
  id: zId,
  ownerId: zId,
  type: AutomationType,
  /** Shown in the management list; e.g. "Morning brief", "Text Rachel". */
  label: z.string().min(1).max(120),
  enabled: z.boolean(),
  schedule: AutomationSchedule,
  /** IANA zone name (e.g. "America/New_York"), validated server-side. */
  timezone: z.string().min(1),
  action: AutomationAction,
  lastRunAt: isoDateTime.nullable().optional(),
  /** Precomputed next fire instant; null while disabled. */
  nextRunAt: isoDateTime.nullable().optional(),
  lastResult: AutomationRunResult.nullable().optional(),
  createdAt: isoDateTime,
});
export type Automation = z.infer<typeof Automation>;
