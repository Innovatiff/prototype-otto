import { strict as assert } from "node:assert";
import { test } from "node:test";

import {
  BUDGET_ENVELOPE,
  buildExperience,
  EXPERIENCE_SYSTEM_PROMPT,
  EXPERIENCE_TOOL,
  plannedTotal,
  validateExperience,
} from "../src/experience/generate.js";
import { summarize } from "../src/experience/store.js";

const NOW = new Date("2026-08-21T12:00:00.000Z");

function payloadFixture(): Record<string, unknown> {
  return {
    kind: "trip",
    title: "Panama, Five Days",
    destination: "Panama City, Panama",
    vibe: "city",
    days: [
      {
        label: "Day 1 — Casco Viejo",
        items: [
          { kind: "stay", title: "Boutique hotel in Casco Viejo", area: "Casco Viejo", estCost: 520, note: "Four nights, taxes in." },
          { kind: "transport", title: "Airport taxi", estCost: 35 },
          { kind: "food", title: "Fonda dinner", estCost: 40, note: "Order the corvina." },
        ],
      },
      {
        label: "Day 2 — The canal",
        items: [
          { kind: "activity", title: "Miraflores Locks visitor center", estCost: 20 },
          { kind: "food", title: "Fish market ceviche", estCost: 15 },
          { kind: "tip", title: "Carry small bills", note: "Cards are patchy outside malls." },
        ],
      },
    ],
    chapters: [
      { kind: "overview", spoken: "Five days in Panama City, based in Casco Viejo — everything good is a walk away." },
      { kind: "stay", spoken: "One hotel the whole time, so you never repack." },
      { kind: "budget", spoken: "It lands at six-thirty, well under your two thousand — the rest stays back for the unplanned." },
    ],
    summary: "Five days in Panama City under $2,000.",
  };
}

// ── The envelope ────────────────────────────────────────────────────

test("a plan inside the 85% envelope validates; planned math is server-owned", () => {
  const result = validateExperience(payloadFixture(), 2000);
  assert.equal(result.ok, true);
  if (!result.ok) return;
  assert.equal(plannedTotal(result.payload.days), 630);

  const experience = buildExperience(result.payload, {
    id: "e1",
    ownerId: "u1",
    statedBudget: 2000,
    currency: "USD",
    now: NOW,
  });
  assert.equal(experience.budget.stated, 2000);
  assert.equal(experience.budget.planned, 630);
  assert.equal(experience.budget.buffer, 1370);
  assert.equal(experience.budget.currency, "USD");
});

test("blowing the envelope is a named validation error, not a shrug", () => {
  const payload = payloadFixture();
  const days = payload["days"] as Array<{ items: Array<Record<string, unknown>> }>;
  days[0]?.items.push({ kind: "activity", title: "Helicopter tour", estCost: 1200 });
  const result = validateExperience(payload, 2000);
  assert.equal(result.ok, false);
  if (result.ok) return;
  assert.ok(result.errors.some((error) => error.includes("exceeds the envelope 1700")));
  assert.equal(Math.floor(2000 * BUDGET_ENVELOPE), 1700);
});

test("a costless plan is rejected — estimates are the honesty", () => {
  const payload = payloadFixture();
  const days = payload["days"] as Array<{ items: Array<Record<string, unknown>> }>;
  for (const day of days) {
    for (const item of day.items) {
      delete item["estCost"];
    }
  }
  const result = validateExperience(payload, 2000);
  assert.equal(result.ok, false);
  if (result.ok) return;
  assert.ok(result.errors.some((error) => error.includes("nothing carries an estCost")));
});

// ── Chapter order ───────────────────────────────────────────────────

test("overview must open and budget must close the presentation", () => {
  const payload = payloadFixture();
  payload["chapters"] = [
    { kind: "budget", spoken: "Money first, apparently." },
    { kind: "overview", spoken: "And the overview second." },
  ];
  const result = validateExperience(payload, 2000);
  assert.equal(result.ok, false);
  if (result.ok) return;
  assert.ok(result.errors.some((error) => error.includes('"overview" must come first')));
  assert.ok(result.errors.some((error) => error.includes('"budget" must come last')));
});

// ── Summaries ───────────────────────────────────────────────────────

test("summaries carry the card face and drop the itinerary", () => {
  const result = validateExperience(payloadFixture(), 2000);
  assert.equal(result.ok, true);
  if (!result.ok) return;
  const experience = buildExperience(result.payload, {
    id: "e1",
    ownerId: "u1",
    statedBudget: 2000,
    currency: "USD",
    now: NOW,
  });
  const summary = summarize(experience);
  assert.equal(summary.dayCount, 2);
  assert.equal(summary.vibe, "city");
  assert.equal(summary.budget.buffer, 1370);
  assert.ok(!("days" in summary));
  assert.ok(!("chapters" in summary));
});

// ── The contract the prompt and tool carry ──────────────────────────

test("the prompt carries realism, the envelope, and the chapter shape", () => {
  assert.ok(EXPERIENCE_SYSTEM_PROMPT.includes("NEVER invent a specific name"));
  assert.ok(EXPERIENCE_SYSTEM_PROMPT.includes("AT MOST 85% of the stated budget"));
  assert.ok(EXPERIENCE_SYSTEM_PROMPT.includes("Estimate HIGH"));
  assert.ok(EXPERIENCE_SYSTEM_PROMPT.includes("Overview first,"));
  assert.ok(EXPERIENCE_SYSTEM_PROMPT.includes("budget last"));
  assert.equal(EXPERIENCE_TOOL.name, "emit_experience");
});
