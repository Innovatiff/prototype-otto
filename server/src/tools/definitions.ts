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
    name: "show_visual",
    description:
      "Put an illustration on the user's screen — the stage — so they SEE " +
      "what you're talking about while you say it. Call this FIRST, before " +
      "answering, whenever the answer is about: current weather (kind " +
      "'weather'), today's schedule or free time (kind 'calendar'), " +
      "reminders, due items, or lists (kind 'reminders'), or their plans " +
      "and training sessions (kind 'plans'). The screen renders the data; " +
      "you speak the judgment — never read what's on screen aloud. At most " +
      "one call per turn, and only when the topic genuinely matches — never " +
      "for unrelated questions.",
    input_schema: {
      type: "object",
      properties: {
        kind: {
          type: "string",
          enum: ["weather", "calendar", "reminders", "plans"],
          description: "Which illustration fits the answer.",
        },
      },
      required: ["kind"],
    },
  },
  {
    name: "set_address_term",
    description:
      "Save what to call the owner. Use it when they tell you what they'd " +
      "like to be called — a name, a title, or nothing ('none' for no term " +
      "of address, ever). Ask ONLY when the dynamic context says no " +
      "confirmed term is on file, ONCE, casually, woven into a natural " +
      "moment — never as an interrogation, never twice. After saving, " +
      "acknowledge in a few words and move on.",
    input_schema: {
      type: "object",
      properties: {
        term: {
          type: "string",
          description: "The term exactly as they want it, or 'none'.",
        },
      },
      required: ["term"],
    },
  },
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
      "context matches case-insensitively; status defaults to 'active'. " +
      "Call this before answering any question about lists, errands, or " +
      "reminders — never answer from memory of the conversation alone.",
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
    name: "propose_calendar_event",
    description:
      "Propose adding ONE calendar event. Nothing is written by this call: " +
      "the user sees a confirmation card on their device, confirms by voice " +
      "or tap, and the write happens there — verified by reading the event " +
      "back. NEVER claim the event was created; say you've set it up for " +
      "their confirmation. Compute concrete ISO datetimes with offset from " +
      "the current date/time in your context.",
    input_schema: {
      type: "object",
      properties: {
        title: { type: "string" },
        startsAt: {
          type: "string",
          description: "ISO 8601 with offset, e.g. 2026-03-06T14:00:00-05:00.",
        },
        endsAt: { type: "string", description: "ISO 8601 with offset." },
        location: { type: "string" },
        notes: { type: "string" },
      },
      required: ["title", "startsAt", "endsAt"],
    },
  },
  {
    name: "propose_calendar_move",
    description:
      "Propose moving an existing calendar event the user named. Nothing is " +
      "written by this call: the device resolves the event by title, shows a " +
      "confirmation card, and writes only on the user's confirmation — " +
      "verified by read-back. NEVER claim the move happened. Omit newEndsAt " +
      "to keep the event's current duration.",
    input_schema: {
      type: "object",
      properties: {
        eventTitle: {
          type: "string",
          description: "The event as the user said it, e.g. 'dentist appointment'.",
        },
        newStartsAt: { type: "string", description: "ISO 8601 with offset." },
        newEndsAt: { type: "string", description: "ISO 8601 with offset; omit to keep duration." },
      },
      required: ["eventTitle", "newStartsAt"],
    },
  },
  {
    name: "generate_plan",
    description:
      "Generate a complete multi-week plan (workout program, weekly " +
      "structure, study plan). Run the short constraints interview FIRST — " +
      "see PLAN INTERVIEWS. Building takes about a minute, so before " +
      "calling, tell them in one short line, e.g. 'Give me a minute — I'm " +
      "building this out.' The full plan renders on their screen; the " +
      "result gives you summary facts. Speak a summary from them in under " +
      "60 words — NEVER read the plan itself aloud, and never promise a " +
      "body outcome by a date. Pass every constraint they gave and every " +
      "relevant memory (injuries, equipment, schedule).",
    input_schema: {
      type: "object",
      properties: {
        domain: { type: "string", enum: ["fitness", "productivity", "learning"] },
        goal: { type: "string", description: "Their goal in their words." },
        horizonDays: { type: "integer", description: "Plan length in days, 7-180." },
        daysPerWeek: { type: "integer", description: "Fitness: training days available." },
        minutesPerSession: { type: "integer", description: "Fitness: minutes per session." },
        equipment: {
          type: "array",
          items: { type: "string" },
          description: "Fitness: exactly what they have, e.g. ['dumbbells', 'bench'].",
        },
        limitations: {
          type: "array",
          items: { type: "string" },
          description: "Injuries or constraints, e.g. ['left shoulder'].",
        },
        experienceLevel: { type: "string" },
        workType: { type: "string", description: "Productivity: what their work is." },
        peakHours: { type: "string", description: "Productivity: when they're sharpest." },
        fixedCommitments: {
          type: "array",
          items: { type: "string" },
          description: "Productivity: immovable blocks, e.g. ['standup 9:30 weekdays'].",
        },
        monthGoal: { type: "string", description: "Productivity: this month's aim." },
        currentLevel: { type: "string", description: "Learning: where they are now." },
        minutesPerDay: { type: "integer", description: "Learning: daily minutes available." },
        targetDate: { type: "string", description: "Learning: exam or deadline, as they said it." },
        motivation: { type: "string", description: "Learning: why — changes the approach." },
        notes: { type: "string", description: "Anything else material." },
      },
      required: ["domain", "goal"],
    },
  },
  {
    name: "create_experience",
    description:
      "Plan a full EXPERIENCE — a trip, a date, a day out — researched, " +
      "budgeted UNDER what they gave (the buffer is deliberate), presented " +
      "by the device as an illustrated spoken tour, and saved to their " +
      "Voyages. INTERVIEW FIRST: never call this while the budget, the " +
      "destination or occasion, or the duration (for trips) is unknown — " +
      "and NEVER guess a budget. Ask for what's missing ONE question per " +
      "turn, three questions maximum, each with a concrete suggestion " +
      "('Beach or city? Casco Viejo eats well on a budget.'). When they " +
      "already said everything, skip straight to the call. Check MEMORIES " +
      "before asking anything — skip questions memory already answers, and " +
      "reference past tastes ('Casco Viejo vibe again, or somewhere new?'). " +
      "AFTER the tool " +
      "returns, say ONE handoff line only ('Here's the evening.') — the " +
      "device narrates and illustrates the whole plan itself; do not " +
      "describe it, do not read any items, do not list prices. The device " +
      "then asks if they want changes: when they do, call this tool AGAIN " +
      "with the FULL revised request — everything kept plus what changed " +
      "('same Panama trip, keep the hotel, swap day 2 dinner for seafood').",
    input_schema: {
      type: "object",
      properties: {
        kind: { type: "string", enum: ["trip", "date", "outing"] },
        request: {
          type: "string",
          description:
            "The full ask plus EVERYTHING learned in the interview: who, " +
            "where or occasion, when, how long, tastes, constraints.",
        },
        budgetAmount: {
          type: "integer",
          description: "The stated budget in whole units. From the user, never assumed.",
        },
        currency: {
          type: "string",
          description: "ISO 4217, e.g. 'USD'. Omit for USD.",
        },
      },
      required: ["kind", "request", "budgetAmount"],
    },
  },
  {
    name: "create_walkthrough",
    description:
      "Build a step-by-step guided walkthrough the user can EXECUTE right " +
      "now with Otto talking them through it hands-free — cook a dish, " +
      "change a tire, fix a leaky faucet, assemble furniture, pack for a " +
      "trip, a focused errand run. This is the DOING tool: one session, " +
      "done today. Use generate_plan instead for multi-week programs. " +
      "Don't interview: ask at most ONE clarifying question (servings? " +
      "which car?) and only if the task is unbuildable without it — and " +
      "fill `notes` from MEMORIES first (skill level, portions, equipment, " +
      "past feedback) instead of asking. The " +
      "finished walkthrough appears on screen with a Start button — never " +
      "read the steps aloud. Say it's ready, the honest minutes, and that " +
      "they can say 'start' whenever. If the tool refuses (hazardous " +
      "task), relay the refusal plainly with its alternative.",
    input_schema: {
      type: "object",
      properties: {
        goal: {
          type: "string",
          description: "What they want to do, specific: 'chicken alfredo for two'.",
        },
        domain: {
          type: "string",
          enum: ["cooking", "repair", "errand", "fitness", "chores", "learning", "other"],
          description: "Closest fit — drives the on-screen illustration.",
        },
        notes: {
          type: "string",
          description:
            "Anything they mentioned that shapes the steps: servings, skill, " +
            "tools on hand, dietary limits. Omit when nothing was said.",
        },
      },
      required: ["goal", "domain"],
    },
  },
  {
    name: "adapt_plan",
    description:
      "Patch the user's ACTIVE plan when life changed — an injury, missed " +
      "days, new availability. A diff, never a regeneration: everything not " +
      "affected stands, and the plan keeps its history as a new version. " +
      "Use only when your context lists an active plan in that domain, and " +
      "pass what changed in the user's own words. Afterwards confirm in ONE " +
      "sentence — 'Swapped overhead pressing out for two weeks. Everything " +
      "else stands.' — never re-describe the whole plan.",
    input_schema: {
      type: "object",
      properties: {
        domain: { type: "string", enum: ["fitness", "productivity", "learning"] },
        change: {
          type: "string",
          description:
            "What changed, in the user's words, e.g. 'left shoulder is " +
            "bothering them' or 'missed Tuesday and Wednesday'.",
        },
      },
      required: ["domain", "change"],
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
  {
    name: "create_automation",
    description:
      "Create a recurring automation that runs on its own schedule — " +
      "'every Friday afternoon, check my calendar and text Rachel a " +
      "summary'. Map spoken times: morning=08:00, midday/noon=12:00, " +
      "afternoon=15:30, evening=18:30, night=21:00. If NO time can be " +
      "inferred at all, ask ONE short clarifying question first — one, " +
      "never two. The instruction is stored verbatim and executed with the " +
      "user's real calendar, tasks, and memory each time it fires; " +
      "composite instructions (check X AND Y, then draft Z) are fine. " +
      "After the tool returns, confirm in ONE short line using the " +
      "returned schedule, e.g. 'Done. Every Friday at 3:30.'",
    input_schema: {
      type: "object",
      properties: {
        label: {
          type: "string",
          description: "Short name shown in settings, e.g. 'Text Rachel gym check'.",
        },
        rrule: {
          type: "string",
          description:
            "FREQ=DAILY or FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR,SA,SU (subset " +
            "only — e.g. 'FREQ=WEEKLY;BYDAY=FR' for every Friday).",
        },
        timeOfDay: {
          type: "string",
          description: "Local wall-clock 24h 'HH:mm', zero-padded — 'afternoon' is '15:30'.",
        },
        instruction: {
          type: "string",
          description:
            "What Otto should DO each time, verbatim from the user, e.g. " +
            "'Check my calendar and my task list, then draft a text to " +
            "Rachel asking if she's coming to the gym.'",
        },
      },
      required: ["label", "rrule", "timeOfDay", "instruction"],
    },
  },
  {
    name: "manage_automations",
    description:
      "List, enable, disable, or delete the user's automations (the " +
      "morning brief, meeting prep, and anything they created). Use " +
      "op='list' to see them before answering questions about them. For " +
      "enable/disable/delete, pass the automation's name as the user said " +
      "it — matching is fuzzy. Built-in automations can be disabled but " +
      "never deleted. Confirm changes in one short sentence.",
    input_schema: {
      type: "object",
      properties: {
        op: {
          type: "string",
          enum: ["list", "enable", "disable", "delete"],
          description: "What to do.",
        },
        label: {
          type: "string",
          description: "Which automation, as spoken — required for everything except 'list'.",
        },
      },
      required: ["op"],
    },
  },
];
