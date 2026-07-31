import { strict as assert } from "node:assert";
import { test } from "node:test";

import type { ConversationMessage } from "@otto/shared";

import {
  capHistory,
  isSessionLive,
  MAX_HISTORY_PAIRS,
  SESSION_IDLE_MS,
} from "../src/sessions/index.js";

const NOW = new Date("2026-07-31T12:00:00.000Z");

function at(msBeforeNow: number): string {
  return new Date(NOW.getTime() - msBeforeNow).toISOString();
}

function pair(index: number): ConversationMessage[] {
  const timestamp = "2026-07-31T11:00:00.000Z";
  return [
    { role: "user", content: `question ${index}`, timestamp },
    { role: "assistant", content: `answer ${index}`, timestamp },
  ];
}

test("a session is live strictly inside the 30-minute idle window", () => {
  assert.equal(isSessionLive(at(SESSION_IDLE_MS - 1000), NOW), true);
  assert.equal(isSessionLive(at(SESSION_IDLE_MS), NOW), false);
  assert.equal(isSessionLive(at(SESSION_IDLE_MS + 1000), NOW), false);
});

test("garbage timestamps never count as live", () => {
  assert.equal(isSessionLive("not-a-date", NOW), false);
  assert.equal(isSessionLive("", NOW), false);
});

test("history under the cap passes through untouched", () => {
  const messages = [...pair(1), ...pair(2)];
  assert.deepEqual(capHistory(messages), messages);
});

test("history over the cap keeps the newest pairs, oldest dropped first", () => {
  const messages = Array.from({ length: MAX_HISTORY_PAIRS + 5 }, (_, i) => pair(i)).flat();
  const capped = capHistory(messages);
  assert.equal(capped.length, MAX_HISTORY_PAIRS * 2);
  assert.equal(capped[0]?.content, "question 5");
  assert.equal(capped[capped.length - 1]?.content, `answer ${MAX_HISTORY_PAIRS + 4}`);
});

test("a corrupted history can never start with an assistant message", () => {
  const [, orphanAnswer] = pair(0);
  assert.ok(orphanAnswer !== undefined);
  const messages = [orphanAnswer, ...pair(1)];
  const capped = capHistory(messages);
  assert.equal(capped[0]?.role, "user");
  assert.equal(capped.length, 2);
});
