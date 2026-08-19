// Rules-level tests for firestore.rules, run against the Firestore emulator:
//
//   npm run test:rules
//
// (wraps `firebase emulators:exec`, which starts the emulator, runs this file
// with node --test, and tears the emulator down.)
//
// The headline is acceptance criterion #5: a read of another user's task is
// rejected BY THE RULES — not by API scoping, which is tested separately in
// server/tests. assertFails resolves only on a rules denial, so every
// expectation here is exact.
import { readFileSync } from "node:fs";
import { after, test } from "node:test";

import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from "@firebase/rules-unit-testing";
import {
  collection,
  deleteDoc,
  doc,
  getDoc,
  getDocs,
  query,
  setDoc,
  updateDoc,
  where,
} from "firebase/firestore";

const ALICE = "alice-uid";
const BOB = "bob-uid";

const emulatorHost = process.env.FIRESTORE_EMULATOR_HOST ?? "127.0.0.1:8087";
const [host, port] = emulatorHost.split(":");

const testEnv = await initializeTestEnvironment({
  projectId: "demo-otto",
  firestore: {
    rules: readFileSync(new URL("./firestore.rules", import.meta.url), "utf8"),
    host,
    port: Number(port),
  },
});

after(() => testEnv.cleanup());

// Seed with rules disabled (as the server's Admin SDK would write).
await testEnv.withSecurityRulesDisabled(async (ctx) => {
  const db = ctx.firestore();
  await setDoc(doc(db, "tasks/task-alice"), {
    id: "task-alice",
    ownerId: ALICE,
    intent: "list",
    title: "Groceries",
    items: [],
    trigger: { type: "none" },
    verification: "inline",
    status: "active",
    createdAt: "2026-07-30T14:00:00.000Z",
  });
  await setDoc(doc(db, "memories/mem-alice"), {
    id: "mem-alice",
    ownerId: ALICE,
    category: "preference",
    content: "Prefers oat milk",
    confidence: 0.9,
    sourceTurnId: "turn-1",
    createdAt: "2026-07-30T14:00:00.000Z",
    userEdited: false,
  });
  await setDoc(doc(db, "plans/plan-alice"), {
    id: "plan-alice",
    ownerId: ALICE,
    meta: { domain: "fitness", goal: "5k", horizonDays: 42, version: 1 },
    constraints: {},
    schedule: [],
    sessions: [],
    createdAt: "2026-07-30T14:00:00.000Z",
  });
  await setDoc(doc(db, `users/${ALICE}`), {
    ownerId: ALICE,
    addressTerm: "Boss",
    createdAt: "2026-07-30T14:00:00.000Z",
  });
  await setDoc(doc(db, "sessions/sess-alice"), {
    sessionId: "sess-alice",
    ownerId: ALICE,
    startedAt: "2026-07-30T14:00:00.000Z",
    lastTurnAt: "2026-07-30T14:05:00.000Z",
    messages: [
      { role: "user", content: "hi", timestamp: "2026-07-30T14:05:00.000Z" },
      { role: "assistant", content: "Hello.", timestamp: "2026-07-30T14:05:01.000Z" },
    ],
  });
  await setDoc(doc(db, "automations/auto-alice"), {
    id: "auto-alice",
    ownerId: ALICE,
    type: "morning_brief",
    label: "Morning brief",
    enabled: true,
    schedule: { kind: "fixed", rrule: "FREQ=DAILY", timeOfDay: "07:00" },
    timezone: "America/New_York",
    action: { kind: "morning_brief", params: {} },
    lastRunAt: null,
    nextRunAt: "2026-08-19T11:00:00.000Z",
    lastResult: null,
    lockedUntil: "2026-08-19T11:02:00.000Z",
    createdAt: "2026-08-01T00:00:00.000Z",
  });
  await setDoc(doc(db, `calendar_views/${ALICE}`), {
    ownerId: ALICE,
    syncedAt: "2026-08-19T11:00:00.000Z",
    timezone: "America/New_York",
    events: [
      {
        id: "evt-1",
        title: "Henderson review",
        startsAt: "2026-08-19T13:30:00.000Z",
        endsAt: "2026-08-19T14:00:00.000Z",
        attendeeCount: 3,
      },
    ],
  });
  await setDoc(doc(db, "cost_events/evt-1"), {
    userId: ALICE,
    turnId: "turn-1",
    tier: "pcc",
    purpose: "converse",
    inputTokens: 10,
    outputTokens: 10,
    cachedTokens: 0,
    latencyMs: 400,
    estimatedCostUsd: 0,
    timestamp: new Date(),
  });
  await setDoc(doc(db, `cost_daily/${ALICE}_2026-07-30`), {
    userId: ALICE,
    date: "2026-07-30",
    totalCostUsd: 0,
    callCount: 1,
    byTier: { local: 0, pcc: 1, sonnet: 0, opus: 0 },
  });
});

