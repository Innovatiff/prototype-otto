/**
 * Brief gathering: everything the synthesis call reads, assembled from the
 * client's calendar payload, Firestore, and the weather provider. All date
 * questions ("is this due today?") are answered by comparing WALL DATES in
 * the user's timezone — never by UTC offset arithmetic.
 */
import type {
  BriefDueTask,
  BriefListCount,
  BriefPlanSession,
  BriefRequest,
  CurrentWeather,
  Memory,
  Plan,
  SessionRecord,
  Task,
} from "@otto/shared";
import { Task as TaskSchema } from "@otto/shared";

import { COLLECTIONS, db } from "../firestore.js";
import { errorFields, logWarning } from "../log.js";
import { parseMemoryDoc } from "../memory/docs.js";
import { loadActivePlans, loadSessionRecords } from "../plans/store.js";
import { cachedCurrentWeather, DEFAULT_LAT, DEFAULT_LON } from "../services/weather/index.js";
import { wallDate } from "../util/time.js";
import { loadBriefSummary } from "./store.js";

export { DEFAULT_LAT, DEFAULT_LON };
export { wallDate };

export interface BriefContext {
  /** Wall date in the user's timezone, YYYY-MM-DD. */
  date: string;
  weather: CurrentWeather | null;
  request: BriefRequest;
  dueTasks: BriefDueTask[];
  lists: BriefListCount[];
  /** Today's plan occurrences. Empty ≠ no plans — see hasActivePlans. */
  planSessions: BriefPlanSession[];
  /** False means no active plans at all — the plans chapter is omitted. */
  hasActivePlans: boolean;
  /** Newest goal/context memories, at most 5. */
  carried: Memory[];
  yesterdaySummary: string | null;
}

/** The instant a task fires, when it has one. */
export function fireInstant(task: Task): string | null {
  switch (task.trigger.type) {
    case "time":
      return task.trigger.at;
    case "recurring":
      return task.trigger.nextFire;
    case "none":
      return null;
  }
}

/** Reminders whose fire instant lands on today's wall date. */
export function dueToday(tasks: Task[], now: Date, timezone: string): BriefDueTask[] {
  const today = wallDate(now, timezone);
  return tasks
    .flatMap((task) => {
      const at = fireInstant(task);
      if (at === null || wallDate(new Date(at), timezone) !== today) {
        return [];
      }
      return [{ taskId: task.id, title: task.title, at }];
    })
    .sort((a, b) => a.at.localeCompare(b.at));
}

/** Open lists as counts — never contents. */
export function listCounts(tasks: Task[]): BriefListCount[] {
  return tasks
    .filter((task) => task.intent === "list")
    .flatMap((task) => {
      const openCount = task.items.filter((item) => !item.checked).length;
      return openCount > 0
        ? [{ taskId: task.id, title: task.title, context: task.context, openCount }]
        : [];
    });
}

/**
 * Schedule entries whose occurrence (plan start + dayOffset days) lands on
 * today's wall date, marked completed when a session record for that
 * template was filed today. Pure — the loader feeds it.
 */
export function planSessionsToday(
  plans: readonly Plan[],
  recordsByPlan: ReadonlyMap<string, readonly SessionRecord[]>,
  now: Date,
  timezone: string,
): BriefPlanSession[] {
  const today = wallDate(now, timezone);
  const sessions: BriefPlanSession[] = [];
  for (const plan of plans) {
    const startMs = new Date(plan.createdAt).getTime();
    const doneToday = new Set(
      (recordsByPlan.get(plan.id) ?? [])
        .filter((record) => wallDate(new Date(record.completedAt), timezone) === today)
        .map((record) => record.sessionId),
    );
    for (const entry of plan.schedule) {
      const occursOn = wallDate(new Date(startMs + entry.dayOffset * 86_400_000), timezone);
      if (occursOn !== today) {
        continue;
      }
      const template = plan.sessions.find((session) => session.id === entry.sessionId);
      sessions.push({
        planId: plan.id,
        sessionId: entry.sessionId,
        sessionTitle: template?.title ?? plan.meta.goal,
        domain: plan.meta.domain,
        week: Math.floor(entry.dayOffset / 7) + 1,
        timeOfDay: entry.timeOfDay,
        completed: doneToday.has(entry.sessionId),
      });
    }
  }
  return sessions.sort((a, b) => (a.timeOfDay ?? "99").localeCompare(b.timeOfDay ?? "99"));
}

