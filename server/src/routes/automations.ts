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
import { Router, type NextFunction, type Request, type Response } from "express";
import { OAuth2Client, type TokenPayload } from "google-auth-library";

import { loadCalendarView, purgeExpiredViews } from "../automations/calendarView.js";
import { executeAutomation } from "../automations/handlers.js";
import { runTick } from "../automations/tick.js";
import {
  claimAutomation,
  completeAutomationRun,
  loadDueAutomations,
} from "../automations/store.js";
import { AppError } from "../errors.js";

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
      });
      res.json({ ok: true, ...summary });
    } catch (err) {
      next(err);
    }
  },
);
