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
          { kind: "stay", title: "Hotel La Compañía", area: "Casco Viejo", address: "Calle Pedro J. Sossa", estCost: 520, note: "Four nights, taxes in.", startTime: "15:00" },
          { kind: "transport", title: "Airport taxi to the hotel", estCost: 35, startTime: "13:30", durationMin: 40, note: "About 25 km." },
          { kind: "food", title: "Fonda Lo Que Hay", estCost: 40, note: "Order the corvina.", startTime: "19:30", durationMin: 90 },
        ],
      },
      {
        label: "Day 2 — The canal",
        items: [
          { kind: "activity", title: "Miraflores Locks visitor center", estCost: 20, startTime: "10:00", durationMin: 120 },
          { kind: "food", title: "Mercado de Mariscos ceviche", estCost: 15, startTime: "13:00" },
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

test("the clock is enforced: non-tips need startTime, drives need durationMin", () => {
  const payload = payloadFixture();
  const days = payload["days"] as Array<{ items: Array<Record<string, unknown>> }>;
  delete days[0]?.items[2]?.["startTime"]; // dinner loses its clock
  delete days[0]?.items[1]?.["durationMin"]; // the taxi loses its duration
  const result = validateExperience(payload, 2000);
  assert.equal(result.ok, false);
  if (result.ok) return;
  assert.ok(result.errors.some((error) => error.includes("startTime is required")));
  assert.ok(result.errors.some((error) => error.includes("transport needs durationMin")));
  // The tip never needs a clock.
  assert.ok(!result.errors.some((error) => error.includes("Carry small bills")));
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

test("the prompt makes it decided, named, and followable by the clock", () => {
  assert.ok(EXPERIENCE_SYSTEM_PROMPT.includes("DECIDE BY NAME"));
  assert.ok(EXPERIENCE_SYSTEM_PROMPT.includes("one specific pick each, by name"));
  assert.ok(EXPERIENCE_SYSTEM_PROMPT.includes("what to order in the note"));
  assert.ok(EXPERIENCE_SYSTEM_PROMPT.includes("instruction sheet"));
  assert.ok(EXPERIENCE_SYSTEM_PROMPT.includes("approximate gas or fare in estCost"));
});
