/**
 * Otto's tool definitions — the model-facing contract for acting on tasks,
 * memories, and messages.
 *
 * These serialize into the prompt AHEAD of the system blocks, inside the
 * cached prefix (the cache_control breakpoint sits on the static system
 * block, which caches everything before it — tools included). Two rules
 * follow from that:
 *
 *   1. Definitions must be byte-stable across turns. Nothing dynamic here —
 *      no dates, no per-user content.
 *   2. Editing any description invalidates every user's prompt cache on the
 *      next deploy. Fine — but know that's what a wording tweak costs.
 *
 * Descriptions are deliberately rich: the model reads them every turn, and
 * the product rules they carry (ONE task per errand, fuzzy item matching,
 * drafts never send) are enforced here first.
 */
import type Anthropic from "@anthropic-ai/sdk";

export const OTTO_TOOLS: readonly Anthropic.Tool[] = [
  {
    name: "create_task",
    description:
      "Create exactly ONE task. A multi-item errand is ONE list task with " +
      "items[] — never several tasks. 'Buy onions, carrots, and milk at " +
      "Walmart' is ONE task: intent 'list', context 'Walmart', three items. " +
      "Use intent 'reminder' with triggerAt only when the user names a time; " +
      "shopping and errand lists tied to a place get intent 'list' with " +
      "context and NO trigger. Use 'capture' for free-form notes to keep. " +
      "Do not create a task the user already has — check active tasks in " +
      "your context first and add to an existing list instead.",
    input_schema: {
      type: "object",
      properties: {
        intent: {
          type: "string",
          enum: ["reminder", "list", "capture"],
          description: "reminder = fires at a time; list = items to check off; capture = a kept note.",
        },
        title: {
          type: "string",
          description: "Short human title, e.g. 'Walmart list' or 'Call the dentist'.",
        },
        items: {
          type: "array",
          items: { type: "string" },
          description: "For lists: one entry per item, exactly as the user said them.",
        },
        context: {
          type: "string",
          description: "Where or when this applies, e.g. 'Walmart', 'Home Depot', 'work'.",
        },
        triggerAt: {
          type: "string",
          description:
            "ISO 8601 datetime with offset for reminders, e.g. 2026-03-05T16:00:00-05:00. " +
            "Omit for lists and captures.",
        },
      },
      required: ["intent", "title"],
    },
  },
  {
    name: "query_tasks",
    description:
      "Find the user's tasks. All filters optional and combined with AND; " +
      "context matches case-insensitively. Call this before answering any " +
      "question about lists, errands, or reminders — never answer from " +
      "memory of the conversation alone.",
    input_schema: {
      type: "object",
      properties: {
        intent: { type: "string", enum: ["reminder", "list", "capture", "message"] },
        context: { type: "string", description: "e.g. 'Walmart'." },
        status: { type: "string", enum: ["active", "completed", "dismissed"] },
      },
      required: [],
    },
  },
  {
    name: "update_task_items",
    description:
      "Check off, uncheck, or add items on an existing list task. Item " +
      "references are matched by fuzzy text against the stored items — 'the " +
      "onions' matches 'onions' — so pass the user's words as spoken. Use " +
      "query_tasks first if you do not have the taskId.",
    input_schema: {
      type: "object",
      properties: {
        taskId: { type: "string" },
        check: { type: "array", items: { type: "string" }, description: "Items to mark done." },
        uncheck: { type: "array", items: { type: "string" }, description: "Items to reopen." },
        add: { type: "array", items: { type: "string" }, description: "New items to append." },
      },
      required: ["taskId"],
    },
  },
  {
    name: "complete_task",
    description:
      "Mark a whole task completed — a finished list, a done reminder, a " +
      "handled capture. Not for checking off single items; that is " +
      "update_task_items.",
    input_schema: {
      type: "object",
      properties: {
        taskId: { type: "string" },
      },
      required: ["taskId"],
    },
  },
  {
    name: "save_memory",
    description:
      "Store ONE atomic, durable fact the user explicitly asked you to " +
      "remember ('remember that I don't eat pork'). Not for passing moods or " +
      "today-only facts, and never compound — split 'I run Tuesdays and " +
      "don't eat pork' into two calls. Passive extraction happens elsewhere; " +
      "this tool is only for explicit statements.",
    input_schema: {
      type: "object",
      properties: {
        category: {
          type: "string",
          enum: ["identity", "schedule", "preference", "constraint", "goal", "context"],
        },
        content: {
          type: "string",
          description: "The single fact, stated plainly, e.g. 'Does not eat pork.'",
        },
      },
      required: ["category", "content"],
    },
  },
  {
    name: "draft_message",
    description:
      "Produce a message draft for the user to send. Returns the draft only " +
      "— nothing is sent, ever; the phone opens a compose sheet and the user " +
      "taps send themselves. Write the body in the user's voice, plain and " +
      "brief, no sign-off unless they asked for one.",
    input_schema: {
      type: "object",
      properties: {
        recipientName: {
          type: "string",
          description: "The contact name as the user said it, e.g. 'Marissa'.",
        },
        body: { type: "string", description: "The message text, ready to send." },
      },
      required: ["recipientName", "body"],
    },
  },
];
