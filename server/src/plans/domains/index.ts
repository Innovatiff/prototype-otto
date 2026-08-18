/**
 * Per-domain generation guidance, injected into the generation prompt. One
 * block per generation — quality lives here: if plans read generic, these
 * templates need work, not the machinery.
 */
import type { PlanDomain } from "../interview.js";
import { FITNESS_GUIDANCE } from "./fitness.js";
import { LEARNING_GUIDANCE } from "./learning.js";
import { PRODUCTIVITY_GUIDANCE } from "./productivity.js";

const GUIDANCE: Record<PlanDomain, string> = {
  fitness: FITNESS_GUIDANCE,
  productivity: PRODUCTIVITY_GUIDANCE,
  learning: LEARNING_GUIDANCE,
};

export function domainGuidance(domain: PlanDomain): string {
  return GUIDANCE[domain];
}
