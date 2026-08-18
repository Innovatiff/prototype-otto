/**
 * Zod -> Swift Codable generator.
 *
 * Reads the authoritative schemas in shared/schemas/ and emits Swift models into
 * ios/Otto/Models/. Run with `npm run codegen` from the repo root.
 *
 * Nothing in ios/Otto/Models/ should ever be hand-edited: change a Zod schema
 * and regenerate.
 *
 * DESIGN NOTES (the non-obvious constraints this generator satisfies)
 *
 * - Output must compile under Swift 6 / iOS 26 with ZERO warnings. The container
 *   throwing/mutating asymmetries below are load-bearing:
 *       let container = try decoder.container(keyedBy:)   // throws; decode is non-mutating
 *       var container = encoder.container(keyedBy:)       // does NOT throw; encode is mutating
 *   Adding `try` to a non-throwing call, or using `let` for the encoder container,
 *   produces exactly the warnings/errors the acceptance criterion forbids.
 *
 * - Existentials are spelled `any Decoder` / `any Encoder` (required in Swift 6).
 *
 * - `Task` is renamed `OttoTask`. A module-scope `struct Task` shadows Swift
 *   Concurrency's `Task`, which would break every `Task { await ... }` in the app.
 *   Wire keys and the source file name are unaffected. See RESERVED_TYPE_NAMES.
 *
 * - Enum cases that would be named `none` are renamed (`no<TypeName>`), keeping the
 *   wire string. A type with its own `.none` case makes any bare `.none` in an
 *   optional position resolve silently to `Optional.none` — a warning whose default
 *   resolution is the wrong one.
 *
 * - Zod `.optional()` REJECTS an explicit JSON null, so optional fields must encode
 *   with `encodeIfPresent` (omit the key), never `encode` (which writes null).
 *
 * - A Zod `.default(v)` field is NOT decode-tolerant just because the Swift property
 *   has an initializer: Swift's synthesized decoder calls `decode`, not
 *   `decodeIfPresent`, and throws on a missing key. Defaults therefore live in the
 *   generated `init(from:)` as `decodeIfPresent(...) ?? v`, and in the memberwise
 *   init's parameter list — never as an inline property initializer, which would
 *   claim a tolerance that does not exist.
 *
 * - `z.unknown()` accepts a missing key WITHOUT a ZodOptional wrapper, so such
 *   fields are emitted as Swift optionals. Missing this makes every TurnEvent
 *   without a `data` field (`done`, `error`) fail to decode at runtime.
 */
import * as fs from "node:fs";
import * as path from "node:path";
import * as url from "node:url";
import { z } from "zod";

import * as calendarSchemas from "../schemas/calendar.js";
import * as taskSchemas from "../schemas/task.js";
import * as memorySchemas from "../schemas/memory.js";
import * as planSchemas from "../schemas/plan.js";
import * as sessionSchemas from "../schemas/session.js";
import * as turnSchemas from "../schemas/turn.js";
import * as userSchemas from "../schemas/user.js";

// ─────────────────────────────────────────────────────────────────────
// Configuration
// ─────────────────────────────────────────────────────────────────────

interface ModuleSpec {
  /** Emitted Swift file basename. */
  readonly swiftFile: string;
  /** Repo-relative schema path, recorded in the generated header. */
  readonly source: string;
  readonly schemas: Readonly<Record<string, unknown>>;
}

const MODULES: readonly ModuleSpec[] = [
  { swiftFile: "Calendar", source: "shared/schemas/calendar.ts", schemas: calendarSchemas },
  { swiftFile: "Task", source: "shared/schemas/task.ts", schemas: taskSchemas },
  { swiftFile: "Memory", source: "shared/schemas/memory.ts", schemas: memorySchemas },
  { swiftFile: "Plan", source: "shared/schemas/plan.ts", schemas: planSchemas },
  { swiftFile: "Session", source: "shared/schemas/session.ts", schemas: sessionSchemas },
  { swiftFile: "Turn", source: "shared/schemas/turn.ts", schemas: turnSchemas },
  { swiftFile: "User", source: "shared/schemas/user.ts", schemas: userSchemas },
];

/**
 * Schema names that must not become Swift type names verbatim.
 *
 * `Task` shadows `_Concurrency.Task`. Any other schema whose name lands on
 * RESERVED_TYPE_NAMES without an entry here is a hard error rather than a silent
 * collision.
 */
const TYPE_NAME_OVERRIDES: Readonly<Record<string, string>> = {
  Task: "OttoTask",
};

const RESERVED_TYPE_NAMES: ReadonlySet<string> = new Set([
  "Task", "Result", "Error", "Never", "Optional", "Data", "Set", "Type", "Any",
  "AnyObject", "Sequence", "Collection", "Actor", "Notification", "Bundle",
  "Calendar", "Locale", "URL", "UUID", "Date", "Decimal", "String", "Int",
  "Double", "Bool", "Array", "Dictionary", "JSONValue", "OttoCoding",
]);

/** Swift keywords that need backtick escaping when used as identifiers. */
const SWIFT_KEYWORDS: ReadonlySet<string> = new Set([
  "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func",
  "import", "init", "inout", "internal", "let", "open", "operator", "private",
  "protocol", "public", "rethrows", "static", "struct", "subscript", "typealias",
  "var", "break", "case", "continue", "default", "defer", "do", "else",
  "fallthrough", "for", "guard", "if", "in", "repeat", "return", "switch",
  "where", "while", "as", "catch", "false", "is", "nil", "super", "self", "Self",
  "throw", "throws", "true", "try", "Protocol", "any", "some",
]);

/** Identifiers backticks cannot rescue. */
const UNUSABLE_IDENTIFIERS: ReadonlySet<string> = new Set(["self", "Self", "init", "_"]);

const INDENT = "    ";

// ─────────────────────────────────────────────────────────────────────
// Errors
// ─────────────────────────────────────────────────────────────────────

class CodegenError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "CodegenError";
  }
}

// ─────────────────────────────────────────────────────────────────────
// Runtime guard
// ─────────────────────────────────────────────────────────────────────

/**
 * This generator reads Zod's private `_def` internals, which are undocumented and
 * differ across major versions (Zod 4 moves them to `_zod.def`). Fail loudly at
 * startup rather than emitting plausible-looking wrong Swift.
 */
function assertZodRuntime(): void {
  const probe = z.string();
  const def: unknown = probe._def;
  if (typeof def !== "object" || def === null || !("typeName" in def)) {
    throw new CodegenError(
      "Unsupported Zod runtime: z.string()._def has no `typeName`. This generator " +
        "targets Zod 3's internals. Pin `zod` to the version in shared/package.json.",
    );
  }
  if (typeof z.ZodObject !== "function" || typeof z.ZodDiscriminatedUnion !== "function") {
    throw new CodegenError("Unsupported Zod runtime: expected Zod 3 schema classes.");
  }
}

