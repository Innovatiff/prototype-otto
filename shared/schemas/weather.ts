import { z } from "zod";
import { isoDateTime } from "./common.js";

/**
 * Deterministic weather guidance, derived IN CODE from the numbers — the
 * model phrases it, it never computes it:
 *   rain — precipitation probability over 50% within the next 4 hours
 *   cold — apparent temperature below 0°C
 *   wind — wind over 40 km/h
 * Several can apply at once.
 */
export const WeatherAdvice = z.enum(["rain", "cold", "wind"]);
export type WeatherAdvice = z.infer<typeof WeatherAdvice>;

/** Conditions right now, metric. */
export const CurrentWeather = z.object({
  temperatureC: z.number(),
  apparentC: z.number(),
  precipitationMm: z.number().min(0),
  /** Probability for the current hour, 0–100. */
  precipitationProbability: z.number().int().min(0).max(100),
  windKmh: z.number().min(0),
  /** WMO weather interpretation code. */
  weatherCode: z.number().int(),
  advice: z.array(WeatherAdvice),
});
export type CurrentWeather = z.infer<typeof CurrentWeather>;

/** One forecast hour, metric. */
export const HourlyForecast = z.object({
  at: isoDateTime,
  temperatureC: z.number(),
  apparentC: z.number(),
  precipitationProbability: z.number().int().min(0).max(100),
  precipitationMm: z.number().min(0),
  windKmh: z.number().min(0),
  weatherCode: z.number().int(),
});
export type HourlyForecast = z.infer<typeof HourlyForecast>;
