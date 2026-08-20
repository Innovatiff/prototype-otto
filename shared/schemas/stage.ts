import { z } from "zod";
import { BriefDueTask, BriefListCount, BriefPlanSession } from "./brief.js";
import { CurrentWeather } from "./weather.js";

/**
 * A stage visual — the "speaks and shows" contract. While Otto answers, the
 * screen illustrates the topic: weather, today's calendar, reminders, plans,
 * a build-in-progress, or a freshly armed automation. Emitted as a "stage"
 * TurnEvent mid-turn; the client slides the matching illustration in.
 *
 * Payload rules: weather/reminders/plans carry their data (the server owns
 * it); calendar carries none — the device's EventKit is the truth and the
 * client renders from its own events. building/automation carry only text.
 */
export const StageVisualKind = z.enum([
  "weather",
  "calendar",
  "reminders",
  "plans",
  "building",
  "automation",
]);
export type StageVisualKind = z.infer<typeof StageVisualKind>;

export const StageVisual = z.object({
  kind: StageVisualKind,
  /** building/automation: the headline ("Building your plan", the label). */
  label: z.string().max(200).optional(),
  /** automation: the humanized schedule line. */
  detail: z.string().max(200).optional(),
  weather: CurrentWeather.optional(),
  dueTasks: z.array(BriefDueTask).max(10).optional(),
  lists: z.array(BriefListCount).max(10).optional(),
  planSessions: z.array(BriefPlanSession).max(6).optional(),
});
export type StageVisual = z.infer<typeof StageVisual>;
