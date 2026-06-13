import { test, describe, beforeEach, afterEach } from "node:test";
import { strict as assert } from "node:assert";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { claudeTranscriptTurnEnded, codexRolloutTurnEnded } from "./slack/bridge.js";

let dir: string;
beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "kanban-bridge-restore-"));
});
afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

function writeJsonl(path: string, objs: any[]): void {
  writeFileSync(path, objs.map((o) => JSON.stringify(o)).join("\n") + "\n");
}

describe("claudeTranscriptTurnEnded", () => {
  test("returns true when the LAST assistant message has stop_reason end_turn", () => {
    const path = join(dir, "transcript.jsonl");
    writeJsonl(path, [
      { type: "user", message: { content: "go" } },
      { type: "assistant", message: { stop_reason: "tool_use", content: [] } },
      { type: "assistant", message: { stop_reason: "end_turn", content: [{ type: "text", text: "done" }] } },
    ]);
    assert.equal(claudeTranscriptTurnEnded(path), true);
  });

  test("returns true on stop_sequence and refusal as well (other terminal reasons)", () => {
    for (const reason of ["stop_sequence", "refusal"]) {
      const path = join(dir, `t-${reason}.jsonl`);
      writeJsonl(path, [{ type: "assistant", message: { stop_reason: reason, content: [] } }]);
      assert.equal(claudeTranscriptTurnEnded(path), true, `reason=${reason} should be terminal`);
    }
  });

  test("returns false when the LAST assistant message is mid-turn (stop_reason: tool_use)", () => {
    const path = join(dir, "transcript.jsonl");
    writeJsonl(path, [
      { type: "assistant", message: { stop_reason: "end_turn", content: [] } }, // previous turn ended
      { type: "user", message: { content: "now do this" } },
      { type: "assistant", message: { stop_reason: "tool_use", content: [] } }, // mid-turn now
    ]);
    assert.equal(claudeTranscriptTurnEnded(path), false);
  });

  test("returns false on an empty / missing transcript", () => {
    assert.equal(claudeTranscriptTurnEnded(join(dir, "does-not-exist.jsonl")), false);
    const empty = join(dir, "empty.jsonl");
    writeFileSync(empty, "");
    assert.equal(claudeTranscriptTurnEnded(empty), false);
  });

  test("ignores trailing system / summary lines after the last assistant turn", () => {
    const path = join(dir, "transcript.jsonl");
    writeJsonl(path, [
      { type: "assistant", message: { stop_reason: "end_turn", content: [] } },
      { type: "system", subtype: "stop_hook_summary" },
      { type: "system", subtype: "turn_duration" },
    ]);
    assert.equal(claudeTranscriptTurnEnded(path), true);
  });
});

describe("codexRolloutTurnEnded", () => {
  test("returns true when task_complete appears after the last user_message", () => {
    const path = join(dir, "rollout.jsonl");
    writeJsonl(path, [
      { type: "event_msg", payload: { type: "user_message", message: "go" } },
      { type: "event_msg", payload: { type: "agent_message", message: "done", phase: "final_answer" } },
      { type: "event_msg", payload: { type: "task_complete", last_agent_message: "done" } },
    ]);
    assert.equal(codexRolloutTurnEnded(path), true);
  });

  test("returns false when a user_message landed AFTER the last task_complete (mid-turn)", () => {
    const path = join(dir, "rollout.jsonl");
    writeJsonl(path, [
      { type: "event_msg", payload: { type: "user_message", message: "go" } },
      { type: "event_msg", payload: { type: "task_complete", last_agent_message: "done" } },
      { type: "event_msg", payload: { type: "user_message", message: "and again" } },
    ]);
    assert.equal(codexRolloutTurnEnded(path), false);
  });

  test("returns false when there is no task_complete at all", () => {
    const path = join(dir, "rollout.jsonl");
    writeJsonl(path, [
      { type: "event_msg", payload: { type: "user_message", message: "go" } },
      { type: "event_msg", payload: { type: "agent_message", message: "still thinking" } },
    ]);
    assert.equal(codexRolloutTurnEnded(path), false);
  });

  test("returns false on an empty / missing rollout", () => {
    assert.equal(codexRolloutTurnEnded(join(dir, "does-not-exist.jsonl")), false);
  });
});
