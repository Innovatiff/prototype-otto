/**
 * Weather entry point. Everything imports the provider from here, so the
 * Phase 5 switch to on-device WeatherKit (which removes the server round
 * trip entirely — see ios/Otto/Services/WeatherKitProvider.swift) touches
 * only this file.
 */
import { OpenMeteoProvider } from "./openMeteo.js";
import type { WeatherProvider } from "./provider.js";

export type { WeatherProvider } from "./provider.js";
export { deriveAdvice } from "./advice.js";

const provider: WeatherProvider = new OpenMeteoProvider();

export function weatherProvider(): WeatherProvider {
  return provider;
}
