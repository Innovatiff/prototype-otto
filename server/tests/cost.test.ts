import { strict as assert } from "node:assert";
import { test } from "node:test";

import { estimateCostUsd, type TokenCounts } from "../src/telemetry/cost.js";

function tokens(partial: Partial<TokenCounts>): TokenCounts {
  return {
    inputTokens: 0,
    outputTokens: 0,
    cacheReadTokens: 0,
    cacheCreationTokens: 0,
    ...partial,
  };
}

test("no model call (future on-device tiers) is free by construction", () => {
  assert.equal(estimateCostUsd(null, tokens({ inputTokens: 1_000_000, outputTokens: 1_000_000 })), 0);
});

test("sonnet and opus bill at sticker per-million rates", () => {
  assert.equal(estimateCostUsd("claude-sonnet-5", tokens({ inputTokens: 1_000_000 })), 3);
  assert.equal(estimateCostUsd("claude-sonnet-5", tokens({ outputTokens: 1_000_000 })), 15);
  assert.equal(estimateCostUsd("claude-opus-5", tokens({ inputTokens: 1_000_000 })), 5);
  assert.equal(estimateCostUsd("claude-opus-5", tokens({ outputTokens: 1_000_000 })), 25);
});

test("cache reads bill at a tenth of the input rate, writes at 1.25x", () => {
  assert.equal(estimateCostUsd("claude-sonnet-5", tokens({ cacheReadTokens: 1_000_000 })), 0.3);
  assert.equal(
    estimateCostUsd("claude-sonnet-5", tokens({ cacheCreationTokens: 1_000_000 })),
    3.75,
  );
});

test("an unknown model estimates to zero rather than guessing a rate", () => {
  assert.equal(estimateCostUsd("claude-next-99", tokens({ inputTokens: 1_000_000 })), 0);
});

test("small calls cost fractions, not zero", () => {
  const cost = estimateCostUsd("claude-sonnet-5", tokens({ inputTokens: 120, outputTokens: 80 }));
  assert.ok(cost > 0);
  assert.ok(cost < 0.01);
});
