/**
 * POST /automations/tick — the Cloud Scheduler entrypoint.
 *
 * The Cloud Run service allows unauthenticated invocations (user routes
 * verify Firebase ID tokens at the app layer), so this route does its own
 * gatekeeping: the bearer must be a Google-signed OIDC ID token whose
 * audience matches SCHEDULER_AUDIENCE and whose verified email is exactly
 * SCHEDULER_INVOKER — the invoker service account deploy.sh creates. With
 * either env var unset the route fails closed (503): a tick that cannot
 * prove its caller never runs.
 *
 * This router is mounted WITHOUT requireAuth. Only scheduler-verified
 * routes belong here; the user-facing automation routes (Step 7) go in
 * their own router behind requireAuth.
 */
import {
  AutomationSettingsRequest,
  AutomationUpdateRequest,
  DeliveryResponseRequest,
  DeviceTokenRequest,
  type AutomationListResponse,
} from "@otto/shared";
import { Router, type NextFunction, type Request, type Response } from "express";
import { OAuth2Client, type TokenPayload } from "google-auth-library";

import { loadCalendarView, purgeExpiredViews } from "../automations/calendarView.js";
import {
  deliveryResponseUpdate,
  loadOwnedDelivery,
  loadOwnerDeliveries,
  loadRecentDeliveries,
  openTimeSuggestion,
  storeDeliverer,
  updateDelivery,
} from "../automations/deliver.js";
import { executeAutomation } from "../automations/handlers.js";
import { runTick } from "../automations/tick.js";
import { applyAutomationUpdate, sortForManagement } from "../automations/custom.js";
import { ensureBuiltInAutomations } from "../automations/defaults.js";
import { isValidTimezone } from "../automations/schedule.js";
import {
  applyManagementUpdate,
  claimAutomation,
  completeAutomationRun,
  deleteAutomationDoc,
  loadDueAutomations,
  loadOwnerAutomations,
  loadOwnerQuietHours,
  readOwnedAutomation,
  syncCustomAutomationCount,
  updateAutomationScheduling,
  updateOwnerQuietHours,
} from "../automations/store.js";
import { AppError, IdParam, parseOrThrow } from "../errors.js";
import { errorFields, logError, logInfo } from "../log.js";
import { requireUid } from "../middleware/auth.js";
import { tierFromProfile } from "../entitlements/index.js";
import { loadUserProfile } from "../users/index.js";
import { registerDeviceToken } from "../automations/push.js";

export interface SchedulerConfig {
  readonly invoker: string;
  readonly audience: string;
}

/** Both env vars, or null — never a half-configured guard. */
export function schedulerConfig(env: NodeJS.ProcessEnv = process.env): SchedulerConfig | null {
  const invoker = env["SCHEDULER_INVOKER"];
  const audience = env["SCHEDULER_AUDIENCE"];
  if (invoker === undefined || invoker.length === 0) {
    return null;
  }
  if (audience === undefined || audience.length === 0) {
    return null;
  }
  return { invoker, audience };
}

/**
 * Whether a verified token's claims belong to the configured invoker.
 * Signature, expiry, and audience are the verifier's job; identity is
 * checked here — and only a VERIFIED email counts as identity.
 */
export function isAuthorizedInvoker(
  payload: TokenPayload | undefined,
  config: SchedulerConfig,
): boolean {
  if (payload === undefined) {
    return false;
  }
  return payload.email_verified === true && payload.email === config.invoker;
}

let oidcClient: OAuth2Client | null = null;

function verifier(): OAuth2Client {
  oidcClient ??= new OAuth2Client();
  return oidcClient;
}

