/**
 * The weather seam. Call sites depend on this interface only, so WeatherKit
 * (on-device, Phase 5) replaces the implementation — or removes the server
 * round trip entirely — with no call-site change.
 */
import type { CurrentWeather, HourlyForecast } from "@otto/shared";

export interface WeatherProvider {
  current(lat: number, lon: number): Promise<CurrentWeather>;
  hourly(lat: number, lon: number, hours: number): Promise<HourlyForecast[]>;
}
