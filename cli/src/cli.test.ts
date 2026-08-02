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

function runCli(
  args: string[],
  env: NodeJS.ProcessEnv = {},
  stdin?: string
): { stdout: string; stderr: string; code: number } {
  try {
    const stdout = execFileSync("npx", ["tsx", CLI, ...args], {
      encoding: "utf-8",
      env: { ...process.env, ...env },
      input: stdin,
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

describe("kanban help", () => {
  test("prioritizes collaboration and subagent commands over low-level send", () => {
    const r = runCli(["--help"]);
    assert.equal(r.code, 0, r.stderr);
    const helpText = r.stdout.replace(/\s+/g, " ");
    assert.match(helpText, /kanban channel --help/);
    assert.match(helpText, /Low-level: deliver a message to one card's session/);

    const channelIndex = r.stdout.indexOf("  channel");
    const dmIndex = r.stdout.indexOf("  dm");
    const subagentIndex = r.stdout.indexOf("  subagent");
    const parentIndex = r.stdout.indexOf("  parent");
    const sendIndex = r.stdout.indexOf("  send");
    assert.ok(channelIndex >= 0, "channel command should be listed");
    assert.ok(dmIndex >= 0, "dm command should be listed");
    assert.ok(subagentIndex >= 0, "subagent command should be listed");
    assert.ok(parentIndex >= 0, "parent command should be listed");
    assert.ok(sendIndex >= 0, "send command should be listed");
    assert.ok(channelIndex < dmIndex, "channel should appear before dm");
    assert.ok(dmIndex < subagentIndex, "dm should appear before subagent");
    assert.ok(subagentIndex < parentIndex, "subagent should appear before parent");
    assert.ok(parentIndex < sendIndex, "parent should appear before low-level send");
    assert.ok(dmIndex < sendIndex, "dm should appear before low-level send");
  });

  test("warns agents not to truncate the help page", () => {
    const r = runCli(["--help"]);
    assert.match(r.stdout, /Do not pipe it through head or tail/);
  });

  test("writes the whole page even when stdout is a pipe", () => {
    const direct = runCli(["--help"]).stdout.length;
    const piped = execFileSync("/bin/sh", ["-c", `npx tsx ${CLI} --help | cat`], {
      encoding: "utf8",
      env: process.env,
    });
    assert.equal(
      piped.length,
      direct,
      `piped help was ${piped.length} bytes, direct help was ${direct}`
    );
  });
});

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

  test("join --as inside tmux preserves and repairs the current card id", () => {
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
    ]);
    runCli(["channel", "create", "general", "--as-user"], { HOME: home });

    let r = runCli(["channel", "join", "general", "--as", "alice"], { HOME: home });
    assert.equal(r.code, 0, r.stderr);
    r = runCli(["channel", "members", "general", "--json"], { HOME: home });
    let members = JSON.parse(r.stdout);
    assert.equal(members.find((m: any) => m.handle === "alice")?.cardId, null);

    const { binDir, logPath } = seedFakeTmux("sess-alice");
    const tmuxEnv = {
      HOME: home,
      PATH: `${binDir}:${process.env.PATH}`,
      TMUX: "/tmp/tmux-test/default,1,0",
      TMUX_LOG: logPath,
      TMUX_SESSION_NAME: "sess-alice",
    };

    r = runCli(["channel", "join", "general", "--as", "alice"], tmuxEnv);
    assert.equal(r.code, 0, r.stderr);
    r = runCli(["channel", "members", "general", "--json"], { HOME: home });
    members = JSON.parse(r.stdout);
    assert.equal(members.find((m: any) => m.handle === "alice")?.cardId, "card_alice");
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

    const r = runCli(["self-compact", "--follow-up-delay", "0.1", "Continue", "after", "compact."], env);
    assert.equal(r.code, 0, r.stderr);
    assert.match(r.stdout, /Sent \/compact to sess-self with post-compact follow-up/);
    // The detached self-compact shell sleeps 2s before Escape (see
    // scheduleTmuxSelfCompact in data.ts), then the per-step sleeps and the
    // follow-up delay. Wait past all of that so every fake-tmux line we
    // assert on has been written to the log file.
    execFileSync("sleep", ["2.8"]);

    const log = readFileSync(logPath, "utf-8");
    assert.match(log, /display-message -p #S/);
    assert.match(log, /send-keys -t sess-self Enter/);
    assert.match(log, /send-keys -t sess-self Escape/);
    assert.match(log, /set-buffer -b kc-\d+-\d+ \/compact/);
    assert.match(log, /paste-buffer -p -d -b kc-\d+-\d+ -t sess-self/);
    assert.match(log, /send-keys -t sess-self Enter/);
    assert.match(log, /set-buffer -b kc-\d+-\d+ Continue after compact\./);
    assert.match(log, /paste-buffer -p -d -b kc-\d+-\d+ -t sess-self/);
  });

  test("self-compact reads a multiline post-compact prompt from piped stdin", () => {
    const sessionName = "sess-self-stdin";
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
        id: "card_self_stdin",
        name: "self card stdin",
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

    const followUp = "Continue after compact.\n\n1. Recheck CI.\n2. Report back.";
    const r = runCli(["self-compact", "--follow-up-delay", "0.1"], env, followUp);
    assert.equal(r.code, 0, r.stderr);
    assert.match(r.stdout, /with post-compact follow-up/);
    execFileSync("sleep", ["2.8"]);

    const log = readFileSync(logPath, "utf-8");
    assert.match(log, /set-buffer -b kc-\d+-\d+ Continue after compact/);
    assert.match(log, /1\. Recheck CI/);
    assert.match(log, /2\. Report back\./);
  });

  test("self-compact rejects an explicitly required but empty stdin handoff", () => {
    const sessionName = "sess-self-empty-stdin";
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
        id: "card_self_empty_stdin",
        name: "self card empty stdin",
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

    const r = runCli(["self-compact", "-"], env, "");
    assert.notEqual(r.code, 0);
    assert.match(r.stderr + r.stdout, /stdin was empty/);
    const log = existsSync(logPath) ? readFileSync(logPath, "utf-8") : "";
    assert.doesNotMatch(log, /set-buffer/);
  });

  test("self-compact submits /compact when no follow-up prompt is provided", () => {
    const sessionName = "sess-self-no-follow-up";
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
        id: "card_self_no_follow_up",
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

    const r = runCli(["self-compact"], env);
    assert.equal(r.code, 0, r.stderr);
    assert.match(r.stdout, /Sent \/compact to sess-self-no-follow-up\./);
    // Detached shell sleeps 2s before Escape (see scheduleTmuxSelfCompact);
    // wait past it before reading the log.
    execFileSync("sleep", ["2.4"]);

    const log = readFileSync(logPath, "utf-8");
    assert.match(log, /set-buffer -b kc-\d+-\d+ \/compact/);
    assert.match(log, /paste-buffer -p -d -b kc-\d+-\d+ -t sess-self-no-follow-up/);
    assert.match(log, /send-keys -t sess-self-no-follow-up Enter/);
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
