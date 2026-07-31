import { z } from "zod";
import { isoDateTime, zId } from "./common.js";

/**
 * The owner's profile — one document per user, doc id = uid.
 *
 * addressTerm is how Otto addresses them: "Boss" (default), "Sir", "Ma'am",
 * "Chief", a first name, or "none" for no term of address at all. Free-form
 * string rather than an enum so a first name needs no schema change; "none"
 * is the one special value.
 */
export const UserProfile = z.object({
  ownerId: zId,
  addressTerm: z.string().min(1).max(40).default("Boss"),
  createdAt: isoDateTime,
});
export type UserProfile = z.infer<typeof UserProfile>;