async function requireScheduler(req: Request, _res: Response, next: NextFunction): Promise<void> {
  const config = schedulerConfig();
  if (config === null) {
    next(new AppError(503, "internal", "Scheduler is not configured."));
    return;
  }
  const header = req.header("authorization") ?? "";
  const token = header.toLowerCase().startsWith("bearer ") ? header.slice(7).trim() : "";
  if (token.length === 0) {
    next(new AppError(401, "unauthenticated", "Missing bearer token."));
    return;
  }
  try {
    const ticket = await verifier().verifyIdToken({ idToken: token, audience: config.audience });
    if (!isAuthorizedInvoker(ticket.getPayload(), config)) {
      next(new AppError(401, "unauthenticated", "Caller is not the scheduler invoker."));
      return;
    }
    next();
  } catch {
    // Never echo verification internals back — same posture as requireAuth.
    next(new AppError(401, "unauthenticated", "Invalid scheduler token."));
  }
}

export const automationsTickRouter = Router();

/**
 * The user-facing half: device registration and push responses. Mounted
 * BEHIND requireAuth in index.ts — never on the tick router above.
 */
export const automationsUserRouter = Router();

/** How far a Snooze pushes the automation's next fire. */
export const SNOOZE_MINUTES = 30;

automationsUserRouter.get(
  "/",
  async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    try {
      const uid = requireUid(req);
      const [automations, quiet, deliveries] = await Promise.all([
        loadOwnerAutomations(uid),
        loadOwnerQuietHours(uid),
        loadOwnerDeliveries(uid, 120).catch((): [] => []),
      ]);
      const now = new Date();
      // The engagement log, read positively: fixed automations whose opens
      // consistently trail their fire time get a one-tap move suggestion.
      const suggestions = automations
        .filter((automation) => automation.enabled)
        .map((automation) => openTimeSuggestion(automation, deliveries, now))
        .filter((suggestion): suggestion is NonNullable<typeof suggestion> => suggestion !== null)
        .slice(0, 10);
      const body: AutomationListResponse = {
        automations: sortForManagement(automations).slice(0, 100),
        quietHoursStart: quiet.start,
        quietHoursEnd: quiet.end,
        ...(suggestions.length > 0 ? { suggestions } : {}),
      };
      res.json(body);
    } catch (err) {
      next(err);
    }
  },
);

automationsUserRouter.post(
  "/:id/update",
  async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    try {
      const uid = requireUid(req);
      const id = parseOrThrow(IdParam, req.params.id, "automation id");
      const request = parseOrThrow(AutomationUpdateRequest, req.body, "automation update");
      const automation = await readOwnedAutomation(id, uid);
      if (automation === null) {
        throw new AppError(404, "not_found", "No such automation.");
      }
      const outcome = applyAutomationUpdate(automation, request, new Date());
      if (!outcome.ok) {
        throw new AppError(400, "invalid_request", outcome.error);
      }
      await applyManagementUpdate(id, outcome.fields);
      logInfo("automation_updated", {
        userId: uid,
        automationId: id,
        enabled: request.enabled ?? null,
        retimed: request.timeOfDay !== undefined,
      });
      res.json({ ok: true });
    } catch (err) {
      next(err);
    }
  },
);

automationsUserRouter.delete(
  "/:id",
  async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    try {
      const uid = requireUid(req);
      const id = parseOrThrow(IdParam, req.params.id, "automation id");
      const automation = await readOwnedAutomation(id, uid);
      if (automation === null) {
        throw new AppError(404, "not_found", "No such automation.");
      }
      if (automation.type !== "custom") {
        throw new AppError(400, "invalid_request", "Built-in automations can be disabled, not deleted.");
      }
      await deleteAutomationDoc(id);
      await syncCustomAutomationCount(uid).catch(() => 0);
      logInfo("automation_deleted", { userId: uid, automationId: id });
      res.json({ ok: true });
    } catch (err) {
      next(err);
    }
  },
);

automationsUserRouter.post(
  "/settings",
  async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    try {
      const uid = requireUid(req);
      const request = parseOrThrow(AutomationSettingsRequest, req.body, "automation settings");
      if (request.quietHoursStart === undefined && request.quietHoursEnd === undefined) {
        throw new AppError(400, "invalid_request", "Nothing to update.");
      }
      await updateOwnerQuietHours(uid, request);
      logInfo("quiet_hours_updated", { userId: uid });
      res.json({ ok: true });
    } catch (err) {
      next(err);
    }
  },
);