/**
 * Active plans + today's occurrences; degrades to "no plans" on failure.
 * Shared with show_visual (the conversational plans illustration).
 */
export async function loadPlanContext(
  uid: string,
  now: Date,
  timezone: string,
): Promise<{ planSessions: BriefPlanSession[]; hasActivePlans: boolean }> {
  try {
    const plans = await loadActivePlans(uid);
    if (plans.length === 0) {
      return { planSessions: [], hasActivePlans: false };
    }
    const recordsByPlan = new Map<string, readonly SessionRecord[]>();
    await Promise.all(
      plans.map(async (plan) => {
        recordsByPlan.set(plan.id, await loadSessionRecords(uid, plan.id, 20));
      }),
    );
    return {
      planSessions: planSessionsToday(plans, recordsByPlan, now, timezone),
      hasActivePlans: true,
    };
  } catch (err: unknown) {
    logWarning("brief_plans_failed", { userId: uid, ...errorFields(err) });
    return { planSessions: [], hasActivePlans: false };
  }
}

/** Shared with the automation handlers (evening shutdown, meeting prep). */
export async function loadActiveTasks(uid: string): Promise<Task[]> {
  const snapshot = await db()
    .collection(COLLECTIONS.tasks)
    .where("ownerId", "==", uid)
    .where("status", "==", "active")
    .orderBy("createdAt", "desc")
    .limit(100)
    .get();
  const tasks: Task[] = [];
  for (const doc of snapshot.docs) {
    const parsed = TaskSchema.safeParse(doc.data());
    if (parsed.success) {
      tasks.push(parsed.data);
    }
  }
  return tasks;
}

/** Newest non-superseded goal/context memories, capped at 5. */
async function loadCarriedMemories(uid: string): Promise<Memory[]> {
  const snapshot = await db()
    .collection(COLLECTIONS.memories)
    .where("ownerId", "==", uid)
    .where("category", "in", ["goal", "context"])
    .orderBy("createdAt", "desc")
    .limit(15)
    .get();
  return snapshot.docs
    .map((doc) => parseMemoryDoc(doc.data()))
    .filter((doc): doc is NonNullable<typeof doc> => doc !== null)
    .map((doc) => doc.memory)
    .filter((memory) => memory.supersededBy === undefined)
    .slice(0, 5);
}

/**
 * Assembles the context. Weather, Firestore reads, and yesterday's summary
 * run in parallel; every source degrades to empty rather than failing the
 * brief.
 */
export async function gatherBriefContext(
  uid: string,
  request: BriefRequest,
  now: Date,
): Promise<BriefContext> {
  const today = wallDate(now, request.timezone);
  const yesterday = wallDate(new Date(now.getTime() - 24 * 3600 * 1000), request.timezone);

  const [weather, tasks, planContext, carried, yesterdaySummary] = await Promise.all([
    cachedCurrentWeather(request.lat ?? DEFAULT_LAT, request.lon ?? DEFAULT_LON),
    loadActiveTasks(uid).catch((err: unknown): Task[] => {
      logWarning("brief_tasks_failed", { userId: uid, ...errorFields(err) });
      return [];
    }),
    loadPlanContext(uid, now, request.timezone),
    loadCarriedMemories(uid).catch((err: unknown): Memory[] => {
      logWarning("brief_memories_failed", { userId: uid, ...errorFields(err) });
      return [];
    }),
    loadBriefSummary(uid, yesterday).catch((): null => null),
  ]);

  return {
    date: today,
    weather,
    request,
    dueTasks: dueToday(tasks, now, request.timezone),
    lists: listCounts(tasks),
    planSessions: planContext.planSessions,
    hasActivePlans: planContext.hasActivePlans,
    carried,
    yesterdaySummary,
  };
}
