/**
 * Weather advice, derived deterministically. The model phrases these tags
 * ("take the car"), it never computes them — that keeps the brief's weather
 * line consistent and cheap.
 */
import type { WeatherAdvice } from "@otto/shared";

export interface AdviceInput {
  apparentC: number;
  windKmh: number;
  /** The maximum precipitation probability over the NEXT 4 hours, 0–100. */
  maxPrecipProbabilityNext4h: number;
}

export function deriveAdvice(input: AdviceInput): WeatherAdvice[] {
  const advice: WeatherAdvice[] = [];
  if (input.maxPrecipProbabilityNext4h > 50) {
    advice.push("rain");
  }
  if (input.apparentC < 0) {
    advice.push("cold");
  }
  if (input.windKmh > 40) {
    advice.push("wind");
  }
  return advice;
}
