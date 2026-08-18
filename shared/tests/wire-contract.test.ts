/**
 * Guards the wire contract between the generated Swift models and the Zod schemas.
 *
 * The Swift compiler is not available in CI on Linux, but the wire contract is fully
 * testable: we construct exactly the JSON the generated `encode(to:)` emits and assert
 * the schemas accept it, and assert the schemas' own output is decodable by the rules
 * the generator emitted.
 *
 * If one of these fails after a schema change, re-run `npm run codegen` and re-read
 * the generated Swift before assuming the test is wrong.
 */
import { strict as assert } from "node:assert";
import { test } from "node:test";

import {
  CalendarEvent,
  Conflict,
  ListItem,
  Memory,
  Plan,
  Task,
  Trigger,
  TurnEvent,
  TurnRequest,
  isoDateTime,
} from "../schemas/index.js";

/**
 * The exact form `OttoCoding.iso8601String(from:)` produces:
 * `Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt)`.
 * Identical to JavaScript's `Date.prototype.toISOString()`.
 */
const CANONICAL_DATE = "2026-07-30T14:00:00.123Z";

const swiftEncodedTask = {
  id: "t1",
  ownerId: "u1",
  intent: "list",
  title: "Groceries",
  items: [{ id: "l1", text: "milk", checked: false, addedAt: CANONICAL_DATE }],
  trigger: { type: "none" },
  verification: "none",
  status: "active",
  createdAt: CANONICAL_DATE,
} as const;

test("the canonical Swift date form is accepted, and offset-less strings are not", () => {
  assert.ok(isoDateTime.safeParse(CANONICAL_DATE).success);
  assert.ok(isoDateTime.safeParse("2026-07-30T14:00:00Z").success);
  assert.ok(isoDateTime.safeParse("2026-07-30T10:00:00-04:00").success);
  assert.ok(isoDateTime.safeParse("2026-07-30T10:00:00.123-04:00").success);
  assert.ok(isoDateTime.safeParse("2026-07-30T14:00:00.123456Z").success);
  assert.ok(!isoDateTime.safeParse("2026-07-30T14:00:00").success);
});

test("optional fields must be OMITTED, never null — this is why Swift uses encodeIfPresent", () => {
  assert.ok(
    !ListItem.safeParse({
      id: "l1",
      text: "milk",
      checked: false,
      quantity: null,
      addedAt: CANONICAL_DATE,
    }).success,
    "explicit null must be rejected, otherwise encodeIfPresent is not required",
  );
  assert.ok(
    ListItem.safeParse({ id: "l1", text: "milk", checked: false, addedAt: CANONICAL_DATE }).success,
  );
});

test("a Swift-encoded Task validates, with nil optionals omitted", () => {
  const parsed = Task.safeParse(swiftEncodedTask);
  assert.ok(parsed.success, JSON.stringify(parsed.success ? {} : parsed.error.issues));
});

test("every Verification wire value round-trips despite renamed Swift cases", () => {
  for (const verification of ["none", "inline", "voice_confirm", "system_sheet"]) {
    assert.ok(Task.safeParse({ ...swiftEncodedTask, verification }).success, verification);
  }
});

test("every Trigger variant matches what the generated union encodes", () => {
  assert.ok(Trigger.safeParse({ type: "none" }).success);
  assert.ok(Trigger.safeParse({ type: "time", at: CANONICAL_DATE }).success);
  assert.ok(
    Trigger.safeParse({
      type: "recurring",
      rrule: "FREQ=WEEKLY;BYDAY=MO",
      nextFire: CANONICAL_DATE,
    }).success,
  );
  // The generated `init(from:)` throws on an unknown discriminator; Zod agrees.
  assert.ok(!Trigger.safeParse({ type: "monthly" }).success);
});

