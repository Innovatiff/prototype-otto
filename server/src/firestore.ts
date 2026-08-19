/**
 * Firebase Admin bootstrap.
 *
 * No explicit credentials anywhere: Application Default Credentials on Cloud
 * Run, and the emulators locally when FIRESTORE_EMULATOR_HOST /
 * FIREBASE_AUTH_EMULATOR_HOST are set. Service-account JSON files never enter
 * this repo.
 */
import { getApps, initializeApp, type App } from "firebase-admin/app";
import { getAuth, type Auth } from "firebase-admin/auth";
import { getFirestore, type Firestore } from "firebase-admin/firestore";

export const COLLECTIONS = {
  users: "users",
  tasks: "tasks",
  memories: "memories",
  sessions: "sessions",
  briefs: "briefs",
  plans: "plans",
  sessionRecords: "session_records",
  automations: "automations",
  calendarViews: "calendar_views",
  costEvents: "cost_events",
  costDaily: "cost_daily",
} as const;

function app(): App {
  return getApps()[0] ?? initializeApp();
}

let firestore: Firestore | null = null;

export function db(): Firestore {
  if (firestore === null) {
    firestore = getFirestore(app());
    // Never write `undefined` into a document; absent keys stay absent, which
    // is what the Zod schemas (and the Swift decoders) expect.
    firestore.settings({ ignoreUndefinedProperties: true });
  }
  return firestore;
}

export function firebaseAuth(): Auth {
  return getAuth(app());
}