// ─────────────────────────────────────────────────────────────────────
// Intermediate representation
// ─────────────────────────────────────────────────────────────────────

type SwiftType =
  | { readonly kind: "string" }
  | { readonly kind: "date" }
  | { readonly kind: "int" }
  | { readonly kind: "double" }
  | { readonly kind: "bool" }
  | { readonly kind: "json" }
  | { readonly kind: "array"; readonly element: SwiftType }
  | { readonly kind: "dictionary"; readonly value: SwiftType }
  | { readonly kind: "named"; readonly name: string };

/**
 * How a field behaves when its JSON key is absent.
 *   required  — key must be present
 *   absent    — key may be missing; Swift optional
 *   defaulted — key may be missing; falls back to a literal
 */
type Presence = "required" | "absent" | "defaulted";

interface FieldIR {
  /** JSON key. */
  readonly wireName: string;
  /** Swift property name (backtick-escaped if it collides with a keyword). */
  readonly swiftName: string;
  readonly type: SwiftType;
  readonly presence: Presence;
  /** Swift literal for `defaulted` fields, else null. */
  readonly defaultLiteral: string | null;
}

interface StructIR {
  readonly kind: "struct";
  readonly name: string;
  readonly fields: readonly FieldIR[];
}

interface EnumCaseIR {
  readonly wire: string;
  readonly swiftName: string;
}

interface EnumIR {
  readonly kind: "enum";
  readonly name: string;
  readonly cases: readonly EnumCaseIR[];
}

interface UnionVariantIR {
  readonly wire: string;
  readonly swiftName: string;
  readonly fields: readonly FieldIR[];
}

interface UnionIR {
  readonly kind: "union";
  readonly name: string;
  readonly discriminator: FieldIR;
  readonly variants: readonly UnionVariantIR[];
}

type DeclIR = StructIR | EnumIR | UnionIR;

// ─────────────────────────────────────────────────────────────────────
// Naming
// ─────────────────────────────────────────────────────────────────────

function assertUsableIdentifier(name: string, context: string): void {
  if (UNUSABLE_IDENTIFIERS.has(name)) {
    throw new CodegenError(
      `${context}: "${name}" cannot be used as a Swift identifier even with backticks. ` +
        "Rename it in the Zod schema.",
    );
  }
}

function escapeIdentifier(name: string): string {
  return SWIFT_KEYWORDS.has(name) ? `\`${name}\`` : name;
}

/** snake_case / kebab-case -> lowerCamelCase. */
function lowerCamelCase(wire: string): string {
  const parts = wire.split(/[_-]+/).filter((p) => p.length > 0);
  const [head, ...rest] = parts;
  if (head === undefined) {
    throw new CodegenError(`cannot derive an identifier from "${wire}"`);
  }
  const tail = rest.map((p) => `${p.charAt(0).toUpperCase()}${p.slice(1)}`).join("");
  return `${head.charAt(0).toLowerCase()}${head.slice(1)}${tail}`;
}

function swiftTypeName(schemaName: string): string {
  const override = TYPE_NAME_OVERRIDES[schemaName];
  if (override !== undefined) return override;
  if (RESERVED_TYPE_NAMES.has(schemaName)) {
    throw new CodegenError(
      `Schema "${schemaName}" collides with a Swift/Foundation type name. Add an entry ` +
        "to TYPE_NAME_OVERRIDES in shared/codegen/swift.ts.",
    );
  }
  return schemaName;
}

/**
 * Case identifier for an enum or union variant.
 *
 * `none` becomes `no<TypeName>`: a type carrying its own `.none` makes any bare
 * `.none` in an optional position resolve silently to `Optional.none`. The wire
 * string never changes.
 */
function caseName(wire: string, ownerType: string): string {
  const camel = lowerCamelCase(wire);
  if (camel === "none") return `no${ownerType}`;
  if (camel === "some") return `some${ownerType}`;
  assertUsableIdentifier(camel, `${ownerType} case "${wire}"`);
  return escapeIdentifier(camel);
}

// ─────────────────────────────────────────────────────────────────────
// Introspection
// ─────────────────────────────────────────────────────────────────────

/** Zod instance -> Swift nominal type name, so shared references emit by name. */
const registry = new Map<z.ZodTypeAny, string>();

function looksLikeZodSchema(value: unknown): boolean {
  if (typeof value !== "object" || value === null) return false;
  if (!("_def" in value)) return false;
  const def: unknown = (value as { readonly _def: unknown })._def;
  return typeof def === "object" && def !== null && "typeName" in def;
}

/**
 * Discovery predicate.
 *
 * `instanceof` gives fully typed access to `_def` with no casts, but returns false
 * for a schema built by a *different copy* of Zod — which would silently skip it.
 * The structural cross-check below turns that into a loud error.
 */
function isZodSchema(value: unknown): value is z.ZodTypeAny {
  const isInstance = value instanceof z.ZodType;
  if (!isInstance && looksLikeZodSchema(value)) {
    throw new CodegenError(
      "Found a Zod-shaped object that is not an instance of this process's Zod. " +
        "Multiple copies of Zod are installed; deduplicate before generating.",
    );
  }
  return isInstance;
}

/** `.shape` on a narrowed ZodObject is loosely typed; pin it to a known type. */
function shapeOf(obj: z.ZodObject<z.ZodRawShape>): z.ZodRawShape {
  const shape: z.ZodRawShape = obj.shape;
  return shape;
}

function swiftLiteral(value: unknown, isIntegral: boolean): string {
  if (value === null) return "nil";
  if (Array.isArray(value)) {
    if (value.length === 0) return "[]";
    throw new CodegenError(`non-empty array defaults are not supported: ${JSON.stringify(value)}`);
  }
  if (typeof value === "boolean") return value ? "true" : "false";
  if (typeof value === "number") {
    if (!Number.isFinite(value)) throw new CodegenError(`non-finite default: ${value}`);
    // A bare `0` would infer Double correctly, but `0.0` documents intent.
    return isIntegral || !Number.isInteger(value) ? `${value}` : `${value}.0`;
  }
  if (typeof value === "string") return JSON.stringify(value);
  if (typeof value === "object") {
    if (Object.keys(value).length === 0) return "[:]"; // `{}` is a closure in Swift
    throw new CodegenError(`non-empty object defaults are not supported: ${JSON.stringify(value)}`);
  }
  throw new CodegenError(`unsupported default value: ${String(value)}`);
}

interface Peeled {
  readonly core: z.ZodTypeAny;
  readonly presence: Presence;
  readonly hasDefault: boolean;
  readonly defaultValue: unknown;
}

