import { strict as assert } from "node:assert";
import { test } from "node:test";

import type { ListItem, TurnEvent } from "@otto/shared";
import { StageVisual, TurnEventType } from "@otto/shared";

import {
  applyItemUpdates,
  CreateTaskInput,
  executeToolUse,
  matchItem,
  normalizeItemText,
  UpdateTaskItemsInput,
  type ToolContext,
} from "../src/tools/execute.js";

const NOW = new Date("2026-07-31T12:00:00.000Z");
const TS = "2026-07-31T11:00:00.000Z";

function item(id: string, text: string, checked = false): ListItem {
  return { id, text, checked, addedAt: TS };
}

// ── Fuzzy matching ──────────────────────────────────────────────────

test("normalization strips punctuation, articles, and case", () => {
  assert.equal(normalizeItemText("The Onions!"), "onions");
  assert.equal(normalizeItemText("  dark   chocolate "), "dark chocolate");
  assert.equal(normalizeItemText("2% milk"), "2 milk");
});

test("spoken references match stored items fuzzily", () => {
  const items = [item("1", "onions"), item("2", "dark chocolate"), item("3", "milk")];
  assert.equal(matchItem(items, "the onions")?.id, "1");
  assert.equal(matchItem(items, "Onion")?.id, "1"); // singular/plural
  assert.equal(matchItem(items, "chocolate")?.id, "2"); // containment
  assert.equal(matchItem(items, "MILK")?.id, "3");
  assert.equal(matchItem(items, "cinnamon"), null);
  assert.equal(matchItem(items, ""), null);
});

// ── Item updates ────────────────────────────────────────────────────

function mint(...values: string[]): () => string {
  const queue = [...values];
  return () => queue.shift() ?? "overflow";
}

test("'got the onions and the milk' checks two off and counts the rest", () => {
  const items = [
    item("1", "onions"),
    item("2", "carrots"),
    item("3", "apples"),
    item("4", "milk"),
    item("5", "cinnamon"),
    item("6", "dark chocolate"),
  ];
  const outcome = applyItemUpdates(items, { check: ["the onions", "the milk"] }, NOW, mint());
  assert.deepEqual(outcome.checked, ["onions", "milk"]);
  assert.deepEqual(outcome.notFound, []);
  assert.equal(outcome.openCount, 4);
});

test("unmatched references are reported, never guessed", () => {
  const outcome = applyItemUpdates([item("1", "onions")], { check: ["butter"] }, NOW, mint());
  assert.deepEqual(outcome.checked, []);
  assert.deepEqual(outcome.notFound, ["butter"]);
});

test("adding an existing item re-opens it instead of duplicating", () => {
  const items = [item("1", "milk", true)];
  const outcome = applyItemUpdates(items, { add: ["milk", "eggs"] }, NOW, mint("new-1"));
  assert.deepEqual(outcome.added, ["eggs"]);
  assert.deepEqual(outcome.unchecked, ["milk"]);
  assert.equal(outcome.items.length, 2);
  assert.equal(outcome.openCount, 2);
});

test("uncheck reopens a checked item", () => {
  const items = [item("1", "onions", true)];
  const outcome = applyItemUpdates(items, { uncheck: ["onions"] }, NOW, mint());
  assert.deepEqual(outcome.unchecked, ["onions"]);
  assert.equal(outcome.items[0]?.checked, false);
});

// ── Input validation ────────────────────────────────────────────────

test("the canonical Walmart utterance parses as ONE list task input", () => {
  const parsed = CreateTaskInput.safeParse({
    intent: "list",
    title: "Walmart list",
    context: "Walmart",
    items: ["onions", "carrots", "apples", "milk", "cinnamon", "dark chocolate"],
  });
  assert.ok(parsed.success);
  assert.equal(parsed.data.items?.length, 6);
  assert.equal(parsed.data.triggerAt, undefined);
});

