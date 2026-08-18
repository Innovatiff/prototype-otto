/**
 * Open-Meteo implementation — no key, no account, free. Metric throughout
 * (Open-Meteo's defaults: °C, km/h, mm). Times are requested as unixtime so
 * no timezone-less strings ever need parsing.
 *
 * The fetch is thin; all shaping lives in exported pure functions so the
 * mapping (and the advice window) is testable without the network.
 */
import { CurrentWeather, HourlyForecast } from "@otto/shared";
import { z } from "zod";

import { deriveAdvice } from "./advice.js";
import type { WeatherProvider } from "./provider.js";

const BASE_URL = "https://api.open-meteo.com/v1/forecast";
const TIMEOUT_MS = 5000;

const HOURLY_FIELDS = [
  "temperature_2m",
  "apparent_temperature",
  "precipitation_probability",
  "precipitation",
  "weather_code",
  "wind_speed_10m",
] as const;

const CURRENT_FIELDS = [
  "temperature_2m",
  "apparent_temperature",
  "precipitation",
  "weather_code",
  "wind_speed_10m",
] as const;

export const OpenMeteoResponse = z.object({
  current: z.object({
    time: z.number(),
    temperature_2m: z.number(),
    apparent_temperature: z.number(),
    precipitation: z.number(),
    weather_code: z.number(),
    wind_speed_10m: z.number(),
  }),
  hourly: z.object({
    time: z.array(z.number()),
    temperature_2m: z.array(z.number().nullable()),
    apparent_temperature: z.array(z.number().nullable()),
    precipitation_probability: z.array(z.number().nullable()),
    precipitation: z.array(z.number().nullable()),
    weather_code: z.array(z.number().nullable()),
    wind_speed_10m: z.array(z.number().nullable()),
  }),
});
export type OpenMeteoResponse = z.infer<typeof OpenMeteoResponse>;

/** Hours at or after `fromEpochSeconds`, up to `hours` of them. */
export function mapHourly(
  response: OpenMeteoResponse,
  fromEpochSeconds: number,
  hours: number,
): HourlyForecast[] {
  const out: HourlyForecast[] = [];
  const h = response.hourly;
  for (const [index, time] of h.time.entries()) {
    if (out.length >= hours) {
      break;
    }
    if (time < fromEpochSeconds) {
      continue;
    }
    const entry = {
      at: new Date(time * 1000).toISOString(),
      temperatureC: h.temperature_2m[index] ?? 0,
      apparentC: h.apparent_temperature[index] ?? 0,
      precipitationProbability: Math.round(h.precipitation_probability[index] ?? 0),
      precipitationMm: h.precipitation[index] ?? 0,
      windKmh: h.wind_speed_10m[index] ?? 0,
      weatherCode: h.weather_code[index] ?? 0,
    };
    out.push(HourlyForecast.parse(entry));
  }
  return out;
}

/** The current block plus code-derived advice from the next 4 hours. */
export function mapCurrent(response: OpenMeteoResponse): CurrentWeather {
  const next4h = mapHourly(response, response.current.time, 4);
  const maxProbability = next4h.reduce(
    (max, hour) => Math.max(max, hour.precipitationProbability),
    0,
  );
  const current = response.current;
  return CurrentWeather.parse({
    temperatureC: current.temperature_2m,
    apparentC: current.apparent_temperature,
    precipitationMm: current.precipitation,
    precipitationProbability: next4h[0]?.precipitationProbability ?? 0,
    windKmh: current.wind_speed_10m,
    weatherCode: current.weather_code,
    advice: deriveAdvice({
      apparentC: current.apparent_temperature,
      windKmh: current.wind_speed_10m,
      maxPrecipProbabilityNext4h: maxProbability,
    }),
  });
}

export class OpenMeteoProvider implements WeatherProvider {
  async current(lat: number, lon: number): Promise<CurrentWeather> {
    return mapCurrent(await this.fetchForecast(lat, lon));
  }

  async hourly(lat: number, lon: number, hours: number): Promise<HourlyForecast[]> {
    const response = await this.fetchForecast(lat, lon);
    return mapHourly(response, response.current.time, hours);
  }

  private async fetchForecast(lat: number, lon: number): Promise<OpenMeteoResponse> {
    const url = new URL(BASE_URL);
    url.searchParams.set("latitude", String(lat));
    url.searchParams.set("longitude", String(lon));
    url.searchParams.set("current", CURRENT_FIELDS.join(","));
    url.searchParams.set("hourly", HOURLY_FIELDS.join(","));
    url.searchParams.set("forecast_days", "2");
    url.searchParams.set("timeformat", "unixtime");
    const response = await fetch(url, { signal: AbortSignal.timeout(TIMEOUT_MS) });
    if (!response.ok) {
      throw new Error(`Open-Meteo failed: ${response.status}`);
    }
    return OpenMeteoResponse.parse(await response.json());
  }
}