/**
 * Peels Optional/Nullable/Default/Readonly wrappers.
 *
 * The OUTERMOST wrapper decides presence. `.optional().default(x)` and
 * `.default(x).optional()` carry the same flags but opposite JSON semantics — the
 * first is always present after parsing, the second can be absent.
 */
function peel(schema: z.ZodTypeAny): Peeled {
  let current = schema;
  let presence: Presence | null = null;
  let hasDefault = false;
  let defaultValue: unknown = undefined;

  for (;;) {
    if (current instanceof z.ZodOptional) {
      presence ??= "absent";
      current = current.unwrap();
      continue;
    }
    if (current instanceof z.ZodNullable) {
      presence ??= "absent";
      current = current.unwrap();
      continue;
    }
    if (current instanceof z.ZodDefault) {
      presence ??= "defaulted";
      if (!hasDefault) {
        hasDefault = true;
        defaultValue = current._def.defaultValue();
      }
      current = current._def.innerType;
      continue;
    }
    if (current instanceof z.ZodReadonly) {
      current = current._def.innerType;
      continue;
    }
    break;
  }

  // `z.unknown()` / `z.any()` accept a missing key with no Optional wrapper.
  if (current instanceof z.ZodUnknown || current instanceof z.ZodAny) {
    return { core: current, presence: "absent", hasDefault, defaultValue };
  }

  return { core: current, presence: presence ?? "required", hasDefault, defaultValue };
}

function mapType(schema: z.ZodTypeAny, at: string): SwiftType {
  const named = registry.get(schema);
  if (named !== undefined) return { kind: "named", name: named };

  if (schema instanceof z.ZodString) {
    const isDate = schema._def.checks.some((check) => check.kind === "datetime");
    return isDate ? { kind: "date" } : { kind: "string" };
  }
  if (schema instanceof z.ZodNumber) {
    const isInt = schema._def.checks.some((check) => check.kind === "int");
    return isInt ? { kind: "int" } : { kind: "double" };
  }
  if (schema instanceof z.ZodBoolean) return { kind: "bool" };
  if (schema instanceof z.ZodUnknown || schema instanceof z.ZodAny) return { kind: "json" };
  if (schema instanceof z.ZodArray) {
    const element = peel(schema._def.type);
    if (element.presence !== "required") {
      throw new CodegenError(`${at}: optional array elements are not supported`);
    }
    return { kind: "array", element: mapType(element.core, `${at}[]`) };
  }
  if (schema instanceof z.ZodRecord) {
    if (!(schema._def.keyType instanceof z.ZodString)) {
      throw new CodegenError(`${at}: only string-keyed records are supported`);
    }
    const value = peel(schema._def.valueType);
    return { kind: "dictionary", value: mapType(value.core, `${at}{}`) };
  }
  if (schema instanceof z.ZodObject) {
    throw new CodegenError(
      `${at}: anonymous object schemas are not supported. Extract it to a named export ` +
        "in shared/schemas/ so it generates as its own Swift type.",
    );
  }
  throw new CodegenError(`${at}: unmapped Zod node "${schema.constructor.name}"`);
}

function fieldOf(wireName: string, schema: z.ZodTypeAny, owner: string): FieldIR {
  assertUsableIdentifier(wireName, `${owner}.${wireName}`);
  const peeled = peel(schema);
  const type = mapType(peeled.core, `${owner}.${wireName}`);
  const isIntegral = type.kind === "int";
  return {
    wireName,
    swiftName: escapeIdentifier(wireName),
    type,
    presence: peeled.presence,
    defaultLiteral:
      peeled.presence === "defaulted" && peeled.hasDefault
        ? swiftLiteral(peeled.defaultValue, isIntegral)
        : null,
  };
}

function fieldsOf(
  obj: z.ZodObject<z.ZodRawShape>,
  owner: string,
  skipKey?: string,
): readonly FieldIR[] {
  const fields: FieldIR[] = [];
  // Shape key order is insertion order = source declaration order: deterministic,
  // and it keeps generated Swift aligned with the schema file for readable diffs.
  for (const [wireName, schema] of Object.entries(shapeOf(obj))) {
    if (skipKey !== undefined && wireName === skipKey) continue;
    fields.push(fieldOf(wireName, schema, owner));
  }
  return fields;
}

function declOf(schemaName: string, schema: z.ZodTypeAny): DeclIR {
  const name = swiftTypeName(schemaName);

  if (schema instanceof z.ZodEnum) {
    const options: readonly string[] = schema.options;
    return {
      kind: "enum",
      name,
      cases: options.map((wire) => ({ wire, swiftName: caseName(wire, name) })),
    };
  }

  if (schema instanceof z.ZodDiscriminatedUnion) {
    const discriminatorKey: string = schema._def.discriminator;
    const options: readonly z.ZodObject<z.ZodRawShape>[] = schema._def.options;
    const variants: UnionVariantIR[] = options.map((option) => {
      const literal = shapeOf(option)[discriminatorKey];
      if (literal === undefined || !(literal instanceof z.ZodLiteral)) {
        throw new CodegenError(
          `${name}: variant is missing a literal "${discriminatorKey}" discriminator`,
        );
      }
      const wire: unknown = literal._def.value;
      if (typeof wire !== "string") {
        throw new CodegenError(`${name}: only string discriminators are supported`);
      }
      return {
        wire,
        swiftName: caseName(wire, name),
        // Union variants are anonymous objects by design; walk them directly.
        fields: fieldsOf(option, `${name}.${wire}`, discriminatorKey),
      };
    });
    return {
      kind: "union",
      name,
      discriminator: {
        wireName: discriminatorKey,
        swiftName: escapeIdentifier(discriminatorKey),
        type: { kind: "string" },
        presence: "required",
        defaultLiteral: null,
      },
      variants,
    };
  }

  if (schema instanceof z.ZodObject) {
    return { kind: "struct", name, fields: fieldsOf(schema, name) };
  }

  // Named primitives (zId, isoDateTime) are not nominal Swift types; they are
  // filtered out before this point.
  throw new CodegenError(`schema "${schemaName}" is not an object, enum, or discriminated union`);
}

/** Only object/enum/union schemas become Swift nominal types. */
function isNominal(schema: z.ZodTypeAny): boolean {
  return (
    schema instanceof z.ZodObject ||
    schema instanceof z.ZodEnum ||
    schema instanceof z.ZodDiscriminatedUnion
  );
}

// ─────────────────────────────────────────────────────────────────────
// Emission
// ─────────────────────────────────────────────────────────────────────