test("bad tool inputs are rejected, not coerced", () => {
  assert.ok(!CreateTaskInput.safeParse({ intent: "location", title: "x" }).success);
  assert.ok(!CreateTaskInput.safeParse({ intent: "reminder" }).success);
  assert.ok(!CreateTaskInput.safeParse({ intent: "reminder", title: "x", triggerAt: "tomorrow" }).success);
  assert.ok(!UpdateTaskItemsInput.safeParse({ check: ["onions"] }).success);
});

// ── The stage (show_visual) ─────────────────────────────────────────

function stageContext(
  tier: "free" | "lite" | "pro" | "max" = "max",
): { ctx: ToolContext; events: TurnEvent[] } {
  const events: TurnEvent[] = [];
  return {
    events,
    ctx: {
      uid: "u1",
      turnId: "t1",
      now: NOW,
      timezone: "America/Toronto",
      entitled: { tier, meterUid: "u1", anchorAt: null, hasConsent: true },
      emit: (event: TurnEvent) => {
        events.push(event);
      },
    },
  };
}

test("the stage event type exists on the turn stream contract", () => {
  assert.ok(TurnEventType.options.includes("stage"));
});

test("show_visual calendar emits a kind-only stage event (device owns the data)", async () => {
  const { ctx, events } = stageContext();
  const result = await executeToolUse("show_visual", { kind: "calendar" }, ctx);
  assert.notEqual(result.isError, true);
  assert.equal(events.length, 1);
  assert.equal(events[0]?.type, "stage");
  const visual = StageVisual.parse(events[0]?.data);
  assert.equal(visual.kind, "calendar");
  assert.equal(visual.weather, undefined);
  assert.equal(visual.dueTasks, undefined);
});

test("show_visual rejects unknown kinds as a tool error, emitting nothing", async () => {
  const { ctx, events } = stageContext();
  const result = await executeToolUse("show_visual", { kind: "stocks" }, ctx);
  assert.equal(result.isError, true);
  assert.equal(events.length, 0);
});

test("stage visuals parse for every kind the server emits", () => {
  assert.ok(StageVisual.safeParse({ kind: "building", label: "Building your plan" }).success);
  assert.ok(
    StageVisual.safeParse({
      kind: "automation",
      label: "Friday check",
      detail: "Fridays at 3:30 PM",
    }).success,
  );
  assert.ok(
    StageVisual.safeParse({
      kind: "reminders",
      dueTasks: [{ taskId: "t1", title: "Call pharmacy", at: "2026-07-31T15:00:00.000Z" }],
      lists: [{ taskId: "w1", title: "Walmart", openCount: 3 }],
    }).success,
  );
  assert.ok(!StageVisual.safeParse({ kind: "stocks" }).success);
});

// ── Entitlement gates (server refuses; the client only hides UI) ────

test("a Lite user asking for an experience gets a typed refusal + upsell event", async () => {
  const { ctx, events } = stageContext("lite");
  const result = await executeToolUse(
    "create_experience",
    { kind: "trip", request: "plan a trip to panama for two people", budgetAmount: 2000 },
    ctx,
  );
  assert.equal(result.isError, true);
  assert.ok(result.result.includes("part of Pro"));
  const gate = events.find((event) => event.type === "entitlement");
  assert.ok(gate !== undefined);
  assert.deepEqual(gate.data, { feature: "experiences", requiredTier: "pro" });
});

test("Pro passes the experience gate (and fails later only on real work)", async () => {
  const { ctx, events } = stageContext("pro");
  // No API key / Firestore in tests: the call will fail INSIDE generation,
  // which proves the gate itself let it through.
  const result = await executeToolUse(
    "create_experience",
    { kind: "date", request: "plan a romantic date downtown for friday", budgetAmount: 200 },
    ctx,
  );
  assert.ok(!events.some((event) => event.type === "entitlement"));
  assert.equal(result.isError, true);
  assert.ok(!result.result.includes("part of Pro"));
});