test("TurnEvent.data is absent for done/error events, so Swift must treat it as optional", () => {
  const done = TurnEvent.parse({ type: "done" });
  assert.ok(
    !("data" in done),
    "z.unknown() accepts a missing key with no Optional wrapper; the Swift property " +
      "must be JSONValue? or every done/error event fails to decode",
  );
  assert.ok(TurnEvent.safeParse({ type: "token", data: "hello" }).success);
  assert.ok(TurnEvent.safeParse({ type: "task_created", data: swiftEncodedTask }).success);
  // A present-but-null data survives as JSONValue.null, which is why the generator
  // emits a `container.contains(...)` check rather than decodeIfPresent.
  assert.ok(TurnEvent.safeParse({ type: "done", data: null }).success);
});

test("a Swift-encoded Memory validates, with and without an embedding", () => {
  const base = {
    id: "m1",
    ownerId: "u1",
    category: "preference",
    content: "Prefers oat milk",
    confidence: 0.92,
    sourceTurnId: "turn1",
    createdAt: CANONICAL_DATE,
    userEdited: false,
  };
  assert.ok(Memory.safeParse(base).success);
  assert.ok(Memory.safeParse({ ...base, embedding: [0.1, 0.2, 0.3] }).success);
});

test("Plan.constraints accepts every JSONValue case the Swift enum can encode", () => {
  const parsed = Plan.safeParse({
    id: "p1",
    ownerId: "u1",
    meta: { domain: "fitness", goal: "5k", horizonDays: 42, version: 1 },
    constraints: {
      daysPerWeek: 3,
      injuries: ["knee"],
      notes: null,
      intense: true,
      ratio: 1.5,
      nested: { a: 1 },
    },
    schedule: [{ sessionId: "s1", dayOffset: 0, timeOfDay: "08:00" }],
    sessions: [
      {
        id: "s1",
        title: "Easy run",
        estimatedMinutes: 30,
        steps: [
          {
            id: "st1",
            type: "counted",
            title: "Squat",
            cue: "Go",
            completion: "manual",
            target: { sets: 3, reps: 10, load: 22.5 },
          },
        ],
      },
    ],
    createdAt: CANONICAL_DATE,
  });
  assert.ok(parsed.success, JSON.stringify(parsed.success ? {} : parsed.error.issues));
});

test("a Swift-encoded TurnRequest validates", () => {
  assert.ok(
    TurnRequest.safeParse({
      turnId: "turn-1",
      text: "add milk to the walmart list",
      clientTimestamp: CANONICAL_DATE,
      timezone: "America/Toronto",
    }).success,
  );
});

test("a Swift-encoded CalendarEvent and Conflict validate", () => {
  const swiftEncodedEvent = {
    id: "evt-1",
    title: "Dentist",
    startsAt: CANONICAL_DATE,
    endsAt: CANONICAL_DATE,
    isAllDay: false,
    location: "Toronto",
  };
  assert.ok(CalendarEvent.safeParse(swiftEncodedEvent).success);
  // isAllDay is defaulted — a payload without it still parses.
  const { isAllDay, ...withoutAllDay } = swiftEncodedEvent;
  const parsed = CalendarEvent.safeParse(withoutAllDay);
  assert.ok(parsed.success);
  assert.equal(parsed.data?.isAllDay, false);

  assert.ok(
    Conflict.safeParse({
      eventA: swiftEncodedEvent,
      eventB: { ...swiftEncodedEvent, id: "evt-2", location: "Mississauga" },
      kind: "travel",
      minutesShort: 10,
    }).success,
  );
});

test("schema output always supplies the keys the Swift decoder requires", () => {
  const parsed = Task.parse(swiftEncodedTask);
  // Fields the generator emits as `decode` (throws when the key is missing).
  const required = [
    "id",
    "ownerId",
    "intent",
    "title",
    "items",
    "trigger",
    "verification",
    "status",
    "createdAt",
  ];
  const missing = required.filter((key) => !(key in parsed));
  assert.deepEqual(missing, []);
});
