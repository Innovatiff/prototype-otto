/**
 * Typed errors for every route.
 *
 * Handlers throw AppError (or let Zod failures surface through parseOrThrow);
 * the error middleware below turns them into a stable JSON body. Raw exception
 * text never reaches a client.
 */
import type { NextFunction, Request, Response } from "express";
import { z } from "zod";

import { errorFields, logError, logWarning } from "./log.js";

export type ErrorCode = "unauthenticated" | "invalid_request" | "not_found" | "internal";

export interface ErrorBody {
  error: {
    code: ErrorCode;
    message: string;
    details?: unknown;
  };
}

export function errorBody(code: ErrorCode, message: string, details?: unknown): ErrorBody {
  return details === undefined ? { error: { code, message } } : { error: { code, message, details } };
}

export class AppError extends Error {
  readonly status: number;
  readonly code: ErrorCode;
  readonly details: unknown;

  constructor(status: number, code: ErrorCode, message: string, details?: unknown) {
    super(message);
    this.name = "AppError";
    this.status = status;
    this.code = code;
    this.details = details;
  }
}

/** A Firestore document id: non-empty, no path separators. */
export const IdParam = z
  .string()
  .min(1)
  .max(1500)
  .refine((value) => !value.includes("/"), { message: "must not contain '/'" });

/**
 * Parses `value` against a Zod schema or throws a 400 AppError whose details
 * carry the flattened issues — never the raw ZodError.
 */
export function parseOrThrow<Output, Input>(
  schema: z.ZodType<Output, z.ZodTypeDef, Input>,
  value: unknown,
  what: string,
): Output {
  const result = schema.safeParse(value);
  if (!result.success) {
    const issues = result.error.issues.map((issue) => ({
      path: issue.path.join("."),
      message: issue.message,
    }));
    throw new AppError(400, "invalid_request", `Invalid ${what}.`, issues);
  }
  return result.data;
}

/** Reads an http-shaped `status` off an unknown error (body-parser sets one). */
function httpStatusOf(err: unknown): number | null {
  if (typeof err === "object" && err !== null && "status" in err) {
    const status = err.status;
    if (typeof status === "number" && Number.isInteger(status)) {
      return status;
    }
  }
  return null;
}

/**
 * Final error handler. Must be registered last, and must keep the 4-arg
 * signature so Express treats it as an error middleware.
 */
export function errorMiddleware(err: unknown, req: Request, res: Response, _next: NextFunction): void {
  if (res.headersSent) {
    // Mid-stream failure (SSE): the status line is gone; just close and log.
    logError("error_after_headers_sent", { path: req.path, ...errorFields(err) });
    res.end();
    return;
  }

  if (err instanceof AppError) {
    if (err.status >= 500) {
      logError("app_error", { path: req.path, status: err.status, code: err.code, message: err.message });
    } else {
      logWarning("request_rejected", { path: req.path, status: err.status, code: err.code });
    }
    res.status(err.status).json(errorBody(err.code, err.message, err.details));
    return;
  }

  // body-parser failures (malformed JSON, oversized body) carry a 4xx status.
  const status = httpStatusOf(err);
  if (status !== null && status >= 400 && status < 500) {
    logWarning("request_rejected", { path: req.path, status });
    const message = status === 413 ? "Request body too large." : "Malformed request body.";
    res.status(status).json(errorBody("invalid_request", message));
    return;
  }

  logError("unhandled_error", { path: req.path, ...errorFields(err) });
  res.status(500).json(errorBody("internal", "Internal server error."));
}
