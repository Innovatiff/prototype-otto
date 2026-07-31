/**
 * Secrets access.
 *
 * Production reads from Google Secret Manager once at cold start and caches in
 * memory — never from .env or process.env. Development (gated on NODE_ENV)
 * falls back to process.env so local runs need no GCP access.
 *
 * Phase 0 requires no secrets (LLM calls are stubbed; Firestore uses ADC), so
 * every known secret is optional at load time: `getSecret` throws only when an
 * absent secret is actually needed.
 */
import { SecretManagerServiceClient } from "@google-cloud/secret-manager";

import { AppError } from "../errors.js";
import { errorFields, logInfo, logWarning } from "../log.js";

/** Every secret this service may read. */
export const KNOWN_SECRETS = ["ANTHROPIC_API_KEY", "VOYAGE_API_KEY"] as const;
export type SecretName = (typeof KNOWN_SECRETS)[number];

const cache = new Map<SecretName, string>();
let loaded = false;

function isProduction(): boolean {
  return process.env.NODE_ENV === "production";
}

/** Loads every known secret once at cold start. Idempotent. */
export async function loadSecrets(): Promise<void> {
  if (loaded) {
    return;
  }

  if (!isProduction()) {
    for (const name of KNOWN_SECRETS) {
      const value = process.env[name];
      if (value !== undefined && value.length > 0) {
        cache.set(name, value);
      }
    }
    loaded = true;
    logInfo("secrets_loaded", { source: "process.env", count: cache.size });
    return;
  }

  try {
    const client = new SecretManagerServiceClient();
    const projectId = await client.getProjectId();
    await Promise.all(
      KNOWN_SECRETS.map(async (name) => {
        try {
          const [version] = await client.accessSecretVersion({
            name: `projects/${projectId}/secrets/${name}/versions/latest`,
          });
          const data = version.payload?.data;
          if (data === undefined || data === null) {
            return;
          }
          const value = typeof data === "string" ? data : Buffer.from(data).toString("utf8");
          if (value.length > 0) {
            cache.set(name, value);
          }
        } catch (err) {
          // Tolerated in Phase 0: nothing requires a secret yet. Never log values.
          logWarning("secret_unavailable", { secret: name, ...errorFields(err) });
        }
      }),
    );
  } catch (err) {
    // Secret Manager itself unreachable. Phase 0 requires no secrets, so a
    // cold-start crash loop would be strictly worse than starting degraded;
    // getSecret still fails loudly if an absent secret is actually needed.
    logWarning("secret_manager_unreachable", errorFields(err));
  }
  loaded = true;
  logInfo("secrets_loaded", { source: "secret-manager", count: cache.size });
}

/** A previously loaded secret. Throws a typed 500 if it was not available. */
export function getSecret(name: SecretName): string {
  const value = cache.get(name);
  if (value === undefined) {
    throw new AppError(500, "internal", `Secret ${name} is not configured.`);
  }
  return value;
}
