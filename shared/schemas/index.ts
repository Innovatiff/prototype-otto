/**
 * Otto shared schemas — the single source of truth.
 *
 * Everything downstream (the TypeScript server and, via codegen, the Swift
 * iOS models) derives from these Zod definitions. Change a schema here and
 * re-run `npm run codegen`; never hand-edit generated Swift.
 */
export * from "./automation.js";
export * from "./brief.js";
export * from "./calendar.js";
export * from "./common.js";
export * from "./experience.js";
export * from "./task.js";
export * from "./memory.js";
export * from "./plan.js";
export * from "./session.js";
export * from "./stage.js";
export * from "./turn.js";
export * from "./user.js";
export * from "./weather.js";