function renderType(type: SwiftType): string {
  switch (type.kind) {
    case "string":
      return "String";
    case "date":
      return "Date";
    case "int":
      return "Int";
    case "double":
      return "Double";
    case "bool":
      return "Bool";
    case "json":
      return "JSONValue";
    case "array":
      return `[${renderType(type.element)}]`;
    case "dictionary":
      return `[String: ${renderType(type.value)}]`;
    case "named":
      return type.name;
  }
}

/** Declared Swift type, including `?` for absent fields. */
function renderFieldType(field: FieldIR): string {
  const base = renderType(field.type);
  return field.presence === "absent" ? `${base}?` : base;
}

function header(source: string | null): readonly string[] {
  const origin =
    source === null
      ? "// Support file — shared/codegen/swift.ts"
      : `// Source: ${source}`;
  return [
    "// GENERATED FROM shared/schemas — DO NOT EDIT",
    "//",
    origin,
    "// Regenerate with `npm run codegen`.",
    "//",
    "// Requires this app-target build setting:",
    "//   SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated",
    "//",
    "// Under MainActor-by-default isolation these Codable conformances cannot",
    "// compile: a main-actor-isolated initializer cannot satisfy the nonisolated",
    "// `init(from:)` requirement.",
  ];
}

function emitEnum(decl: EnumIR): readonly string[] {
  const lines: string[] = [];
  lines.push(`enum ${decl.name}: String, Codable, Hashable, Sendable, CaseIterable {`);
  for (const entry of decl.cases) {
    // An explicit raw value only where the identifier differs from the wire string;
    // `case reminder` already has rawValue "reminder".
    if (entry.swiftName === entry.wire) {
      lines.push(`${INDENT}case ${entry.swiftName}`);
    } else {
      lines.push(`${INDENT}/// Wire value: \`"${entry.wire}"\`.`);
      lines.push(`${INDENT}case ${entry.swiftName} = "${entry.wire}"`);
    }
  }
  lines.push("}");
  return lines;
}

/** `decodeIfPresent`/`decode` call for one field, assigning into `self`. */
function decodeLines(field: FieldIR): readonly string[] {
  const type = renderType(field.type);
  const key = `.${field.wireName}`;

  if (field.presence === "defaulted") {
    if (field.defaultLiteral === null) {
      throw new CodegenError(`${field.wireName}: defaulted field without a literal`);
    }
    return [
      `${INDENT}${INDENT}self.${field.swiftName} = try container.decodeIfPresent(${type}.self, forKey: ${key}) ?? ${field.defaultLiteral}`,
    ];
  }

  if (field.presence === "absent") {
    // For a free-form JSON field, distinguish "key missing" from "key present and
    // null": `decodeIfPresent` collapses both to nil, losing JSONValue.null.
    if (field.type.kind === "json") {
      return [
        `${INDENT}${INDENT}if container.contains(${key}) {`,
        `${INDENT}${INDENT}${INDENT}self.${field.swiftName} = try container.decode(${type}.self, forKey: ${key})`,
        `${INDENT}${INDENT}} else {`,
        `${INDENT}${INDENT}${INDENT}self.${field.swiftName} = nil`,
        `${INDENT}${INDENT}}`,
      ];
    }
    return [
      `${INDENT}${INDENT}self.${field.swiftName} = try container.decodeIfPresent(${type}.self, forKey: ${key})`,
    ];
  }

  return [`${INDENT}${INDENT}self.${field.swiftName} = try container.decode(${type}.self, forKey: ${key})`];
}

/** Encode call for one field. Optionals MUST omit rather than write null. */
function encodeLine(field: FieldIR): string {
  const key = `.${field.wireName}`;
  const fn = field.presence === "absent" ? "encodeIfPresent" : "encode";
  return `${INDENT}${INDENT}try container.${fn}(self.${field.swiftName}, forKey: ${key})`;
}

function emitStruct(decl: StructIR): readonly string[] {
  const lines: string[] = [];
  const conformances = ["Codable", "Hashable", "Sendable"];
  if (decl.fields.some((f) => f.wireName === "id" && f.presence === "required")) {
    conformances.push("Identifiable");
  }

  lines.push(`struct ${decl.name}: ${conformances.join(", ")} {`);

  if (decl.fields.length === 0) {
    // No CodingKeys and no custom coding: an unused `container` local would warn.
    lines.push(`${INDENT}init() {}`);
    lines.push("}");
    return lines;
  }

  // Stored properties. `var` so SwiftUI can bind and callers can mutate before a PUT.
  // Defaults deliberately do NOT appear here — an inline initializer does not make
  // the decoder tolerant of a missing key, so writing one here would mislead.
  for (const field of decl.fields) {
    lines.push(`${INDENT}var ${field.swiftName}: ${renderFieldType(field)}`);
  }

  // Memberwise init, with defaults where the schema has them.
  lines.push("");
  lines.push(`${INDENT}init(`);
  const params = decl.fields.map((field) => {
    const type = renderFieldType(field);
    if (field.presence === "defaulted" && field.defaultLiteral !== null) {
      return `${INDENT}${INDENT}${field.swiftName}: ${type} = ${field.defaultLiteral}`;
    }
    if (field.presence === "absent") {
      return `${INDENT}${INDENT}${field.swiftName}: ${type} = nil`;
    }
    return `${INDENT}${INDENT}${field.swiftName}: ${type}`;
  });
  lines.push(params.join(",\n"));
  lines.push(`${INDENT}) {`);
  for (const field of decl.fields) {
    lines.push(`${INDENT}${INDENT}self.${field.swiftName} = ${field.swiftName}`);
  }
  lines.push(`${INDENT}}`);

  // CodingKeys.
  lines.push("");
  lines.push(`${INDENT}private enum CodingKeys: String, CodingKey {`);
  for (const field of decl.fields) {
    lines.push(`${INDENT}${INDENT}case ${field.swiftName}`);
  }
  lines.push(`${INDENT}}`);

  // init(from:) — `decoder.container(keyedBy:)` throws; the container is `let`
  // because its decode requirements are non-mutating.
  lines.push("");
  lines.push(`${INDENT}init(from decoder: any Decoder) throws {`);
  lines.push(`${INDENT}${INDENT}let container = try decoder.container(keyedBy: CodingKeys.self)`);
  for (const field of decl.fields) lines.push(...decodeLines(field));
  lines.push(`${INDENT}}`);

  // encode(to:) — `encoder.container(keyedBy:)` does NOT throw (no `try`), and the
  // container is `var` because its encode requirements are mutating.
  lines.push("");
  lines.push(`${INDENT}func encode(to encoder: any Encoder) throws {`);
  lines.push(`${INDENT}${INDENT}var container = encoder.container(keyedBy: CodingKeys.self)`);
  for (const field of decl.fields) lines.push(encodeLine(field));
  lines.push(`${INDENT}}`);

  lines.push("}");
  return lines;
}

