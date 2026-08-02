import { strict as assert } from "node:assert";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, test } from "node:test";
import { readLastTranscriptTurns } from "./data.js";

function withTranscript(lines: string[], run: (path: string) => void): void {
  const directory = mkdtempSync(join(tmpdir(), "kanban-transcript-"));
  const path = join(directory, "session.jsonl");
  try {
    writeFileSync(path, `${lines.join("\n")}\n`);
    run(path);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

describe("readLastTranscriptTurns", () => {
  test("reads Claude user and assistant messages", () => {
    withTranscript(
      [
        JSON.stringify({ type: "user", timestamp: "1", message: { content: "hello" } }),
        JSON.stringify({
          type: "assistant",
          timestamp: "2",
          message: { content: [{ type: "text", text: "hi" }] },
        }),
      ],
      (path) => {
        assert.deepEqual(readLastTranscriptTurns(path, 5), [
          { role: "user", text: "hello", timestamp: "1" },
          { role: "assistant", text: "hi", timestamp: "2" },
        ]);
      }
    );
  });

  test("reads Codex event messages without duplicating response items", () => {
    withTranscript(
      [
        JSON.stringify({
          type: "event_msg",
          timestamp: "1",
          payload: { type: "user_message", message: "inspect this" },
        }),
        JSON.stringify({
          type: "event_msg",
          timestamp: "2",
          payload: { type: "agent_message", message: "working on it" },
        }),
        JSON.stringify({
          type: "response_item",
          payload: { type: "message", content: "duplicate" },
        }),
      ],
      (path) => {
        assert.deepEqual(readLastTranscriptTurns(path, 5), [
          { role: "user", text: "inspect this", timestamp: "1" },
          { role: "assistant", text: "working on it", timestamp: "2" },
        ]);
      }
    );
  });
});
