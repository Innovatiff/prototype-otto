/**
 * The constraints interview — what Otto asks before generating a plan.
 *
 * The interview happens conversationally through the normal turn loop: the
 * guidance below rides in the prompt, the model asks by voice one question
 * at a time, session memory carries the answers, and generation (Step 2)
 * receives them as a validated PlanConstraints object via tool input.
 *
 * Get this wrong in either direction and the product suffers: too few
 * questions produces generic plans, too many feels like a form.
 */
import { z } from "zod";

export const PlanDomain = z.enum(["fitness", "productivity", "learning"]);
export type PlanDomain = z.infer<typeof PlanDomain>;

/**
 * Everything generation may know about the user's situation. domain and
 * goal are mandatory; the rest is filled from the interview and from
 * memories. Stored verbatim on the Plan (constraints field).
 */
export const PlanConstraints = z.object({
  domain: PlanDomain,
  goal: z.string().min(1).max(500),
  /** Plan horizon; the generator defaults sensibly per domain if absent. */
  horizonDays: z.number().int().min(7).max(180).optional(),

  // fitness
  daysPerWeek: z.number().int().min(1).max(7).optional(),
  minutesPerSession: z.number().int().min(10).max(240).optional(),
  equipment: z.array(z.string().min(1)).max(20).optional(),
  limitations: z.array(z.string().min(1)).max(20).optional(),
  experienceLevel: z.string().max(200).optional(),

  // productivity
  workType: z.string().max(300).optional(),
  peakHours: z.string().max(200).optional(),
  fixedCommitments: z.array(z.string().min(1)).max(30).optional(),
  monthGoal: z.string().max(500).optional(),

  // learning
  currentLevel: z.string().max(300).optional(),
  minutesPerDay: z.number().int().min(5).max(600).optional(),
  targetDate: z.string().max(100).optional(),
  motivation: z.string().max(500).optional(),

  notes: z.string().max(1000).optional(),
});
export type PlanConstraints = z.infer<typeof PlanConstraints>;

/**
 * The interview rules, injected into the prompt. Kept static (cacheable)
 * and domain menus included inline — the model picks the menu that matches
 * the request.
 */
export const INTERVIEW_GUIDANCE = `PLAN INTERVIEWS
When they ask for a plan (workout program, weekly structure, study plan),
interview BEFORE generating. Rules:
- At most 4 questions. Usually 3. One question per turn, spoken naturally —
  never a form, never a numbered list.
- NEVER ask anything your MEMORIES or context already answer. Confirm
  instead: "Still working around the left shoulder?" counts as one question.
- Only ask what MATERIALLY changes the plan. Skip nice-to-know.
- Then generate. Do not re-summarize their answers back first.

Question menus by domain (pick the material ones, never all):
- fitness: days per week available · equipment access · injuries or
  limitations · experience level
- productivity: work type · when they're sharpest · fixed commitments ·
  what they're trying to accomplish this month
- learning: current level · minutes per day · target date if any · why
  they're learning it (this changes the whole approach)`;
