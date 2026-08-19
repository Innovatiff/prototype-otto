/**
 * POST /calendar/sync — the device's compressed 48-hour view arrives.
 *
 * Three things happen, in order: the payload is clamped to the promised
 * window and stored (whole-view replace, one doc per user), the device's
 * IANA zone re-anchors any automation whose stored zone drifted, and
 * relative_to_event automations are re-armed against the fresh events.
 * The response reports both counts so the client can log honestly.
 */
import { CalendarSyncRequest, type CalendarSyncResponse } from "@otto/shared";
import { Router, type NextFunction, type Request, type Response } from "express";

import { clampToWindow, storeCalendarView } from "../automations/calendarView.js";
import { rearmUpdates } from "../automations/rearm.js";
import { isValidTimezone } from "../automations/schedule.js";
import { loadOwnerAutomations, updateAutomationScheduling } from "../automations/store.js";
import { AppError, parseOrThrow } from "../errors.js";
import { errorFields, logError, logInfo } from "../log.js";
import { requireUid } from "../middleware/auth.js";

export const calendarRouter = Router();

calendarRouter.post(
  "/sync",
  async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    try {
      const uid = requireUid(req);
      const request = parseOrThrow(CalendarSyncRequest, req.body, "calendar sync request");
      if (!isValidTimezone(request.timezone)) {
        throw new AppError(400, "invalid_request", "Unknown timezone.");
      }
      const now = new Date();
      const events = clampToWindow(request.events, now);
      await storeCalendarView(uid, events, request.timezone, now);

      const automations = await loadOwnerAutomations(uid);
      const updates = rearmUpdates(automations, request.timezone, events, now);
      let rearmed = 0;
      for (const update of updates) {
        try {
          await updateAutomationScheduling(update.id, update.fields);
          rearmed += 1;
        } catch (err) {
          // A single bad automation must not fail the whole sync.
          logError("automation_rearm_failed", { automationId: update.id, ...errorFields(err) });
        }
      }

      logInfo("calendar_synced", {
        userId: uid,
        stored: events.length,
        rearmed,
        timezone: request.timezone,
      });
      const body: CalendarSyncResponse = { stored: events.length, rearmed };
      res.json(body);
    } catch (err) {
      next(err);
    }
  },
);
