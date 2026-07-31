import { strict as assert } from "node:assert";
import { test } from "node:test";

import type { Memory } from "@otto/shared";

import { VoyageResponse } from "../src/memory/embed.js";
import {
  parseExtractionResponse,
  planMemoryWrites,
  type ExtractedFact,
} from "../src/memory/extract.js";
import { selectMemories, sortSimilar } from "../src/memory/retrieve.js";

const NOW = new Date("2026-07-31T12:00:00.000Z");

function mem(partial: Partial<Memory> & { id: string; content: string }): Memory {
  return {
    ownerId: "u1",
    category: "preference",
    confidence: 0.8,
    sourceTurnId: "t0",
    createdAt: "2026-07-01T00:00:00.000Z",
    userEdited: false,
    ...partial,
  };
}

// ── Extraction response parsing ─────────────────────────────────────

test("clean JSON, fenced JSON, and [] all parse; garbage yields []", () => {
  const facts = [{ category: "constraint", content: "Does not eat pork." }];
  assert.deepEqual(parseExtractionResponse(JSON.stringify(facts)), facts);
  assert.deepEqual(parseExtractionResponse("```json\n" + JSON.stringify(facts) + "\n```"), facts);
  assert.deepEqual(parseExtractionResponse("[]"), []);
  assert.deepEqual(parseExtractionResponse("Sure! Here are the facts:"), []);
  assert.deepEqual(parseExtractionResponse('{"category":"goal","content":"x"}'), []);
});

test("invalid entries drop individually; the cap holds", () => {
  const mixed = [
    { category: "constraint", content: "Does not eat pork." },
    { category: "mood", content: "tired" },
    { category: "goal" },
    { category: "goal", content: "Run a 5k." },
  ];
  assert.deepEqual(parseExtractionResponse(JSON.stringify(mixed)), [
    { category: "constraint", content: "Does not eat pork." },
    { category: "goal", content: "Run a 5k." },
  ]);
  const many = Array.from({ length: 20 }, (_, i) => ({
    category: "context",
    content: `fact ${i}`,
  }));
  assert.equal(parseExtractionResponse(JSON.stringify(many)).length, 10);
});

// ── Write planning ──────────────────────────────────────────────────

function ids(...values: string[]): () => string {
  const queue = [...values];
  return () => {
    const next = queue.shift();
    assert.ok(next !== undefined, "mintId exhausted");
    return next;
  };
}

const PLAN_INPUT = { userId: "u1", turnId: "t9", now: NOW };

test("a plain fact becomes one create with extraction confidence", () => {
  const facts: ExtractedFact[] = [{ category: "constraint", content: "Does not eat pork." }];
  const plan = planMemoryWrites(facts, [], { ...PLAN_INPUT, mintId: ids("m-new") });
  assert.equal(plan.creates.length, 1);
  assert.equal(plan.supersedes.length, 0);
  const created = plan.creates[0]?.memory;
  assert.equal(created?.id, "m-new");
  assert.equal(created?.confidence, 0.8);
  assert.equal(created?.sourceTurnId, "t9");
  assert.equal(created?.userEdited, false);
});

test("superseding a normal memory stamps the old one", () => {
  const existing = [mem({ id: "m-old", content: "Drinks coffee all day." })];
  const facts: ExtractedFact[] = [
    { category: "preference", content: "No coffee after 2pm.", supersedes: "m-old" },
  ];
  const plan = planMemoryWrites(facts, existing, { ...PLAN_INPUT, mintId: ids("m-new") });
  assert.equal(plan.creates[0]?.memory.supersedes, "m-old");
  assert.deepEqual(plan.supersedes, [{ id: "m-old", supersededBy: "m-new" }]);
});

test("a userEdited memory is never superseded — the new fact is flagged instead", () => {
  const existing = [mem({ id: "m-edited", content: "Drinks coffee all day.", userEdited: true })];
  const facts: ExtractedFact[] = [
    { category: "preference", content: "No coffee after 2pm.", supersedes: "m-edited" },
  ];
  const plan = planMemoryWrites(facts, existing, { ...PLAN_INPUT, mintId: ids("m-new") });
  assert.equal(plan.supersedes.length, 0);
  assert.equal(plan.creates[0]?.memory.conflictsWith, "m-edited");
  assert.equal(plan.creates[0]?.memory.supersedes, undefined);
});

test("dangling supersedes ids are dropped; duplicates are skipped entirely", () => {
  const existing = [mem({ id: "m1", category: "constraint", content: "Does not eat pork." })];
  const facts: ExtractedFact[] = [
    { category: "goal", content: "Run a 5k.", supersedes: "m-ghost" },
    { category: "constraint", content: "does not eat pork." },
  ];
  const plan = planMemoryWrites(facts, existing, { ...PLAN_INPUT, mintId: ids("m2") });
  assert.equal(plan.creates.length, 1);
  assert.equal(plan.creates[0]?.memory.content, "Run a 5k.");
  assert.equal(plan.creates[0]?.memory.supersedes, undefined);
  assert.equal(plan.supersedes.length, 0);
});

// ── Retrieval selection ─────────────────────────────────────────────

test("similar memories sort by distance, newest first on ties", () => {
  const a = mem({ id: "a", content: "a", createdAt: "2026-07-01T00:00:00.000Z" });
  const b = mem({ id: "b", content: "b", createdAt: "2026-07-20T00:00:00.000Z" });
  const c = mem({ id: "c", content: "c", createdAt: "2026-07-10T00:00:00.000Z" });
  const sorted = sortSimilar([
    { memory: a, distance: 0.3 },
    { memory: b, distance: 0.1 },
    { memory: c, distance: 0.3 },
  ]);
  assert.deepEqual(
    sorted.map((memory) => memory.id),
    ["b", "c", "a"],
  );
});

test("identity memories always lead, deduped against similar, superseded excluded", () => {
  const identity = mem({ id: "i1", category: "identity", content: "Name is Alan." });
  const dupe = mem({ id: "i1", category: "identity", content: "Name is Alan." });
  const gone = mem({ id: "s1", content: "old fact", supersededBy: "s2" });
  const kept = mem({ id: "s2", content: "new fact" });
  const selected = selectMemories([identity], [dupe, gone, kept]);
  assert.deepEqual(
    selected.map((memory) => memory.id),
    ["i1", "s2"],
  );
});

test("the token budget caps the block, identity first", () => {
  const identity = mem({ id: "i1", category: "identity", content: "x".repeat(400) });
  const big = mem({ id: "v1", content: "y".repeat(3000) });
  const small = mem({ id: "v2", content: "z".repeat(100) });
  const selected = selectMemories([identity], [big, small], 300);
  // identity (~100 tokens) fits, the 750-token similar does not, the small one does.
  assert.deepEqual(
    selected.map((memory) => memory.id),
    ["i1", "v2"],
  );
});

// ── Voyage response contract ────────────────────────────────────────

test("the Voyage schema rejects wrong-dimension vectors", () => {
  const good = { data: [{ embedding: Array.from({ length: 512 }, () => 0.1), index: 0 }] };
  const bad = { data: [{ embedding: [0.1, 0.2], index: 0 }] };
  assert.ok(VoyageResponse.safeParse(good).success);
  assert.ok(!VoyageResponse.safeParse(bad).success);
});