function emitUnion(decl: UnionIR): readonly string[] {
  const lines: string[] = [];
  lines.push(`enum ${decl.name}: Codable, Hashable, Sendable {`);

  for (const variant of decl.variants) {
    if (variant.swiftName !== lowerCamelCase(variant.wire)) {
      lines.push(`${INDENT}/// Wire value: \`"${variant.wire}"\`.`);
    }
    if (variant.fields.length === 0) {
      lines.push(`${INDENT}case ${variant.swiftName}`);
    } else {
      const payload = variant.fields
        .map((f) => `${f.swiftName}: ${renderFieldType(f)}`)
        .join(", ");
      lines.push(`${INDENT}case ${variant.swiftName}(${payload})`);
    }
  }

  // CodingKeys is the union of the discriminator and every variant's keys.
  const keys: string[] = [decl.discriminator.swiftName];
  for (const variant of decl.variants) {
    for (const field of variant.fields) {
      if (!keys.includes(field.swiftName)) keys.push(field.swiftName);
    }
  }
  lines.push("");
  lines.push(`${INDENT}private enum CodingKeys: String, CodingKey {`);
  for (const key of keys) lines.push(`${INDENT}${INDENT}case ${key}`);
  lines.push(`${INDENT}}`);

  // init(from:) — decode each payload into a local before assigning to `self`, so
  // `try` stays on its own statement.
  const discriminatorLocal = decl.discriminator.wireName === "type" ? "typeTag" : "discriminator";
  lines.push("");
  lines.push(`${INDENT}init(from decoder: any Decoder) throws {`);
  lines.push(`${INDENT}${INDENT}let container = try decoder.container(keyedBy: CodingKeys.self)`);
  lines.push(
    `${INDENT}${INDENT}let ${discriminatorLocal} = try container.decode(String.self, forKey: .${decl.discriminator.wireName})`,
  );
  lines.push(`${INDENT}${INDENT}switch ${discriminatorLocal} {`);
  for (const variant of decl.variants) {
    lines.push(`${INDENT}${INDENT}case "${variant.wire}":`);
    for (const field of variant.fields) {
      lines.push(
        `${INDENT}${INDENT}${INDENT}let ${field.swiftName} = try container.decode(${renderType(field.type)}.self, forKey: .${field.wireName})`,
      );
    }
    if (variant.fields.length === 0) {
      lines.push(`${INDENT}${INDENT}${INDENT}self = .${variant.swiftName}`);
    } else {
      const args = variant.fields.map((f) => `${f.swiftName}: ${f.swiftName}`).join(", ");
      lines.push(`${INDENT}${INDENT}${INDENT}self = .${variant.swiftName}(${args})`);
    }
  }
  lines.push(`${INDENT}${INDENT}default:`);
  lines.push(`${INDENT}${INDENT}${INDENT}throw DecodingError.dataCorruptedError(`);
  lines.push(`${INDENT}${INDENT}${INDENT}${INDENT}forKey: .${decl.discriminator.wireName},`);
  lines.push(`${INDENT}${INDENT}${INDENT}${INDENT}in: container,`);
  lines.push(
    `${INDENT}${INDENT}${INDENT}${INDENT}debugDescription: "Unknown ${decl.name} ${decl.discriminator.wireName} \\(${discriminatorLocal}.debugDescription)."`,
  );
  lines.push(`${INDENT}${INDENT}${INDENT})`);
  lines.push(`${INDENT}${INDENT}}`);
  lines.push(`${INDENT}}`);

  // encode(to:)
  lines.push("");
  lines.push(`${INDENT}func encode(to encoder: any Encoder) throws {`);
  lines.push(`${INDENT}${INDENT}var container = encoder.container(keyedBy: CodingKeys.self)`);
  lines.push(`${INDENT}${INDENT}switch self {`);
  for (const variant of decl.variants) {
    if (variant.fields.length === 0) {
      lines.push(`${INDENT}${INDENT}case .${variant.swiftName}:`);
    } else {
      const bindings = variant.fields.map((f) => `let ${f.swiftName}`).join(", ");
      lines.push(`${INDENT}${INDENT}case .${variant.swiftName}(${bindings}):`);
    }
    lines.push(
      `${INDENT}${INDENT}${INDENT}try container.encode("${variant.wire}", forKey: .${decl.discriminator.wireName})`,
    );
    for (const field of variant.fields) {
      lines.push(
        `${INDENT}${INDENT}${INDENT}try container.encode(${field.swiftName}, forKey: .${field.wireName})`,
      );
    }
  }
  lines.push(`${INDENT}${INDENT}}`);
  lines.push(`${INDENT}}`);

  lines.push("}");
  return lines;
}

function emitDecl(decl: DeclIR): readonly string[] {
  switch (decl.kind) {
    case "enum":
      return emitEnum(decl);
    case "union":
      return emitUnion(decl);
    case "struct":
      return emitStruct(decl);
  }
}

function renderFile(source: string | null, body: readonly string[]): string {
  return `${[...header(source), "", "import Foundation", "", ...body].join("\n")}\n`;
}

// ─────────────────────────────────────────────────────────────────────
// Support files
// ─────────────────────────────────────────────────────────────────────

/**
 * The shared ISO-8601 coding strategy.
 *
 * Encoding uses a single `format` call rather than assembling the string from parts:
 * a malformed date string breaks every request, so predictability beats
 * sub-millisecond fidelity here.
 */
