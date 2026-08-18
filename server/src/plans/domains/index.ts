/**
 * Per-domain generation guidance, injected into the generation prompt.
 *
 * Step 3 replaces these with the real expertise blocks (fitness.ts,
 * productivity.ts, learning.ts); these placeholders only keep Step 2's
 * machinery honest in the meantime.
 */
import type { PlanDomain } from "../interview.js";

const PLACEHOLDERS: Record<PlanDomain, string> = {
  fitness:
    "DOMAIN GUIDANCE (fitness)\n" +
    "Respect stated equipment and session length absolutely. Progress load " +
    "via schedule progression overrides, conservatively.",
  productivity:
    "DOMAIN GUIDANCE (productivity)\n" +
    "Structure full days. Respect fixed commitments exactly as given.",
  learning:
    "DOMAIN GUIDANCE (learning)\n" +
    "Interleave new material with review. Weekly checkpoints test recall.",
};

export function domainGuidance(domain: PlanDomain): string {
  return PLACEHOLDERS[domain];
}
