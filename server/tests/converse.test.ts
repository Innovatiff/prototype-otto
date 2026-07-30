import { strict as assert } from "node:assert";
import { test } from "node:test";

import { TurnEvent } from "@otto/shared";

import type { LlmTurnResult, LlmUsage } from "../src/llm/anthropic.js";
import { sseMessage, streamLlmTurn, type EventSink } from "../src/routes/converse.js";

/** Parses one SSE message back into a validated TurnEvent. */
function decode(chunk: string): TurnEvent {
  assert.match(chunk, /^data: [^\n]*\n\n$/, "one single-line data field per message");
  const json: unknown = JSON.parse(chunk.slice("data: ".length, -2));
  return TurnEvent.parse(json);
}

function makeSink(): { sink: EventSink; chunks: string[]; close: () => void } {
  const chunks: string[] = [];
  let closed = false;
  const sink: EventSink = {
    write: (chunk: string): void => {
      chunks.push(chunk);
    },
    get closed(): boolean {
      return closed;
    },
  };
  return {
    sink,
    chunks,
    close: () => {
      closed = true;
    },
  };
}

const USAGE: LlmUsage = {
  inputTokens: 42,
  outputTokens: 7,
  cacheReadTokens: 0,
  cacheCreationTokens: 0,
};

/**
 * A fake model turn: yields each delta asynchronously (one microtask apart,
 * like real network chunks), then resolves with the given result. Keeps
 * yielding after the sink closes — exactly what an in-flight API stream does
 * until its abort lands — so the relay's own gating is what's under test.
 */
function fakeTurn(
  deltas: string[],
  result: Partial<LlmTurnResult> = {},
): (onToken: (text: string) => void) => Promise<LlmTurnResult> {
  return async (onToken) => {
    for (const delta of deltas) {
      await new Promise((resolve) => {
        setImmediate(resolve);
      });
      onToken(delta);
    }
    return { usage: USAGE, stopReason: "end_turn", aborted: false, ...result };
  };
}

test("relays each delta as a token event the moment it arrives, then done", async () => {
  const { sink, chunks } = makeSink();
  const seenAtFirstToken: number[] = [];
  const { tokensWritten, result } = await streamLlmTurn(
    sink,
    (onToken) =>
      fakeTurn(["Hel", "lo ", "there."])((text) => {
        seenAtFirstToken.push(chunks.length);
        onToken(text);
      }),
    (r) => ({ tier: "sonnet", usage: r.usage }),
  );

  assert.equal(tokensWritten, 3);
  assert.equal(result.stopReason, "end_turn");
  assert.equal(chunks.length, 4);

  const events = chunks.map(decode);
  const tokens = events.slice(0, 3);
  for (const event of tokens) {
    assert.equal(event.type, "token");
  }
  assert.equal(tokens.map((event) => event.data).join(""), "Hello there.");
  // Each delta was written before the next arrived — streamed, not batched.
  assert.deepEqual(seenAtFirstToken, [0, 1, 2]);

  const done = events[3];
  assert.ok(done !== undefined);
  assert.equal(done.type, "done");
  assert.deepEqual(done.data, { tier: "sonnet", usage: USAGE });
});

test("client disconnect stops token writes and suppresses done", async () => {
  const { sink, chunks, close } = makeSink();
  const counting: EventSink = {
    write: (chunk: string): void => {
      sink.write(chunk);
      if (chunks.length === 2) {
        close(); // disconnect after the second token
      }
    },
    get closed(): boolean {
      return sink.closed;
    },
  };
  const { tokensWritten } = await streamLlmTurn(
    counting,
    fakeTurn(["a", "b", "c", "d"]),
    () => ({}),
  );
  assert.equal(tokensWritten, 2);
  assert.equal(chunks.length, 2);
  for (const event of chunks.map(decode)) {
    assert.equal(event.type, "token");
  }
});

test("an aborted turn never claims done, even on an open sink", async () => {
  const { sink, chunks } = makeSink();
  const { result } = await streamLlmTurn(
    sink,
    fakeTurn(["partial "], { aborted: true, stopReason: null }),
    () => ({}),
  );
  assert.equal(result.aborted, true);
  assert.equal(chunks.length, 1);
  const only = chunks.map(decode)[0];
  assert.ok(only !== undefined);
  assert.equal(only.type, "token");
});

test("empty deltas are dropped, a turn with no output still emits done", async () => {
  const { sink, chunks } = makeSink();
  const { tokensWritten } = await streamLlmTurn(sink, fakeTurn(["", ""]), () => ({ ok: true }));
  assert.equal(tokensWritten, 0);
  assert.equal(chunks.length, 1);
  const only = chunks.map(decode)[0];
  assert.ok(only !== undefined);
  assert.equal(only.type, "done");
  assert.deepEqual(only.data, { ok: true });
});

test("a turn that throws propagates — the route converts it to an error event", async () => {
  const { sink, chunks } = makeSink();
  await assert.rejects(
    streamLlmTurn(
      sink,
      async (onToken) => {
        onToken("half");
        throw new Error("overloaded");
      },
      () => ({}),
    ),
    /overloaded/,
  );
  // The token written before the failure stays written; no done follows.
  assert.equal(chunks.length, 1);
});

test("sseMessage frames a TurnEvent as a single data line", () => {
  const message = sseMessage({ type: "token", data: "hi " });
  assert.equal(message, 'data: {"type":"token","data":"hi "}\n\n');
});
