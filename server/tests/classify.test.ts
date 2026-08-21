import { strict as assert } from "node:assert";
import { test } from "node:test";

import { classify, type Intent } from "../src/router/classify.js";

const CASES: ReadonlyArray<readonly [string, Intent]> = [
  // list_add
  ["add milk to the walmart list", "list_add"],
  ["add eggs", "list_add"],
  ["put paper towels on the home depot list", "list_add"],
  // list_query
  ["what's on my walmart list", "list_query"],
  ["show me the grocery list", "list_query"],
  // check_item
  ["check off the milk", "check_item"],
  ["mark the dentist appointment as done", "check_item"],
  ["i got the milk", "check_item"],
  // reminder_create
  ["remind me to call mom at 5", "reminder_create"],
  ["don't let me forget the dry cleaning", "reminder_create"],
  ["remember to water the plants", "reminder_create"],
  // message_draft
  ["text sarah that i'm running late", "message_draft"],
  ["email my landlord about the leak", "message_draft"],
  ["tell dad happy birthday", "message_draft"],
  // capture
  ["note to self the gate code is 4437", "capture"],
  ["jot this down i parked on level 3", "capture"],
  ["remember that lucy prefers window seats", "capture"],
  // time_query
  ["what time is it", "time_query"],
  ["what's the date today", "time_query"],
  // plan_request
  ["build me a 6 week half marathon training plan", "plan_request"],
  ["make a meal plan for the week", "plan_request"],
  // question — including near-misses for other intents
  ["why is the sky blue", "question"],
  ["is the hardware store open on sunday?", "question"],
  ["how do i get to the airport", "question"],
  ["tell me a joke", "question"],
  ["what should i make for dinner?", "question"],
  ["what's the plan for today?", "question"],
  // unknown
  ["blorp", "unknown"],
  ["", "unknown"],
  ["   ", "unknown"],
];

test("classify routes each utterance to the pinned intent", () => {
  for (const [utterance, expected] of CASES) {
    assert.equal(classify(utterance), expected, `"${utterance}"`);
  }
});

test("classify is case-insensitive and trims", () => {
  assert.equal(classify("  REMIND ME to stretch  "), "reminder_create");
});

test("classify is stateless across repeated calls (no global-regex lastIndex)", () => {
  for (let i = 0; i < 3; i += 1) {
    assert.equal(classify("remind me to stretch"), "reminder_create");
    assert.equal(classify("what time is it"), "time_query");
  }
});

// ── The margin gate's intents (never worth a sonnet turn) ───────────

test("the cheap intents classify away from the question catch-all", () => {
  assert.equal(classify("How's the weather looking today?"), "weather_query");
  assert.equal(classify("is it going to rain tomorrow"), "weather_query");
  assert.equal(classify("what's on my calendar this afternoon"), "calendar_lookup");
  assert.equal(classify("am I free thursday"), "calendar_lookup");
  assert.equal(classify("do I have anything tomorrow"), "calendar_lookup");
  assert.equal(classify("how's my day looking"), "calendar_lookup");
  assert.equal(classify("what's today's date"), "time_query");
  assert.equal(classify("what day is tomorrow"), "date_query");
  assert.equal(classify("I'm done with the report"), "complete_task");
  assert.equal(classify("finished the workout"), "complete_task");
  assert.equal(classify("okay"), "simple_ack");
  assert.equal(classify("Thanks!"), "simple_ack");
  assert.equal(classify("sounds good"), "simple_ack");
  assert.equal(classify("never mind"), "simple_ack");
  // Anchoring: an ack with more behind it is NOT an ack.
  assert.notEqual(classify("thanks, and add milk to the list"), "simple_ack");
});
