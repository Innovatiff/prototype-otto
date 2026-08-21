import { strict as assert } from "node:assert";
import { test } from "node:test";

import { DELETION_SPECS } from "../src/account/delete.js";
import { COLLECTIONS } from "../src/firestore.js";

/**
 * The census test: every collection Otto writes must be named in the
 * deletion specs exactly once. Add a collection without deciding how it
 * dies, and this fails — which is the point.
 */
test("account deletion covers every collection, each exactly once", () => {
  const covered = DELETION_SPECS.map((spec) => spec.collection);
  assert.equal(new Set(covered).size, covered.length, "a collection is listed twice");
  for (const name of Object.values(COLLECTIONS)) {
    assert.ok(
      covered.includes(name),
      `collection "${name}" is not covered by account deletion — add a DeletionSpec`,
    );
  }
  assert.equal(covered.length, Object.values(COLLECTIONS).length);
});

test("owner-field specs use the field each collection actually writes", () => {
  const byCollection = new Map(
    DELETION_SPECS.map((spec) => [spec.collection, spec] as const),
  );
  // cost tables key by userId (telemetry), everything else by ownerId.
  const costEvents = byCollection.get(COLLECTIONS.costEvents);
  assert.ok(costEvents !== undefined && "field" in costEvents && costEvents.field === "userId");
  const tasks = byCollection.get(COLLECTIONS.tasks);
  assert.ok(tasks !== undefined && "field" in tasks && tasks.field === "ownerId");
  // Doc-per-user collections delete by id, not by query.
  const views = byCollection.get(COLLECTIONS.calendarViews);
  assert.ok(views !== undefined && "docId" in views);
  const users = byCollection.get(COLLECTIONS.users);
  assert.ok(users !== undefined && "docId" in users);
  // cost_daily docs are keyed `${userId}_${date}` — an id-prefix sweep.
  const daily = byCollection.get(COLLECTIONS.costDaily);
  assert.ok(daily !== undefined && "idPrefix" in daily);
});
