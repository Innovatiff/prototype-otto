/**
 * Structured logging.
 *
 * One JSON object per line on stdout/stderr. Cloud Run ingests these natively:
 * `severity` and `message` are the fields Cloud Logging understands, and every
 * other key lands in jsonPayload for filtering.
 */

type LogFields = Record<string, unknown>;

function emit(severity: "INFO" | "WARNING" | "ERROR", message: string, fields: LogFields): void {
  const line = JSON.stringify({ severity, message, ...fields });
  if (severity === "ERROR") {
    process.stderr.write(`${line}\n`);
  } else {
    process.stdout.write(`${line}\n`);
  }
}

export function logInfo(message: string, fields: LogFields = {}): void {
  emit("INFO", message, fields);
}

export function logWarning(message: string, fields: LogFields = {}): void {
  emit("WARNING", message, fields);
}

export function logError(message: string, fields: LogFields = {}): void {
  emit("ERROR", message, fields);
}

/** Serializes an unknown thrown value into loggable fields. Never throws. */
export function errorFields(err: unknown): LogFields {
  if (err instanceof Error) {
    return { errorName: err.name, errorMessage: err.message, stack: err.stack };
  }
  return { errorValue: String(err) };
}
