/**
 * What a calendar sync does to the owner's automations.
 *
 * Two signals arrive with every sync: fresh events (which re-arm
 * relative_to_event schedules) and the device's current IANA zone (which
 * re-anchors EVERYTHING when it changed — landing in Tokyo moves the 07:00
 * brief to Tokyo's 07:00 on the next sync, no app-open required beyond the
 * sync itself).
 *
 * Pure: takes the automations and returns targeted field updates; the
 * route applies them. Locks and counters are untouched by construction.
 */
import type { Automation, CalendarSyncEvent } from "@otto/shared";

import { isValidTimezone, nextRunAt } from "./schedule.js";

export interface RearmUpdate {
  readonly id: string;
  readonly fields: {
    readonly timezone?: string;
    readonly nextRunAt?: string | null;
  };
}

export function rearmUpdates(
  automations: readonly Automation[],
  deviceTimezone: string,
  events: readonly CalendarSyncEvent[],
  now: Date,
): RearmUpdate[] {
  const tzUsable = isValidTimezone(deviceTimezone);
  const updates: RearmUpdate[] = [];

  for (const automation of automations) {
    const tzChanged = tzUsable && automation.timezone !== deviceTimezone;
    const timezone = tzChanged ? deviceTimezone : automation.timezone;

    if (!automation.enabled) {
      // A disabled automation stays parked (nextRunAt null), but its zone
      // keeps up so a later enable starts from the right one.
      if (tzChanged) {
        updates.push({ id: automation.id, fields: { timezone } });
      }
      continue;
    }

    // A due-but-not-yet-run nextRunAt belongs to the tick. A foreground
    // sync often lands moments before a meeting's prep fires — recomputing
    // here would move the fire past the pending one and silently kill it.
    const currentIso = automation.nextRunAt ?? null;
    if (currentIso !== null && currentIso <= now.toISOString()) {
      if (tzChanged) {
        updates.push({ id: automation.id, fields: { timezone } });
      }
      continue;
    }

    if (automation.schedule.kind === "fixed") {
      // Rule-driven schedules only move when the zone does.
      if (tzChanged) {
        const next = nextRunAt(automation.schedule, timezone, now);
        updates.push({
          id: automation.id,
          fields: { timezone, nextRunAt: next === null ? null : next.toISOString() },
        });
      }
      continue;
    }

    const next = nextRunAt(automation.schedule, timezone, now, events);
    const nextIso = next === null ? null : next.toISOString();
    if (tzChanged || nextIso !== currentIso) {
      updates.push({
        id: automation.id,
        fields: tzChanged ? { timezone, nextRunAt: nextIso } : { nextRunAt: nextIso },
      });
    }
  }

  return updates;
}
