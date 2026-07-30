import { z } from "zod";

/**
 * Shared, reusable Zod primitives.
 *
 * These exist so the codegen (shared/codegen/swift.ts) can detect intent
 * uniformly:
 *   - `isoDateTime` is a `z.string().datetime()` and is emitted as Swift `Date`
 *     via a shared ISO-8601 coding strategy.
 *   - `zId` is a non-empty string used for all document / entity identifiers.
 */

/** A non-empty identifier string (document id, entity id, etc.). */
export const zId = z.string().min(1);

/**
 * An ISO-8601 datetime string.
 *
 * `offset: true` accepts both `...Z` (UTC) and explicit offsets like
 * `2026-07-30T10:00:00-04:00`, which is what iOS clients will send.
 * The Swift codegen maps any string carrying this `datetime` check to `Date`.
 */
export const isoDateTime = z.string().datetime({ offset: true });