const alice = testEnv.authenticatedContext(ALICE).firestore();
const bob = testEnv.authenticatedContext(BOB).firestore();
const anon = testEnv.unauthenticatedContext().firestore();

// ── ACCEPTANCE CRITERION #5 ──────────────────────────────────────────

test("ACCEPTANCE #5: another user's read of a task is rejected", async () => {
  await assertFails(getDoc(doc(bob, "tasks/task-alice")));
});

test("the owner's read of the same task succeeds (control)", async () => {
  await assertSucceeds(getDoc(doc(alice, "tasks/task-alice")));
});

// ── tasks: ownership on every operation ──────────────────────────────

test("unauthenticated reads are rejected", async () => {
  await assertFails(getDoc(doc(anon, "tasks/task-alice")));
});

test("create requires ownerId == auth.uid; spoofed ownership is rejected", async () => {
  await assertSucceeds(
    setDoc(doc(bob, "tasks/task-bob"), {
      id: "task-bob",
      ownerId: BOB,
      intent: "capture",
      title: "Bob's note",
      items: [],
      trigger: { type: "none" },
      verification: "none",
      status: "active",
      createdAt: "2026-07-30T14:00:00.000Z",
    }),
  );
  await assertFails(
    setDoc(doc(bob, "tasks/task-spoof"), {
      id: "task-spoof",
      ownerId: ALICE, // pretending to write as alice
      intent: "capture",
      title: "spoof",
      items: [],
      trigger: { type: "none" },
      verification: "none",
      status: "active",
      createdAt: "2026-07-30T14:00:00.000Z",
    }),
  );
});

test("update: owner can update; others cannot; ownership cannot be transferred", async () => {
  await assertSucceeds(updateDoc(doc(alice, "tasks/task-alice"), { title: "Groceries (edited)" }));
  await assertFails(updateDoc(doc(bob, "tasks/task-alice"), { title: "hijacked" }));
  await assertFails(updateDoc(doc(alice, "tasks/task-alice"), { ownerId: BOB }));
});

test("delete: another user cannot delete; the owner can", async () => {
  await assertFails(deleteDoc(doc(bob, "tasks/task-alice")));
  await assertSucceeds(deleteDoc(doc(bob, "tasks/task-bob")));
});

test("list: allowed only when scoped to your own uid", async () => {
  await assertSucceeds(getDocs(query(collection(alice, "tasks"), where("ownerId", "==", ALICE))));
  await assertFails(getDocs(query(collection(bob, "tasks"), where("ownerId", "==", ALICE))));
  await assertFails(getDocs(collection(bob, "tasks"))); // unscoped
});

// ── memories and plans: same contract ────────────────────────────────

test("memories: cross-user read rejected, owner read succeeds", async () => {
  await assertFails(getDoc(doc(bob, "memories/mem-alice")));
  await assertSucceeds(getDoc(doc(alice, "memories/mem-alice")));
});

test("plans: cross-user read rejected, owner read succeeds", async () => {
  await assertFails(getDoc(doc(bob, "plans/plan-alice")));
  await assertSucceeds(getDoc(doc(alice, "plans/plan-alice")));
});

test("plans: immutable from clients — even the owner cannot write", async () => {
  // Plans are server-authored; adaptation writes new versions via the API.
  await assertFails(
    setDoc(doc(alice, "plans/plan-new"), {
      id: "plan-new",
      ownerId: ALICE,
      meta: { domain: "fitness", goal: "5k", horizonDays: 42, version: 1 },
      constraints: {},
      schedule: [],
      sessions: [],
      status: "active",
      createdAt: "2026-07-30T14:00:00.000Z",
    }),
  );
  await assertFails(
    setDoc(doc(alice, "plans/plan-alice"), {
      id: "plan-alice",
      ownerId: ALICE,
      meta: { domain: "fitness", goal: "10k", horizonDays: 42, version: 1 },
      constraints: {},
      schedule: [],
      sessions: [],
      status: "active",
      createdAt: "2026-07-30T14:00:00.000Z",
    }),
  );
});

// ── cost telemetry: server-only, no client access at all ─────────────

