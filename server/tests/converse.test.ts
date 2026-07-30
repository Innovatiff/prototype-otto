import { strict as assert } from "node:assert";
import { test } from "node:test";

import { TurnEvent } from "@otto/shared";

import { sseMessage, streamStubTurn, type EventSink } from "../src/routes/converse.js";

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

test("streams word by word with a delay, then done — visibly incremental", async () => {
  const { sink, chunks } = makeSink();
  const startedAt = Date.now();
  const written = await streamStubTurn(sink, "one two three four", { tier: "pcc" }, 10);
  const elapsed = Date.now() - startedAt;

  assert.equal(written, 4);
  assert.equal(chunks.length, 5);

  const events = chunks.map(decode);
  const tokens = events.slice(0, 4);
  for (const event of tokens) {
    assert.equal(event.type, "token");
  }
  assert.equal(tokens.map((event) => event.data).join(""), "one two three four");

  const done = events[4];
  assert.ok(done !== undefined);
  assert.equal(done.type, "done");
  assert.deepEqual(done.data, { tier: "pcc" });

  // Three inter-word delays of 10ms — the words cannot all arrive at once.
  assert.ok(elapsed >= 30, `elapsed ${elapsed}ms`);
});

test("whitespace runs collapse to single spaces", async () => {
  const { sink, chunks } = makeSink();
  await streamStubTurn(sink, "  hello   world \n", {}, 0);
  const events = chunks.map(decode);
  assert.equal(events.length, 3);
  assert.equal(events.slice(0, 2).map((event) => event.data).join(""), "hello world");
});

test("client disconnect stops the stream and suppresses done", async () => {
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
  const written = await streamStubTurn(counting, "a b c d e", {}, 1);
  assert.equal(written, 2);
  assert.equal(chunks.length, 2);
  for (const event of chunks.map(decode)) {
    assert.equal(event.type, "token");
  }
});

test("empty text emits only done", async () => {
  const { sink, chunks } = makeSink();
  const written = await streamStubTurn(sink, "   ", { tier: "local" }, 0);
  assert.equal(written, 0);
  assert.equal(chunks.length, 1);
  const only = chunks.map(decode)[0];
  assert.ok(only !== undefined);
  assert.equal(only.type, "done");
});

test("sseMessage frames a TurnEvent as a single data line", () => {
  const message = sseMessage({ type: "token", data: "hi " });
  assert.equal(message, 'data: {"type":"token","data":"hi "}\n\n');
});
