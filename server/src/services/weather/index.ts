/**
 * Weather entry point. Everything imports the provider from here, so the
 * Phase 5 switch to on-device WeatherKit (which removes the server round
 * trip entirely — see ios/Otto/Services/WeatherKitProvider.swift) touches
 * only this file.
 */
import type { CurrentWeather } from "@otto/shared";

import { errorFields, logWarning } from "../../log.js";
import { OpenMeteoProvider } from "./openMeteo.js";
import type { WeatherProvider } from "./provider.js";

export type { WeatherProvider } from "./provider.js";
export { deriveAdvice } from "./advice.js";

/** Default coordinates (Toronto) until a home-location SETTING exists.
 *  Location services are out of scope by product decision. */
export const DEFAULT_LAT = 43.6532;
export const DEFAULT_LON = -79.3832;

const provider: WeatherProvider = new OpenMeteoProvider();

export function weatherProvider(): WeatherProvider {
  return provider;
}

/** Conditions change slowly; conversation turns should never wait twice. */
const CACHE_TTL_MS = 10 * 60 * 1000;

let cache: { key: string; at: number; weather: CurrentWeather } | null = null;

/**
 * Current weather with a 10-minute in-memory cache (keyed on rounded
 * coordinates). Never throws — null means "no weather this turn".
 */
export async function cachedCurrentWeather(
  lat: number = DEFAULT_LAT,
  lon: number = DEFAULT_LON,
): Promise<CurrentWeather | null> {
  const key = `${lat.toFixed(1)},${lon.toFixed(1)}`;
  const now = Date.now();
  if (cache !== null && cache.key === key && now - cache.at < CACHE_TTL_MS) {
    return cache.weather;
  }
  try {
    const weather = await provider.current(lat, lon);
    cache = { key, at: now, weather };
    return weather;
  } catch (err) {
    logWarning("weather_fetch_failed", errorFields(err));
    return null;
  }
}