const OTTO_CODING_BODY: readonly string[] = [
  "/// The single JSON coding configuration shared by every generated Otto model.",
  "///",
  "/// Every schema field built from `isoDateTime` (`z.string().datetime({ offset: true })`)",
  "/// decodes into a Swift `Date` through the strategies defined here. Because the",
  "/// strategies live on the `JSONDecoder`/`JSONEncoder`, they apply to `Date` at any",
  "/// nesting depth — including `Trigger.at` inside `OttoTask`, and `ListItem.addedAt`",
  "/// inside `[ListItem]`.",
  "///",
  "/// `ScheduledSession.timeOfDay` (\"08:00\") is a wall-clock string, not an instant,",
  "/// and stays a Swift `String`.",
  "enum OttoCoding {",
  "",
  `${INDENT}// Canonical wire format: 2026-07-30T14:00:00.123Z`,
  `${INDENT}//`,
  `${INDENT}// RFC 3339, UTC, three fractional digits. Byte-for-byte what JavaScript's`,
  `${INDENT}// Date.prototype.toISOString() produces, and accepted by the server's`,
  `${INDENT}// z.string().datetime({ offset: true }).`,
  "",
  `${INDENT}/// Primary parser.`,
  `${INDENT}///`,
  `${INDENT}/// \`Date.ISO8601FormatStyle\` is a \`Sendable\` struct, so these \`static let\`s are`,
  `${INDENT}/// concurrency-safe under Swift 6. \`ISO8601DateFormatter\` is a non-Sendable`,
  `${INDENT}/// class and would not be.`,
  `${INDENT}///`,
  `${INDENT}/// \`includingFractionalSeconds\` constrains FORMATTING only. As of Swift 6.2 the`,
  `${INDENT}/// parser accepts fractional seconds either way (and keeps their precision), so`,
  `${INDENT}/// on iOS 26 this parser alone handles both \`...00Z\` and \`...00.123Z\`.`,
  `${INDENT}///`,
  `${INDENT}/// A zone designator is REQUIRED — \`timeZone\` is passed as the default but is`,
  `${INDENT}/// always overridden by the \`Z\` or numeric offset in the string, which is what`,
  `${INDENT}/// determines the instant. The server's \`.datetime({ offset: true })\` guarantees`,
  `${INDENT}/// a designator is present.`,
  `${INDENT}private static let parser = Date.ISO8601FormatStyle(`,
  `${INDENT}${INDENT}includingFractionalSeconds: false,`,
  `${INDENT}${INDENT}timeZone: TimeZone.gmt`,
  `${INDENT})`,
  "",
  `${INDENT}/// Formats the canonical wire form, and parses on Foundation versions before`,
  `${INDENT}/// Swift 6.2 where a parser had to match the input's fractional seconds exactly.`,
  `${INDENT}private static let fractionalParser = Date.ISO8601FormatStyle(`,
  `${INDENT}${INDENT}includingFractionalSeconds: true,`,
  `${INDENT}${INDENT}timeZone: TimeZone.gmt`,
  `${INDENT})`,
  "",
  `${INDENT}/// Parses any ISO-8601 instant the server or an iOS client emits.`,
  `${INDENT}///`,
  `${INDENT}///     2026-07-30T14:00:00Z`,
  `${INDENT}///     2026-07-30T10:00:00-04:00`,
  `${INDENT}///     2026-07-30T10:00:00.123-04:00`,
  `${INDENT}///     2026-07-30T14:00:00.123456Z`,
  `${INDENT}static func date(fromISO8601 string: String) -> Date? {`,
  `${INDENT}${INDENT}if let date = try? OttoCoding.parser.parse(string) {`,
  `${INDENT}${INDENT}${INDENT}return date`,
  `${INDENT}${INDENT}}`,
  `${INDENT}${INDENT}if let date = try? OttoCoding.fractionalParser.parse(string) {`,
  `${INDENT}${INDENT}${INDENT}return date`,
  `${INDENT}${INDENT}}`,
  `${INDENT}${INDENT}return nil`,
  `${INDENT}}`,
  "",
  `${INDENT}/// Renders \`date\` in the canonical wire form.`,
  `${INDENT}static func iso8601String(from date: Date) -> String {`,
  `${INDENT}${INDENT}return OttoCoding.fractionalParser.format(date)`,
  `${INDENT}}`,
  "",
  `${INDENT}/// The \`.custom\` payload is \`@Sendable\`; this closure captures nothing and`,
  `${INDENT}/// reaches the parsers through \`OttoCoding\`'s own Sendable statics.`,
  `${INDENT}static let dateDecodingStrategy: JSONDecoder.DateDecodingStrategy =`,
  `${INDENT}${INDENT}.custom { (decoder: any Decoder) throws -> Date in`,
  `${INDENT}${INDENT}${INDENT}// \`singleValueContainer()\` throws; \`decode\` is non-mutating, so \`let\`.`,
  `${INDENT}${INDENT}${INDENT}let container = try decoder.singleValueContainer()`,
  `${INDENT}${INDENT}${INDENT}let raw = try container.decode(String.self)`,
  `${INDENT}${INDENT}${INDENT}guard let date = OttoCoding.date(fromISO8601: raw) else {`,
  `${INDENT}${INDENT}${INDENT}${INDENT}throw DecodingError.dataCorruptedError(`,
  `${INDENT}${INDENT}${INDENT}${INDENT}${INDENT}in: container,`,
  `${INDENT}${INDENT}${INDENT}${INDENT}${INDENT}debugDescription: "Expected an ISO-8601 date-time string, found \\(raw.debugDescription)."`,
  `${INDENT}${INDENT}${INDENT}${INDENT})`,
  `${INDENT}${INDENT}${INDENT}}`,
  `${INDENT}${INDENT}${INDENT}return date`,
  `${INDENT}${INDENT}}`,
  "",
  `${INDENT}static let dateEncodingStrategy: JSONEncoder.DateEncodingStrategy =`,
  `${INDENT}${INDENT}.custom { (date: Date, encoder: any Encoder) throws -> Void in`,
  `${INDENT}${INDENT}${INDENT}// \`Encoder.singleValueContainer()\` does NOT throw — no \`try\`.`,
  `${INDENT}${INDENT}${INDENT}// \`encode\` is mutating, so \`var\`.`,
  `${INDENT}${INDENT}${INDENT}var container = encoder.singleValueContainer()`,
  `${INDENT}${INDENT}${INDENT}try container.encode(OttoCoding.iso8601String(from: date))`,
  `${INDENT}${INDENT}}`,
  "",
  `${INDENT}/// Never set \`keyEncodingStrategy\`/\`keyDecodingStrategy\`: the wire keys are`,
  `${INDENT}/// already lowerCamelCase and any conversion would break the Zod contract.`,
  `${INDENT}static func makeDecoder() -> JSONDecoder {`,
  `${INDENT}${INDENT}let decoder = JSONDecoder()`,
  `${INDENT}${INDENT}decoder.dateDecodingStrategy = OttoCoding.dateDecodingStrategy`,
  `${INDENT}${INDENT}return decoder`,
  `${INDENT}}`,
  "",
  `${INDENT}static func makeEncoder() -> JSONEncoder {`,
  `${INDENT}${INDENT}let encoder = JSONEncoder()`,
  `${INDENT}${INDENT}encoder.dateEncodingStrategy = OttoCoding.dateEncodingStrategy`,
  `${INDENT}${INDENT}return encoder`,
  `${INDENT}}`,
  "",
  `${INDENT}/// Shared coders. These are reference types: never mutate their properties.`,
  `${INDENT}/// Use \`makeDecoder()\`/\`makeEncoder()\` if you need a configured copy.`,
  `${INDENT}static let decoder: JSONDecoder = OttoCoding.makeDecoder()`,
  `${INDENT}static let encoder: JSONEncoder = OttoCoding.makeEncoder()`,
  "}",
];

