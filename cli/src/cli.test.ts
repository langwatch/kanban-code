/**
 * End-to-end CLI tests: run `tsx src/kanban.ts <args>` with a sandboxed
 * HOME directory so channels live in a tmp tree. No real tmux required —
 * we set --no-fanout or omit tmux detection.
 */

import { test, describe, beforeEach, afterEach } from "node:test";
import { strict as assert } from "node:assert";
import { execFileSync } from "node:child_process";
import { chmodSync, mkdtempSync, rmSync, writeFileSync, mkdirSync, existsSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const CLI = resolve(import.meta.dirname, "kanban.ts");

function runCli(args: string[], env: NodeJS.ProcessEnv = {}): { stdout: string; stderr: string; code: number } {
  try {
    const stdout = execFileSync("npx", ["tsx", CLI, ...args], {
      encoding: "utf-8",
      env: { ...process.env, ...env },
    });
    return { stdout, stderr: "", code: 0 };
  } catch (e: any) {
    return {
      stdout: String(e.stdout ?? ""),
      stderr: String(e.stderr ?? ""),
      code: e.status ?? 1,
    };
  }
}

let home: string;

function seedLinks(links: unknown[]): void {
  const kanbanDir = join(home, ".kanban-code");
  mkdirSync(kanbanDir, { recursive: true });
  writeFileSync(join(kanbanDir, "links.json"), JSON.stringify({ links }, null, 2));
}

function seedFakeTmux(sessionName: string): { binDir: string; logPath: string } {
  const binDir = join(home, "bin");
  const logPath = join(home, "tmux.log");
  mkdirSync(binDir, { recursive: true });
  const tmuxPath = join(binDir, "tmux");
  writeFileSync(
    tmuxPath,
    `#!/bin/sh
printf '%s\\n' "$*" >> "$TMUX_LOG"
if [ "$1" = "display-message" ]; then
  printf '%s\\n' "$TMUX_SESSION_NAME"
  exit 0
fi
exit 0
`
  );
  chmodSync(tmuxPath, 0o755);
  return { binDir, logPath };
}

describe("kanban channel (CLI e2e)", () => {
  beforeEach(() => { home = mkdtempSync(join(tmpdir(), "kanban-cli-e2e-")); });
  afterEach(() => { rmSync(home, { recursive: true, force: true }); });

  test("create → list", () => {
    const env = { HOME: home };
    seedLinks([]);
    let r = runCli(["channel", "create", "general", "--as-user"], env);
    assert.equal(r.code, 0, r.stderr);
    assert.match(r.stdout, /Created #general/);

    r = runCli(["channel", "list", "--json"], env);
    assert.equal(r.code, 0, r.stderr);
    const rows = JSON.parse(r.stdout);
    assert.equal(rows.length, 1);
    assert.equal(rows[0].name, "general");
  });

  test("join, send (no fanout), history, members", () => {
    const env = { HOME: home };
    // Two cards with tmux-linked sessions so auto-detect could work if we wanted.
    seedLinks([
      {
        id: "card_alice",
        name: "alice-card",
        column: "in_progress",
        createdAt: new Date().toISOString(),
        updatedAt: new Date().toISOString(),
        tmuxLink: { sessionName: "sess-alice" },
        isRemote: false,
        prLinks: [],
        manualOverrides: {},
        source: "manual",
        manuallyArchived: false,
      },
      {
        id: "card_bob",
        name: "bob-card",
        column: "in_progress",
        createdAt: new Date().toISOString(),
        updatedAt: new Date().toISOString(),
        tmuxLink: { sessionName: "sess-bob" },
        isRemote: false,
        prLinks: [],
        manualOverrides: {},
        source: "manual",
        manuallyArchived: false,
      },
    ]);
    runCli(["channel", "create", "general", "--as-user"], env);

    let r = runCli(["channel", "join", "general", "--as", "alice"], env);
    assert.equal(r.code, 0, r.stderr);
    r = runCli(["channel", "join", "general", "--as", "bob"], env);
    assert.equal(r.code, 0, r.stderr);

    // Send from user — --no-fanout so we don't try to reach real tmux sessions.
    r = runCli(
      ["channel", "send", "general", "hello", "team", "--as-user", "--no-fanout"],
      env
    );
    assert.equal(r.code, 0, r.stderr);
    assert.match(r.stdout, /@\w+ → #general: hello team/);

    // History should include join events + our message.
    r = runCli(["channel", "history", "general", "--json"], env);
    assert.equal(r.code, 0, r.stderr);
    const msgs = JSON.parse(r.stdout);
    const bodies = msgs.map((m: any) => m.body);
    assert.ok(bodies.some((b: string) => b.includes("joined")));
    assert.ok(bodies.some((b: string) => b === "hello team"));

    // Members should list 3 (human user + alice + bob). The human handle
    // is derived from the system user, so we just assert the count and
    // that alice/bob are present.
    r = runCli(["channel", "members", "general", "--json"], env);
    assert.equal(r.code, 0, r.stderr);
    const members = JSON.parse(r.stdout);
    assert.equal(members.length, 3);
    const handles = members.map((m: any) => m.handle);
    assert.ok(handles.includes("alice"));
    assert.ok(handles.includes("bob"));
  });

  test("create duplicate fails gracefully", () => {
    const env = { HOME: home };
    seedLinks([]);
    runCli(["channel", "create", "ops", "--as-user"], env);
    const r = runCli(["channel", "create", "ops", "--as-user"], env);
    assert.notEqual(r.code, 0);
    assert.match(r.stderr + r.stdout, /already exists/);
  });

  test("leave removes membership", () => {
    const env = { HOME: home };
    seedLinks([]);
    runCli(["channel", "create", "general", "--as-user"], env);
    runCli(["channel", "join", "general", "--as", "alice"], env);
    let r = runCli(["channel", "members", "general", "--json"], env);
    assert.equal(JSON.parse(r.stdout).length, 2);

    r = runCli(["channel", "leave", "general", "--as", "alice"], env);
    assert.equal(r.code, 0, r.stderr);

    r = runCli(["channel", "members", "general", "--json"], env);
    const rows = JSON.parse(r.stdout);
    assert.equal(rows.length, 1);
    // Remaining member is the human (derived handle).
    assert.equal(rows[0].cardId, null);
  });

  test("send errors on unknown channel", () => {
    const env = { HOME: home };
    seedLinks([]);
    const r = runCli(["channel", "send", "nope", "hi", "--as-user"], env);
    assert.notEqual(r.code, 0);
    assert.match(r.stderr + r.stdout, /does not exist/);
  });

  test("delete removes channel metadata", () => {
    const env = { HOME: home };
    seedLinks([]);
    runCli(["channel", "create", "transient", "--as-user"], env);
    let r = runCli(["channel", "delete", "transient"], env);
    assert.equal(r.code, 0, r.stderr);
    r = runCli(["channel", "list", "--json"], env);
    assert.deepEqual(JSON.parse(r.stdout), []);
  });

  test("DM send to unknown handle fails", () => {
    const env = { HOME: home };
    seedLinks([]);
    runCli(["channel", "create", "ops", "--as-user"], env);
    const r = runCli(["dm", "send", "nobody", "hi", "--as-user"], env);
    assert.notEqual(r.code, 0);
    assert.match(r.stderr + r.stdout, /Unknown handle/);
  });

  test("self-compact targets current card tmux and sends follow-up prompt", () => {
    const sessionName = "sess-self";
    const { binDir, logPath } = seedFakeTmux(sessionName);
    const env = {
      HOME: home,
      PATH: `${binDir}:${process.env.PATH ?? ""}`,
      TMUX: "/tmp/tmux-123/default,1,0",
      TMUX_SESSION_NAME: sessionName,
      TMUX_LOG: logPath,
    };
    seedLinks([
      {
        id: "card_self",
        name: "self card",
        column: "in_progress",
        createdAt: new Date().toISOString(),
        updatedAt: new Date().toISOString(),
        tmuxLink: { sessionName },
        isRemote: false,
        prLinks: [],
        manualOverrides: {},
        source: "manual",
        manuallyArchived: false,
      },
    ]);

    const r = runCli(["self-compact", "Continue", "after", "compact."], env);
    assert.equal(r.code, 0, r.stderr);
    assert.match(r.stdout, /Sent \/compact to sess-self with post-compact follow-up/);

    const log = readFileSync(logPath, "utf-8");
    assert.match(log, /display-message -p #S/);
    assert.match(log, /send-keys -t sess-self Enter/);
    assert.match(log, /send-keys -t sess-self Escape/);
    assert.match(log, /send-keys -t sess-self \/compact Enter/);
    assert.match(log, /set-buffer Continue after compact\./);
    assert.match(log, /paste-buffer -p -t sess-self/);
  });

  test("self-compact explains when current tmux is not linked to a card", () => {
    const sessionName = "unlinked";
    const { binDir, logPath } = seedFakeTmux(sessionName);
    const env = {
      HOME: home,
      PATH: `${binDir}:${process.env.PATH ?? ""}`,
      TMUX: "/tmp/tmux-123/default,1,0",
      TMUX_SESSION_NAME: sessionName,
      TMUX_LOG: logPath,
    };
    seedLinks([]);

    const r = runCli(["self-compact"], env);
    assert.notEqual(r.code, 0);
    assert.match(r.stderr + r.stdout, /not linked to any Kanban Code card/);
    assert.match(r.stderr + r.stdout, /executed from an agent inside a tmux session/);
  });
});
