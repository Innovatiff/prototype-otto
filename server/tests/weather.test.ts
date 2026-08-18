import { strict as assert } from "node:assert";
import { test } from "node:test";

import { deriveAdvice } from "../src/services/weather/advice.js";
import {
  mapCurrent,
  mapHourly,
  OpenMeteoResponse,
  type OpenMeteoResponse as Response,
} from "../src/services/weather/openMeteo.js";

// ── Advice boundaries (the spec's exact thresholds) ─────────────────

test("rain only above 50%, cold only below 0°C, wind only above 40km/h", () => {
  assert.deepEqual(
    deriveAdvice({ apparentC: 5, windKmh: 10, maxPrecipProbabilityNext4h: 50 }),
    [],
  );
  assert.deepEqual(
    deriveAdvice({ apparentC: 5, windKmh: 10, maxPrecipProbabilityNext4h: 51 }),
    ["rain"],
  );
  assert.deepEqual(deriveAdvice({ apparentC: 0, windKmh: 40, maxPrecipProbabilityNext4h: 0 }), []);
  assert.deepEqual(
    deriveAdvice({ apparentC: -0.5, windKmh: 10, maxPrecipProbabilityNext4h: 0 }),
    ["cold"],
  );
  assert.deepEqual(
    deriveAdvice({ apparentC: 5, windKmh: 40.5, maxPrecipProbabilityNext4h: 0 }),
    ["wind"],
  );
});

test("all three advice tags can stack", () => {
  assert.deepEqual(
    deriveAdvice({ apparentC: -8, windKmh: 55, maxPrecipProbabilityNext4h: 90 }),
    ["rain", "cold", "wind"],
  );
});

// ── Open-Meteo mapping ──────────────────────────────────────────────

const HOUR = 3600;
const T0 = 1_755_500_400; // an exact hour

function fixture(probabilities: number[]): Response {
  const count = probabilities.length;
  return OpenMeteoResponse.parse({
    current: {
      time: T0,
      temperature_2m: 9.2,
      apparent_temperature: 7.1,
      precipitation: 0.3,
      weather_code: 61,
      wind_speed_10m: 18,
    },
    hourly: {
      time: probabilities.map((_, i) => T0 + (i - 1) * HOUR), // one PAST hour first
      temperature_2m: Array.from({ length: count }, () => 9),
      apparent_temperature: Array.from({ length: count }, () => 7),
      precipitation_probability: probabilities,
      precipitation: Array.from({ length: count }, () => 0.1),
      weather_code: Array.from({ length: count }, () => 61),
      wind_speed_10m: Array.from({ length: count }, () => 18),
    },
  });
}

test("mapHourly starts at the current hour, skips the past, caps the count", () => {
  const hours = mapHourly(fixture([99, 10, 20, 30, 40, 50, 60]), T0, 4);
  assert.equal(hours.length, 4);
  // The 99% entry is in the past and must not appear.
  assert.deepEqual(
    hours.map((h) => h.precipitationProbability),
    [10, 20, 30, 40],
  );
  assert.equal(hours[0]?.at, new Date(T0 * 1000).toISOString());
});

test("mapCurrent derives advice from the next-4-hour window, not the current instant", () => {
  // Probability peaks at 80% three hours out — rain advice must fire.
  const weather = mapCurrent(fixture([0, 10, 20, 80, 10, 0]));
  assert.deepEqual(weather.advice, ["rain"]);
  assert.equal(weather.precipitationProbability, 10);
  assert.equal(weather.temperatureC, 9.2);
  assert.equal(weather.windKmh, 18);
});

test("nullable forecast gaps map to zeros instead of failing", () => {
  const raw = fixture([10, 10]);
  raw.hourly.precipitation_probability[1] = null;
  raw.hourly.temperature_2m[1] = null;
  const hours = mapHourly(raw, T0, 4);
  assert.equal(hours.length, 1);
  assert.equal(hours[0]?.precipitationProbability, 0);
});
