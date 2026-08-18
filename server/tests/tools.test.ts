import { strict as assert } from "node:assert";
import { test } from "node:test";

import { MemoryCategory, TaskIntent, TaskStatus } from "@otto/shared";

import { buildStaticPrefix } from "../src/persona/system.js";
import { estimateTokens } from "../src/router/selectModel.js";
import { OTTO_TOOLS } from "../src/tools/definitions.js";

function tool(name: string) {
  const found = OTTO_TOOLS.find((t) => t.name === name);
  assert.ok(found !== undefined, `missing tool ${name}`);
  return found;
}

type SchemaProperty = { type?: string; enum?: string[] };

function properties(name: string): Record<string, SchemaProperty> {
  return (tool(name).input_schema.properties ?? {}) as Record<string, SchemaProperty>;
}

test("exactly the specified tools, snake_case, unique", () => {
  const names = OTTO_TOOLS.map((t) => t.name);
  assert.deepEqual(names, [
    "create_task",
    "query_tasks",
    "update_task_items",
    "complete_task",
    "save_memory",
    "propose_calendar_event",
    "propose_calendar_move",
    "generate_plan",
    "adapt_plan",
    "draft_message",
  ]);
  assert.equal(new Set(names).size, names.length);
  for (const name of names) {
    assert.match(name, /^[a-z][a-z_]*$/);
  }
});

test("every tool is a plain object schema whose required keys exist", () => {
  for (const t of OTTO_TOOLS) {
    assert.equal(t.input_schema.type, "object");
    assert.ok((t.description ?? "").length >= 40, `${t.name} needs a real description`);
    const props = (t.input_schema.properties ?? {}) as Record<string, unknown>;
    const required = (t.input_schema.required ?? []) as string[];
    for (const key of required) {
      assert.ok(key in props, `${t.name}.required lists unknown field ${key}`);
    }
  }
});

test("enums stay aligned with the shared Zod schemas", () => {
  // create_task: the spec's three creatable intents (message flows via draft_message).
  assert.deepEqual(properties("create_task").intent?.enum, ["reminder", "list", "capture"]);
  for (const value of properties("create_task").intent?.enum ?? []) {
    assert.ok(TaskIntent.options.includes(value as never), `unknown intent ${value}`);
  }
  // query_tasks filters cover the full shared enums.
  assert.deepEqual(properties("query_tasks").intent?.enum, TaskIntent.options);
  assert.deepEqual(properties("query_tasks").status?.enum, TaskStatus.options);
  // save_memory categories are exactly the Memory categories.
  assert.deepEqual(properties("save_memory").category?.enum, MemoryCategory.options);
});

test("the spec's product rules are stated where the model reads them", () => {
  assert.match(tool("create_task").description ?? "", /ONE task/);
  assert.match(tool("update_task_items").description ?? "", /fuzzy/i);
  assert.match(tool("save_memory").description ?? "", /explicit/i);
  assert.match(tool("draft_message").description ?? "", /nothing is sent/i);
  assert.match(tool("propose_calendar_event").description ?? "", /NEVER claim/i);
  assert.match(tool("propose_calendar_move").description ?? "", /NEVER claim/i);
  // The generation UX contract rides in the description: interview first,
  // acknowledge before the wait, summarize under 60 words, never read the
  // plan aloud, never promise a body outcome by a date.
  assert.match(tool("generate_plan").description ?? "", /interview FIRST/);
  assert.match(tool("generate_plan").description ?? "", /Give me a minute/);
  assert.match(tool("generate_plan").description ?? "", /under\s+.?60 words/);
  assert.match(tool("generate_plan").description ?? "", /NEVER read the plan/);
  assert.match(tool("generate_plan").description ?? "", /never promise a body outcome/i);
  assert.deepEqual(properties("generate_plan").domain?.enum, [
    "fitness",
    "productivity",
    "learning",
  ]);
  // Adaptation is a diff with a one-sentence confirmation — never a rewrite.
  assert.match(tool("adapt_plan").description ?? "", /never a regeneration/i);
  assert.match(tool("adapt_plan").description ?? "", /ONE\s+sentence/);
  assert.match(tool("adapt_plan").description ?? "", /Everything\s+else stands/);
  assert.deepEqual(properties("adapt_plan").domain?.enum, [
    "fitness",
    "productivity",
    "learning",
  ]);
});

test("nothing dynamic can leak into the cached prefix", () => {
  const serialized = JSON.stringify(OTTO_TOOLS);
  // Fixed example dates are fine (they never vary); a leaked clock is not.
  // Today's date appearing anywhere in the prefix means someone interpolated
  // `new Date()` into static content.
  const today = new Date().toISOString().slice(0, 10);
  assert.ok(!serialized.includes(today), "today's date leaked into a tool definition");
  assert.ok(!buildStaticPrefix("Boss").includes(today), "today's date leaked into the identity block");
  // Serialization is deterministic: same bytes on every call.
  assert.equal(serialized, JSON.stringify(OTTO_TOOLS));
});

test("tools + identity clear Sonnet's 1024-token cache floor with margin", () => {
  const prefixTokens =
    estimateTokens(JSON.stringify(OTTO_TOOLS)) + estimateTokens(buildStaticPrefix("Boss"));
  assert.ok(
    prefixTokens >= 1150,
    `cached prefix ≈${prefixTokens} tokens — too close to the 1024 minimum, fatten the descriptions`,
  );
});
