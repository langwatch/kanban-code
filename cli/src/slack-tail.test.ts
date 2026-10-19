import { test, describe } from "node:test";
import { strict as assert } from "node:assert";
import { mkdtempSync, mkdirSync, writeFileSync, appendFileSync, utimesSync, statSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { newTailCursor, switchTail, capPosts, MAX_POSTS_PER_POLL } from "./slack/tail.js";
import { findCodexRollout } from "./data.js";

const CWD = "/home/ubuntu/agent-workspaces/pr-reviewer";

function rolloutLine(message: string): string {
  return JSON.stringify({ type: "event_msg", payload: { type: "agent_message", message } }) + "\n";
}

function writeRollout(dir: string, name: string, messages: string[]): string {
  mkdirSync(dir, { recursive: true });
  const path = join(dir, name);
  const meta = JSON.stringify({ type: "session_meta", payload: { cwd: CWD } }) + "\n";
  writeFileSync(path, meta + messages.map(rolloutLine).join(""));
  return path;
}

function touch(path: string, atSeconds: number): void {
  utimesSync(path, atSeconds, atSeconds);
}

function unreadMessages(path: string, offset: number): string[] {
  return readFileSync(path, "utf-8")
    .slice(offset)
    .split("\n")
    .filter((l) => l.trim())
    .map((l) => JSON.parse(l))
    .filter((o) => o.payload?.type === "agent_message")
    .map((o) => o.payload.message);
}

describe("switchTail", () => {
  test("two rollouts of one agent taking turns never replay the old backlog", () => {
    const home = mkdtempSync(join(tmpdir(), "kanban-tail-"));
    const prevHome = process.env.CODEX_HOME;
    process.env.CODEX_HOME = home;
    try {
      const sessions = join(home, "sessions");
      const backlog = Array.from({ length: 500 }, (_, i) => `old review ${i}`);
      const old = writeRollout(join(sessions, "2026/08/03"), "rollout-2026-08-03T12-47-14-a.jsonl", backlog);
      touch(old, 1000);

      // Bridge starts: the August rollout is the only one, read from its end.
      const cursor = newTailCursor({ path: findCodexRollout(CWD) });
      assert.equal(cursor.path, old);
      assert.equal(cursor.offset, statSync(old).size);

      // A new session starts: its rollout is born after the bridge followed the old one.
      const fresh = writeRollout(join(sessions, "2026/10/19"), "rollout-2026-10-19T09-49-26-b.jsonl", ["new session hello"]);
      touch(fresh, 2000);
      assert.equal(switchTail({ cursor, latest: findCodexRollout(CWD) }), true);
      assert.equal(cursor.path, fresh);
      assert.deepEqual(unreadMessages(fresh, cursor.offset), ["new session hello"]);
      cursor.offset = statSync(fresh).size;

      // `codex resume --last` appends to the August rollout, which becomes newest again.
      appendFileSync(old, rolloutLine("resumed reply"));
      touch(old, 3000);
      assert.equal(switchTail({ cursor, latest: findCodexRollout(CWD) }), true);
      assert.equal(cursor.path, old);
      assert.deepEqual(unreadMessages(old, cursor.offset), ["resumed reply"]);
      cursor.offset = statSync(old).size;

      // And back to the new one: only what it gained since we left it.
      appendFileSync(fresh, rolloutLine("second turn"));
      touch(fresh, 4000);
      switchTail({ cursor, latest: findCodexRollout(CWD) });
      assert.deepEqual(unreadMessages(fresh, cursor.offset), ["second turn"]);
    } finally {
      if (prevHome === undefined) delete process.env.CODEX_HOME;
      else process.env.CODEX_HOME = prevHome;
    }
  });

  test("a file that already existed before the bridge followed the current one starts at its end", () => {
    const dir = mkdtempSync(join(tmpdir(), "kanban-tail-"));
    const a = writeRollout(dir, "rollout-a.jsonl", ["a1"]);
    const b = writeRollout(dir, "rollout-b.jsonl", ["b1", "b2"]);
    const cursor = newTailCursor({ path: a, nowMs: Date.now() + 60_000 });
    switchTail({ cursor, latest: b });
    assert.equal(cursor.offset, statSync(b).size);
  });

  test("no switch when the newest file is the current one", () => {
    const dir = mkdtempSync(join(tmpdir(), "kanban-tail-"));
    const a = writeRollout(dir, "rollout-a.jsonl", ["a1"]);
    const cursor = newTailCursor({ path: a });
    assert.equal(switchTail({ cursor, latest: a }), false);
    assert.equal(switchTail({ cursor, latest: undefined }), false);
  });
});

describe("capPosts", () => {
  const post = (text: string) => ({ kind: "text", text });

  test("passes a normal poll through", () => {
    const posts = Array.from({ length: MAX_POSTS_PER_POLL }, (_, i) => post(`p${i}`));
    assert.equal(capPosts(posts, post), posts);
  });

  test("replaces a backlog with one notice", () => {
    const posts = Array.from({ length: MAX_POSTS_PER_POLL + 5 }, (_, i) => post(`p${i}`));
    assert.deepEqual(capPosts(posts, post), [post(`skipped ${MAX_POSTS_PER_POLL + 5} old lines`)]);
  });
});