/**
 * `JSONValue` backs the two schema fields with no fixed shape:
 * `TurnEvent.data` (z.unknown) and `Plan.constraints` (z.record(string, unknown)).
 *
 * `hash(into:)` is written out rather than synthesized: recursive Hashable synthesis
 * through `[String: JSONValue]` would otherwise be the single point of failure for
 * three files at once, and spelling it costs nothing.
 */
const JSON_VALUE_BODY: readonly string[] = [
  "/// A lossless, `Sendable` representation of an arbitrary JSON value.",
  "///",
  "/// Backs the two Zod fields with no fixed shape:",
  "///   - `TurnEvent.data` — `z.unknown()`",
  "///   - `Plan.constraints` — `z.record(z.string(), z.unknown())`",
  "///",
  "/// No `indirect`: `Array` and `Dictionary` are fixed-size structs pointing at heap",
  "/// storage, so the recursive cases do not make this enum's layout unbounded.",
  "enum JSONValue: Codable, Hashable, Sendable {",
  `${INDENT}case null`,
  `${INDENT}case bool(Bool)`,
  `${INDENT}/// A JSON number that is integral and fits in \`Int\`.`,
  `${INDENT}case int(Int)`,
  `${INDENT}/// Any other JSON number: fractional, exponential, or out of \`Int\` range.`,
  `${INDENT}case double(Double)`,
  `${INDENT}case string(String)`,
  `${INDENT}case array([JSONValue])`,
  `${INDENT}case object([String: JSONValue])`,
  "",
  `${INDENT}init(from decoder: any Decoder) throws {`,
  `${INDENT}${INDENT}// \`singleValueContainer()\` throws; the container's decode requirements are`,
  `${INDENT}${INDENT}// non-mutating, so \`let\`.`,
  `${INDENT}${INDENT}let container = try decoder.singleValueContainer()`,
  "",
  `${INDENT}${INDENT}// \`SingleValueDecodingContainer.decodeNil()\` does NOT throw — \`try\` would warn.`,
  `${INDENT}${INDENT}if container.decodeNil() {`,
  `${INDENT}${INDENT}${INDENT}self = .null`,
  `${INDENT}${INDENT}${INDENT}return`,
  `${INDENT}${INDENT}}`,
  "",
  `${INDENT}${INDENT}// Bool before the numeric cases, and Int before Double, so integral values`,
  `${INDENT}${INDENT}// keep full precision and re-encode without a decimal point.`,
  `${INDENT}${INDENT}if let value = try? container.decode(Bool.self) {`,
  `${INDENT}${INDENT}${INDENT}self = .bool(value)`,
  `${INDENT}${INDENT}${INDENT}return`,
  `${INDENT}${INDENT}}`,
  `${INDENT}${INDENT}if let value = try? container.decode(Int.self) {`,
  `${INDENT}${INDENT}${INDENT}self = .int(value)`,
  `${INDENT}${INDENT}${INDENT}return`,
  `${INDENT}${INDENT}}`,
  `${INDENT}${INDENT}if let value = try? container.decode(Double.self) {`,
  `${INDENT}${INDENT}${INDENT}self = .double(value)`,
  `${INDENT}${INDENT}${INDENT}return`,
  `${INDENT}${INDENT}}`,
  `${INDENT}${INDENT}if let value = try? container.decode(String.self) {`,
  `${INDENT}${INDENT}${INDENT}self = .string(value)`,
  `${INDENT}${INDENT}${INDENT}return`,
  `${INDENT}${INDENT}}`,
  `${INDENT}${INDENT}if let value = try? container.decode([JSONValue].self) {`,
  `${INDENT}${INDENT}${INDENT}self = .array(value)`,
  `${INDENT}${INDENT}${INDENT}return`,
  `${INDENT}${INDENT}}`,
  `${INDENT}${INDENT}if let value = try? container.decode([String: JSONValue].self) {`,
  `${INDENT}${INDENT}${INDENT}self = .object(value)`,
  `${INDENT}${INDENT}${INDENT}return`,
  `${INDENT}${INDENT}}`,
  "",
  `${INDENT}${INDENT}throw DecodingError.dataCorrupted(`,
  `${INDENT}${INDENT}${INDENT}DecodingError.Context(`,
  `${INDENT}${INDENT}${INDENT}${INDENT}codingPath: container.codingPath,`,
  `${INDENT}${INDENT}${INDENT}${INDENT}debugDescription: "Not a representable JSON value."`,
  `${INDENT}${INDENT}${INDENT})`,
  `${INDENT}${INDENT})`,
  `${INDENT}}`,
  "",
  `${INDENT}func encode(to encoder: any Encoder) throws {`,
  `${INDENT}${INDENT}// \`Encoder.singleValueContainer()\` does NOT throw; \`encode\` is mutating.`,
  `${INDENT}${INDENT}var container = encoder.singleValueContainer()`,
  `${INDENT}${INDENT}switch self {`,
  `${INDENT}${INDENT}case .null:`,
  `${INDENT}${INDENT}${INDENT}// \`SingleValueEncodingContainer.encodeNil()\` DOES throw.`,
  `${INDENT}${INDENT}${INDENT}try container.encodeNil()`,
  `${INDENT}${INDENT}case .bool(let value):`,
  `${INDENT}${INDENT}${INDENT}try container.encode(value)`,
  `${INDENT}${INDENT}case .int(let value):`,
  `${INDENT}${INDENT}${INDENT}try container.encode(value)`,
  `${INDENT}${INDENT}case .double(let value):`,
  `${INDENT}${INDENT}${INDENT}try container.encode(value)`,
  `${INDENT}${INDENT}case .string(let value):`,
  `${INDENT}${INDENT}${INDENT}try container.encode(value)`,
  `${INDENT}${INDENT}case .array(let value):`,
  `${INDENT}${INDENT}${INDENT}try container.encode(value)`,
  `${INDENT}${INDENT}case .object(let value):`,
  `${INDENT}${INDENT}${INDENT}try container.encode(value)`,
  `${INDENT}${INDENT}}`,
  `${INDENT}}`,
  "",
  `${INDENT}func hash(into hasher: inout Hasher) {`,
  `${INDENT}${INDENT}switch self {`,
  `${INDENT}${INDENT}case .null:`,
  `${INDENT}${INDENT}${INDENT}hasher.combine(0)`,
  `${INDENT}${INDENT}case .bool(let value):`,
  `${INDENT}${INDENT}${INDENT}hasher.combine(1)`,
  `${INDENT}${INDENT}${INDENT}hasher.combine(value)`,
  `${INDENT}${INDENT}case .int(let value):`,
  `${INDENT}${INDENT}${INDENT}hasher.combine(2)`,
  `${INDENT}${INDENT}${INDENT}hasher.combine(value)`,
  `${INDENT}${INDENT}case .double(let value):`,
  `${INDENT}${INDENT}${INDENT}hasher.combine(3)`,
  `${INDENT}${INDENT}${INDENT}hasher.combine(value)`,
  `${INDENT}${INDENT}case .string(let value):`,
  `${INDENT}${INDENT}${INDENT}hasher.combine(4)`,
  `${INDENT}${INDENT}${INDENT}hasher.combine(value)`,
  `${INDENT}${INDENT}case .array(let value):`,
  `${INDENT}${INDENT}${INDENT}hasher.combine(5)`,
  `${INDENT}${INDENT}${INDENT}hasher.combine(value)`,
  `${INDENT}${INDENT}case .object(let value):`,
  `${INDENT}${INDENT}${INDENT}hasher.combine(6)`,
  `${INDENT}${INDENT}${INDENT}hasher.combine(value)`,
  `${INDENT}${INDENT}}`,
  `${INDENT}}`,
  "",
  `${INDENT}/// The wrapped string, when this value is a JSON string.`,
  `${INDENT}///`,
  `${INDENT}/// Used by the debug console to pull token text out of \`TurnEvent.data\`.`,
  `${INDENT}var stringValue: String? {`,
  `${INDENT}${INDENT}switch self {`,
  `${INDENT}${INDENT}case .string(let value):`,
  `${INDENT}${INDENT}${INDENT}return value`,
  `${INDENT}${INDENT}default:`,
  `${INDENT}${INDENT}${INDENT}return nil`,
  `${INDENT}${INDENT}}`,
  `${INDENT}}`,
  "",
  `${INDENT}var boolValue: Bool? {`,
  `${INDENT}${INDENT}switch self {`,
  `${INDENT}${INDENT}case .bool(let value):`,
  `${INDENT}${INDENT}${INDENT}return value`,
  `${INDENT}${INDENT}default:`,
  `${INDENT}${INDENT}${INDENT}return nil`,
  `${INDENT}${INDENT}}`,
  `${INDENT}}`,
  "",
  `${INDENT}/// \`Int(exactly:)\` returns nil for fractional, out-of-range, and NaN values,`,
  `${INDENT}/// so this never traps.`,
  `${INDENT}var intValue: Int? {`,
  `${INDENT}${INDENT}switch self {`,
  `${INDENT}${INDENT}case .int(let value):`,
  `${INDENT}${INDENT}${INDENT}return value`,
  `${INDENT}${INDENT}case .double(let value):`,
  `${INDENT}${INDENT}${INDENT}return Int(exactly: value)`,
  `${INDENT}${INDENT}default:`,
  `${INDENT}${INDENT}${INDENT}return nil`,
  `${INDENT}${INDENT}}`,
  `${INDENT}}`,
  "",
  `${INDENT}var doubleValue: Double? {`,
  `${INDENT}${INDENT}switch self {`,
  `${INDENT}${INDENT}case .int(let value):`,
  `${INDENT}${INDENT}${INDENT}return Double(value)`,
  `${INDENT}${INDENT}case .double(let value):`,
  `${INDENT}${INDENT}${INDENT}return value`,
  `${INDENT}${INDENT}default:`,
  `${INDENT}${INDENT}${INDENT}return nil`,
  `${INDENT}${INDENT}}`,
  `${INDENT}}`,
  "",
  `${INDENT}var arrayValue: [JSONValue]? {`,
  `${INDENT}${INDENT}switch self {`,
  `${INDENT}${INDENT}case .array(let value):`,
  `${INDENT}${INDENT}${INDENT}return value`,
  `${INDENT}${INDENT}default:`,
  `${INDENT}${INDENT}${INDENT}return nil`,
  `${INDENT}${INDENT}}`,
  `${INDENT}}`,
  "",
  `${INDENT}var objectValue: [String: JSONValue]? {`,
  `${INDENT}${INDENT}switch self {`,
  `${INDENT}${INDENT}case .object(let value):`,
  `${INDENT}${INDENT}${INDENT}return value`,
  `${INDENT}${INDENT}default:`,
  `${INDENT}${INDENT}${INDENT}return nil`,
  `${INDENT}${INDENT}}`,
  `${INDENT}}`,
  "}",
];