test("users: the owner reads and writes their own profile; nobody else's", async () => {
  await assertSucceeds(getDoc(doc(alice, `users/${ALICE}`)));
  await assertSucceeds(
    setDoc(doc(alice, `users/${ALICE}`), {
      ownerId: ALICE,
      addressTerm: "Chief",
      createdAt: "2026-07-30T14:00:00.000Z",
    }),
  );
  await assertFails(getDoc(doc(bob, `users/${ALICE}`)));
  await assertFails(getDoc(doc(anon, `users/${ALICE}`)));
  // Writing a profile whose ownerId is not the path uid is forged.
  await assertFails(
    setDoc(doc(alice, `users/${ALICE}`), {
      ownerId: BOB,
      addressTerm: "Boss",
      createdAt: "2026-07-30T14:00:00.000Z",
    }),
  );
});

test("briefs: server-only — the owner cannot read or write their own brief", async () => {
  await assertFails(getDoc(doc(alice, `briefs/${ALICE}_2026-08-18`)));
  await assertFails(
    setDoc(doc(alice, `briefs/${ALICE}_2026-08-18`), {
      ownerId: ALICE,
      date: "2026-08-18",
      spoken: "forged",
      summary: "forged",
      createdAt: "2026-08-18T12:00:00.000Z",
    }),
  );
});

test("sessions: server-only — the owner cannot read or write their own session", async () => {
  await assertFails(getDoc(doc(alice, "sessions/sess-alice")));
  await assertFails(
    getDocs(query(collection(alice, "sessions"), where("ownerId", "==", ALICE))),
  );
  await assertFails(
    setDoc(doc(alice, "sessions/sess-forged"), {
      sessionId: "sess-forged",
      ownerId: ALICE,
      startedAt: "2026-07-30T14:00:00.000Z",
      lastTurnAt: "2026-07-30T14:00:00.000Z",
      messages: [],
    }),
  );
});

test("automations: server-only — the owner cannot read, list, toggle, or unlock their own", async () => {
  await assertFails(getDoc(doc(alice, "automations/auto-alice")));
  await assertFails(
    getDocs(query(collection(alice, "automations"), where("ownerId", "==", ALICE))),
  );
  // Flipping enabled, forging a run result, or clearing the tick's lock —
  // all management goes through the API.
  await assertFails(updateDoc(doc(alice, "automations/auto-alice"), { enabled: false }));
  await assertFails(updateDoc(doc(alice, "automations/auto-alice"), { lockedUntil: null }));
  await assertFails(
    setDoc(doc(alice, "automations/auto-forged"), {
      id: "auto-forged",
      ownerId: ALICE,
      type: "custom",
      label: "forged",
      enabled: true,
      schedule: { kind: "fixed", rrule: "FREQ=DAILY", timeOfDay: "07:00" },
      timezone: "America/New_York",
      action: { kind: "composite", params: {} },
      createdAt: "2026-08-01T00:00:00.000Z",
    }),
  );
});

test("calendar_views: server-only — the owner cannot read back or forge their view", async () => {
  await assertFails(getDoc(doc(alice, `calendar_views/${ALICE}`)));
  await assertFails(
    setDoc(doc(alice, `calendar_views/${ALICE}`), {
      ownerId: ALICE,
      syncedAt: "2026-08-19T11:00:00.000Z",
      timezone: "America/New_York",
      events: [],
    }),
  );
  await assertFails(deleteDoc(doc(alice, `calendar_views/${ALICE}`)));
});

test("deliveries: server-only — the owner cannot read the push log or forge opens", async () => {
  await assertFails(getDoc(doc(alice, "deliveries/del-1")));
  await assertFails(
    getDocs(query(collection(alice, "deliveries"), where("ownerId", "==", ALICE))),
  );
  await assertFails(
    setDoc(doc(alice, "deliveries/del-forged"), {
      id: "del-forged",
      ownerId: ALICE,
      automationId: "auto-alice",
      openedAt: "2026-08-19T12:00:00.000Z",
    }),
  );
});

test("cost_events: no client read or write, even by the user it concerns", async () => {
  await assertFails(getDoc(doc(alice, "cost_events/evt-1")));
  await assertFails(getDocs(query(collection(alice, "cost_events"), where("userId", "==", ALICE))));
  await assertFails(
    setDoc(doc(alice, "cost_events/evt-forged"), {
      userId: ALICE,
      estimatedCostUsd: -100,
    }),
  );
});

test("cost_daily: no client read or write, even of your own rollup", async () => {
  await assertFails(getDoc(doc(alice, `cost_daily/${ALICE}_2026-07-30`)));
  await assertFails(
    setDoc(doc(alice, `cost_daily/${ALICE}_2026-07-30`), { totalCostUsd: 0 }),
  );
});

// ── deny by default ──────────────────────────────────────────────────

test("unknown collections are denied outright", async () => {
  await assertFails(getDoc(doc(alice, "profiles/alice-uid")));
  await assertFails(setDoc(doc(alice, "profiles/alice-uid"), { ownerId: ALICE }));
});
