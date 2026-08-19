/**
 * The push transport's pure parts: token bookkeeping, dead-token
 * classification, the FCM payload (real content + deep-link data +
 * category), and response marking (first open wins; snooze/dismiss are
 * explicit answers).
 */
import { strict as assert } from "node:assert";
import { test } from "node:test";

import { deliveryResponseUpdate, type DeliveryRecord } from "../src/automations/deliver.js";
import {
  buildPushMessage,
  isDeadTokenCode,
  MAX_DEVICE_TOKENS,
  nextTokens,
  PUSH_CATEGORY,
} from "../src/automations/push.js";
import { SNOOZE_MINUTES } from "../src/routes/automations.js";

const NOW = new Date("2026-08-19T11:02:00.000Z");

test("nextTokens dedupes, keeps most-recent-last, and caps at five devices", () => {
  assert.deepEqual(nextTokens([], "t1"), ["t1"]);
  assert.deepEqual(nextTokens(["t1", "t2"], "t1"), ["t2", "t1"], "re-registering moves to the end");
  const six = nextTokens(["t1", "t2", "t3", "t4", "t5"], "t6");
  assert.equal(six.length, MAX_DEVICE_TOKENS);
  assert.deepEqual(six, ["t2", "t3", "t4", "t5", "t6"], "the oldest falls off");
});

test("only genuinely dead token codes trigger pruning", () => {
  assert.ok(isDeadTokenCode("messaging/registration-token-not-registered"));
  assert.ok(isDeadTokenCode("messaging/invalid-registration-token"));
  assert.ok(!isDeadTokenCode("messaging/internal-error"), "a server hiccup is not a dead device");
  assert.ok(!isDeadTokenCode("messaging/quota-exceeded"));
  assert.ok(!isDeadTokenCode(undefined));
});

test("the payload carries REAL content plus the data a tap needs", () => {
  const message = buildPushMessage(["t1", "t2"], {
    title: "Morning brief",
    body: "9 degrees and likely rain. First up: Henderson review at 9:30 AM.",
    deepLink: "otto://brief",
    deliveryId: "d1",
    automationId: "a1",
    automationType: "morning_brief",
  });
  assert.deepEqual(message.tokens, ["t1", "t2"]);
  assert.equal(message.notification?.title, "Morning brief");
  assert.match(message.notification?.body ?? "", /9 degrees/);
  assert.deepEqual(message.data, {
    deepLink: "otto://brief",
    deliveryId: "d1",
    automationId: "a1",
    automationType: "morning_brief",
  });
  const aps = message.apns?.payload?.aps as Record<string, unknown>;
  assert.equal(aps["category"], PUSH_CATEGORY);
  assert.equal(aps["interruption-level"], "active");
  assert.equal(aps["thread-id"], "morning_brief");
});

test("meeting prep interrupts at time-sensitive — it expires with the meeting", () => {
  const message = buildPushMessage(["t1"], {
    title: "Henderson review",
    body: "In 30 minutes with 3 people.",
    deepLink: "otto://calendar",
    deliveryId: "d2",
    automationId: "a2",
    automationType: "meeting_prep",
  });
  const aps = message.apns?.payload?.aps as Record<string, unknown>;
  assert.equal(aps["interruption-level"], "time-sensitive");
});

function delivery(overrides: Partial<DeliveryRecord> = {}): DeliveryRecord {
  return {
    id: "d1",
    ownerId: "u1",
    automationId: "a1",
    automationType: "morning_brief",
    title: "Morning brief",
    body: "…",
    deepLink: "otto://brief",
    channel: "push",
    titleKey: null,
    openedAt: null,
    action: null,
    actionAt: null,
    sendOutcome: "sent",
    createdAt: "2026-08-19T11:00:00.000Z",
    ...overrides,
  };
}

test("the first open wins; a second open writes nothing", () => {
  assert.deepEqual(deliveryResponseUpdate(delivery(), "opened", NOW), {
    openedAt: NOW.toISOString(),
  });
  assert.equal(
    deliveryResponseUpdate(delivery({ openedAt: "2026-08-19T11:01:00.000Z" }), "opened", NOW),
    null,
  );
});

test("snooze and Not today record the explicit answer", () => {
  assert.deepEqual(deliveryResponseUpdate(delivery(), "snoozed", NOW), {
    action: "snoozed",
    actionAt: NOW.toISOString(),
  });
  assert.deepEqual(deliveryResponseUpdate(delivery(), "dismissed", NOW), {
    action: "dismissed",
    actionAt: NOW.toISOString(),
  });
  assert.equal(SNOOZE_MINUTES, 30);
});