// ─────────────────────────────────────────────────────────────────────
// Driver
// ─────────────────────────────────────────────────────────────────────

function repoRoot(): string {
  const here = path.dirname(url.fileURLToPath(import.meta.url));
  return path.resolve(here, "..", "..");
}

function main(): void {
  assertZodRuntime();

  // Pass 1: register every nominal schema so shared references emit by name.
  // Sorted for determinism: the ES module namespace is spec-sorted, but a CJS or
  // bundled build is not, and codegen output must never churn.
  for (const mod of MODULES) {
    for (const name of Object.keys(mod.schemas).sort()) {
      const value: unknown = mod.schemas[name];
      if (!isZodSchema(value) || !isNominal(value)) continue;
      registry.set(value, swiftTypeName(name));
    }
  }

  // Pass 2: emit.
  const outDir = path.join(repoRoot(), "ios", "Otto", "Models");
  fs.mkdirSync(outDir, { recursive: true });

  const files = new Map<string, string>();
  files.set("OttoCoding.swift", renderFile(null, OTTO_CODING_BODY));
  files.set("JSONValue.swift", renderFile(null, JSON_VALUE_BODY));

  for (const mod of MODULES) {
    const blocks: string[][] = [];
    for (const name of Object.keys(mod.schemas).sort()) {
      const value: unknown = mod.schemas[name];
      if (!isZodSchema(value) || !isNominal(value)) continue;
      blocks.push([...emitDecl(declOf(name, value))]);
    }
    // A module with no nominal schemas (e.g. common.ts) emits nothing.
    if (blocks.length === 0) continue;
    const body: string[] = [];
    blocks.forEach((block, index) => {
      if (index > 0) body.push("");
      body.push(...block);
    });
    files.set(`${mod.swiftFile}.swift`, renderFile(mod.source, body));
  }

  // Sweep stale output so a deleted schema cannot leave an orphan file behind.
  for (const existing of fs.readdirSync(outDir)) {
    if (existing.endsWith(".swift") && !files.has(existing)) {
      fs.unlinkSync(path.join(outDir, existing));
      console.log(`  removed  ios/Otto/Models/${existing}`);
    }
  }

  for (const [name, contents] of [...files].sort(([a], [b]) => a.localeCompare(b))) {
    fs.writeFileSync(path.join(outDir, name), contents, "utf8");
    const lineCount = contents.split("\n").length - 1;
    console.log(`  wrote    ios/Otto/Models/${name} (${lineCount} lines)`);
  }

  console.log(`\ncodegen complete — ${files.size} files in ios/Otto/Models/`);
}

main();
