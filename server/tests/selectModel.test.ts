import { strict as assert } from "node:assert";
import { test } from "node:test";

import {
  PCC_CONTEXT_CEILING,
  TIER_MODELS,
  estimateTokens,
  selectTier,
  type RouteInput,
} from "../src/router/selectModel.js";

function input(overrides: Partial<RouteInput>): RouteInput {
  return {
    intent: "question",
    utteranceLength: 40,
    requiresMemory: false,
    requiresMultiStep: false,
    contextTokens: 100,
    ...overrides,
  };
}

test("local handles the structured on-device intents", () => {
  for (const intent of ["list_add", "list_query", "check_item", "time_query"]) {
    assert.equal(selectTier(input({ intent })), "local", intent);
  }
});

test("multi-step always routes to opus, over every other signal", () => {
  assert.equal(selectTier(input({ intent: "plan_request", requiresMultiStep: true })), "opus");
  // Contradictory input: multi-step wins even over a local intent.
  assert.equal(selectTier(input({ intent: "list_add", requiresMultiStep: true })), "opus");
});

test("drafting routes to sonnet even under the PCC ceiling", () => {
  assert.equal(selectTier(input({ intent: "message_draft", contextTokens: 50 })), "sonnet");
});

test("the PCC ceiling is a hard gate at exactly 24000", () => {
  assert.equal(PCC_CONTEXT_CEILING, 24_000);
  assert.equal(selectTier(input({ contextTokens: PCC_CONTEXT_CEILING - 1 })), "pcc");
  assert.equal(selectTier(input({ contextTokens: PCC_CONTEXT_CEILING })), "sonnet");
});

test("small non-local turns default to pcc", () => {
  assert.equal(selectTier(input({ intent: "capture", contextTokens: 500 })), "pcc");
  assert.equal(selectTier(input({ intent: "unknown", contextTokens: 12 })), "pcc");
});

test("tier -> model mapping lives in one place and local/pcc never call the API", () => {
  assert.equal(TIER_MODELS.sonnet, "claude-sonnet-5");
  assert.equal(TIER_MODELS.opus, "claude-opus-5");
  assert.equal(TIER_MODELS.local, null);
  assert.equal(TIER_MODELS.pcc, null);
});

test("estimateTokens approximates 4 chars per token, rounding up", () => {
  assert.equal(estimateTokens(""), 0);
  assert.equal(estimateTokens("abcd"), 1);
  assert.equal(estimateTokens("abcde"), 2);
});
