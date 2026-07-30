import { strict as assert } from "node:assert";
import { test } from "node:test";

import { estimateCostUsd } from "../src/telemetry/cost.js";

test("local and pcc are free by construction — no API call is ever made", () => {
  assert.equal(estimateCostUsd("local", 1_000_000, 1_000_000), 0);
  assert.equal(estimateCostUsd("pcc", 1_000_000, 1_000_000), 0);
});

test("sonnet and opus use the placeholder per-million rates", () => {
  assert.equal(estimateCostUsd("sonnet", 1_000_000, 0), 3);
  assert.equal(estimateCostUsd("sonnet", 0, 1_000_000), 15);
  assert.equal(estimateCostUsd("opus", 1_000_000, 0), 15);
  assert.equal(estimateCostUsd("opus", 0, 1_000_000), 75);
});

test("small calls cost fractions, not zero", () => {
  const cost = estimateCostUsd("sonnet", 120, 80);
  assert.ok(cost > 0);
  assert.ok(cost < 0.01);
});