automationsUserRouter.post(
  "/devices",
  async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    try {
      const uid = requireUid(req);
      const request = parseOrThrow(DeviceTokenRequest, req.body, "device token request");
      const count = await registerDeviceToken(uid, request.token);
      // Registration is the moment pushes become deliverable — seed the
      // built-ins here so a user who never enables calendar sync still
      // gets their brief. Idempotent; failure never fails registration.
      if (request.timezone !== undefined && isValidTimezone(request.timezone)) {
        try {
          const existing = await loadOwnerAutomations(uid);
          await ensureBuiltInAutomations(existing, uid, request.timezone, new Date());
        } catch (err) {
          logError("built_in_seed_failed", { userId: uid, ...errorFields(err) });
        }
      }
      logInfo("device_token_registered", { userId: uid, deviceCount: count });
      res.json({ ok: true, devices: count });
    } catch (err) {
      next(err);
    }
  },
);

automationsUserRouter.post(
  "/response",
  async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    try {
      const uid = requireUid(req);
      const request = parseOrThrow(DeliveryResponseRequest, req.body, "delivery response");
      const delivery = await loadOwnedDelivery(request.deliveryId, uid);
      if (delivery === null) {
        throw new AppError(404, "not_found", "No such delivery.");
      }
      const now = new Date();
      const fields = deliveryResponseUpdate(delivery, request.action, now);
      if (fields !== null) {
        await updateDelivery(delivery.id, fields);
      }
      if (request.action === "snoozed") {
        // Re-fire the automation shortly; the handler regenerates with
        // FRESH data rather than replaying a stale body. Only a LIVE
        // automation re-arms: one deleted or disabled since the push must
        // not gain a nextRunAt it can never act on (a permanently-due
        // disabled doc would squat in the tick's due page forever).
        const target = await readOwnedAutomation(delivery.automationId, uid);
        if (target !== null && target.enabled) {
          const snoozeUntil = new Date(now.getTime() + SNOOZE_MINUTES * 60_000);
          await updateAutomationScheduling(delivery.automationId, {
            nextRunAt: snoozeUntil.toISOString(),
          }).catch(() => {});
        }
      }
      logInfo("delivery_response", {
        userId: uid,
        deliveryId: delivery.id,
        automationId: delivery.automationId,
        action: request.action,
      });
      res.json({ ok: true });
    } catch (err) {
      next(err);
    }
  },
);

automationsTickRouter.post(
  "/tick",
  requireScheduler,
  async (_req: Request, res: Response, next: NextFunction): Promise<void> => {
    try {
      const summary = await runTick({
        now: () => new Date(),
        loadDue: loadDueAutomations,
        claim: claimAutomation,
        complete: completeAutomationRun,
        execute: (automation, ctx) => executeAutomation(automation, ctx),
        loadView: loadCalendarView,
        purgeViews: purgeExpiredViews,
        loadQuietHours: loadOwnerQuietHours,
        loadOwnerGate: async (ownerId) => {
          // Own tier only here: seat members' Pro automations are a known
          // v1 limitation (the tick has no email to resolve seats with).
          const profile = await loadUserProfile(ownerId, new Date());
          return {
            tier: tierFromProfile(profile, new Date()),
            hasConsent: profile.aiConsentVersion !== undefined,
          };
        },
        loadOwnerDeliveries: (ownerId) => loadOwnerDeliveries(ownerId),
        // 15 leaves headroom: the streak needs five COUNTABLE sends among
        // these after fresh and never-sent records are filtered out.
        loadAutomationDeliveries: (ownerId, automationId) =>
          loadRecentDeliveries(ownerId, automationId, 15),
        notify: (uid, automation, delivery) => storeDeliverer(uid, automation, delivery),
        disable: (id) => updateAutomationScheduling(id, { enabled: false, nextRunAt: null }),
      });
      res.json({ ok: true, ...summary });
    } catch (err) {
      next(err);
    }
  },
);
