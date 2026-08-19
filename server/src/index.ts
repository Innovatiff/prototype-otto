/**
 * Otto API entrypoint.
 *
 * /healthz is unauthenticated (load-balancer health checks); every other route
 * sits behind requireAuth. Secrets load once at cold start. PORT comes from
 * the environment (Cloud Run injects it).
 */
import express, { type Request, type Response } from "express";

import { errorBody, errorMiddleware } from "./errors.js";
import { errorFields, logError, logInfo } from "./log.js";
import { requireAuth } from "./middleware/auth.js";
import { automationsTickRouter } from "./routes/automations.js";
import { briefRouter } from "./routes/brief.js";
import { converseRouter } from "./routes/converse.js";
import { memoryRouter } from "./routes/memory.js";
import { plansRouter } from "./routes/plans.js";
import { tasksRouter } from "./routes/tasks.js";
import { loadSecrets } from "./secrets/index.js";

export const app = express();
app.disable("x-powered-by");
app.use(express.json({ limit: "1mb" }));

app.get("/healthz", (_req: Request, res: Response): void => {
  res.json({ ok: true });
});

app.use("/converse", requireAuth, converseRouter);
app.use("/brief", requireAuth, briefRouter);
app.use("/tasks", requireAuth, tasksRouter);
app.use("/memory", requireAuth, memoryRouter);
app.use("/plans", requireAuth, plansRouter);
// Deliberately NOT behind requireAuth: /automations/tick authenticates the
// Cloud Scheduler's OIDC token itself. User-facing automation routes must go
// in a separate router mounted with requireAuth.
app.use("/automations", automationsTickRouter);

// JSON 404 for anything unmatched, then the typed error handler — order matters.
app.use((_req: Request, res: Response): void => {
  res.status(404).json(errorBody("not_found", "No such route."));
});
app.use(errorMiddleware);

const port = Number(process.env.PORT ?? 8080);

async function main(): Promise<void> {
  await loadSecrets();
  const server = app.listen(port, () => {
    logInfo("server_started", { port, nodeEnv: process.env.NODE_ENV ?? "development" });
  });
  // Cloud Run sends SIGTERM before shutdown; stop accepting connections and
  // let in-flight requests (including open SSE streams) drain.
  process.on("SIGTERM", () => {
    logInfo("sigterm_received");
    server.close(() => {
      process.exit(0);
    });
  });
}

main().catch((err: unknown) => {
  logError("startup_failed", errorFields(err));
  process.exit(1);
});
