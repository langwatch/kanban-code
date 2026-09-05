/**
 * Remote tmux routing: a card on a boxd machine has no tmux server on the Mac,
 * so every tmux call for its session has to travel through `boxd machine exec`.
 */

import { strict as assert } from "node:assert";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, test } from "node:test";
import {
  buildTmuxCommand,
  captureTmuxPane,
  hasTmuxSession,
  killTmuxSession,
  pasteTmuxPrompt,
  peekTmuxPane,
  remoteMachineForSession,
  remoteTmuxSessionNames,
  scheduleTmuxPrompt,
  scheduleTmuxSelfCompact,
  sendTmuxEnter,
  sendTmuxEscape,
  sendTmuxKey,
  sendTmuxKeys,
  setTmuxCommandRunner,
} from "./data.js";
import type { Link } from "./types.js";

let home: string;
let previousHome: string | undefined;
let commands: { command: string; detached: boolean }[];

function link(overrides: Partial<Link>): Link {
  return {
    id: "card-1",
    column: "in_progress",
    createdAt: "2026-08-29T00:00:00Z",
    updatedAt: "2026-08-29T00:00:00Z",
    manualOverrides: {
      worktreePath: false,
      tmuxSession: false,
      name: false,
      column: false,
      prLink: false,
      issueLink: false,
    },
    manuallyArchived: false,
    source: "manual",
    isRemote: false,
    ...overrides,
  };
}

function seedLinks(links: Link[]): void {
  writeFileSync(
    join(process.env.KANBAN_CODE_HOME!, "links.json"),
    JSON.stringify({ links }, null, 2)
  );
}

function remoteCard(): Link {
  return link({
    id: "card-remote",
    tmuxLink: { sessionName: "kc-remote", extraSessions: ["kc-remote-shell"] },
    isRemote: true,
    remote: { mode: "boxd", machineName: "vm-1" },
  });
}

/** The script the machine runs, unwrapped from the Mac's own shell quoting. */
function remoteScript(command: string): string {
  const match = command.match(/^boxd machine exec (\S+) -- '(.*)'( 2>\/dev\/null)?$/s);
  assert.ok(match, `not a boxd command: ${command}`);
  return match[2].replace(/'\\''/g, "'");
}

beforeEach(() => {
  home = mkdtempSync(join(tmpdir(), "kanban-remote-tmux-"));
  previousHome = process.env.KANBAN_CODE_HOME;
  process.env.KANBAN_CODE_HOME = join(home, ".kanban-code");
  mkdirSync(process.env.KANBAN_CODE_HOME, { recursive: true });
  commands = [];
  setTmuxCommandRunner((command, options) => {
    commands.push({ command, detached: options.detached });
    return "";
  });
});

afterEach(() => {
  setTmuxCommandRunner(undefined);
  if (previousHome === undefined) delete process.env.KANBAN_CODE_HOME;
  else process.env.KANBAN_CODE_HOME = previousHome;
  rmSync(home, { recursive: true, force: true });
});

describe("remoteMachineForSession", () => {
  test("finds the machine of a boxd card by its session name", () => {
    seedLinks([remoteCard()]);
    assert.equal(remoteMachineForSession("kc-remote"), "vm-1");
  });

  test("covers the card's extra terminals too", () => {
    seedLinks([remoteCard()]);
    assert.equal(remoteMachineForSession("kc-remote-shell"), "vm-1");
  });

  test("ignores local cards and other remote modes", () => {
    seedLinks([
      link({ id: "local", tmuxLink: { sessionName: "kc-local" } }),
      link({
        id: "synced",
        tmuxLink: { sessionName: "kc-synced" },
        remote: { mode: "mutagen", machineName: "vm-2" },
      }),
    ]);
    assert.equal(remoteMachineForSession("kc-local"), undefined);
    assert.equal(remoteMachineForSession("kc-synced"), undefined);
  });

  test("says nothing when there is no links file", () => {
    assert.equal(remoteMachineForSession("kc-remote"), undefined);
  });

  test("a card that kept its machine but runs locally routes locally", () => {
    seedLinks([
      link({
        id: "card-kept",
        tmuxLink: { sessionName: "kc-kept" },
        isRemote: false,
        remote: { mode: "boxd", machineName: "vm-1" },
      }),
    ]);
    assert.equal(remoteMachineForSession("kc-kept"), undefined);
  });
});

describe("remoteTmuxSessionNames", () => {
  test("lists every session that lives on a machine", () => {
    seedLinks([remoteCard(), link({ id: "local", tmuxLink: { sessionName: "kc-local" } })]);
    assert.deepEqual(remoteTmuxSessionNames().sort(), ["kc-remote", "kc-remote-shell"]);
  });

  test("is empty without remote cards", () => {
    seedLinks([link({ id: "local", tmuxLink: { sessionName: "kc-local" } })]);
    assert.deepEqual(remoteTmuxSessionNames(), []);
  });
});

describe("buildTmuxCommand", () => {
  test("runs tmux directly for a local session", () => {
    seedLinks([link({ tmuxLink: { sessionName: "kc-local" } })]);
    const command = buildTmuxCommand("kc-local", [["send-keys", "-t", "kc-local", "Enter"]]);
    assert.doesNotMatch(command, /boxd/);
    assert.match(command, /tmux send-keys -t kc-local Enter/);
  });

  test("wraps the whole chain in one boxd exec for a remote session", () => {
    seedLinks([remoteCard()]);
    const command = buildTmuxCommand("kc-remote", [
      ["set-buffer", "-b", "kc-1", "--", "hello there"],
      { sleep: 0.1 },
      ["send-keys", "-t", "kc-remote", "Enter"],
    ]);
    assert.equal(command.split("boxd machine exec").length - 1, 1);
    assert.equal(
      remoteScript(command),
      "tmux set-buffer -b kc-1 -- 'hello there' && sleep 0.1 && tmux send-keys -t kc-remote Enter"
    );
  });

  test("appends the quiet redirect outside the exec", () => {
    seedLinks([remoteCard()]);
    const command = buildTmuxCommand(
      "kc-remote",
      [["has-session", "-t", "kc-remote"]],
      { quiet: true }
    );
    assert.ok(command.endsWith(" 2>/dev/null"), command);
  });
});

describe("tmux calls for a remote card", () => {
  beforeEach(() => {
    seedLinks([remoteCard()]);
  });

  test("paste sends the buffer, the paste and Enter in one round trip", () => {
    assert.deepEqual(pasteTmuxPrompt("kc-remote", "review the diff"), { ok: true });
    assert.equal(commands.length, 1);
    const { command, detached } = commands[0];
    assert.equal(detached, false);
    const script = remoteScript(command);
    assert.match(script, /^tmux set-buffer -b kc-\d+-\d+ -- 'review the diff'/);
    assert.match(script, /tmux paste-buffer -p -d -b kc-\d+-\d+ -t kc-remote/);
    assert.match(script, /tmux send-keys -t kc-remote Enter$/);
  });

  test("keys, Enter, Escape and a bare key all travel through boxd", () => {
    sendTmuxKeys("kc-remote", "/status");
    sendTmuxEnter("kc-remote");
    sendTmuxEscape("kc-remote");
    sendTmuxKey("kc-remote", "1");
    assert.equal(commands.length, 4);
    assert.deepEqual(
      commands.map((entry) => remoteScript(entry.command)),
      [
        "tmux send-keys -t kc-remote /status Enter",
        "tmux send-keys -t kc-remote Enter",
        "tmux send-keys -t kc-remote Escape",
        "tmux send-keys -t kc-remote 1",
      ]
    );
  });

  test("capture and peek read the pane over boxd", () => {
    captureTmuxPane("kc-remote", "all");
    peekTmuxPane("kc-remote", 5);
    assert.equal(remoteScript(commands[0].command), "tmux capture-pane -t kc-remote -p -S -");
    assert.equal(remoteScript(commands[1].command), "tmux capture-pane -t kc-remote -p -S -25");
    for (const { command } of commands) assert.ok(command.endsWith(" 2>/dev/null"), command);
  });

  test("session probes and kills go to the machine", () => {
    assert.equal(hasTmuxSession("kc-remote"), true);
    killTmuxSession("kc-remote");
    assert.equal(
      commands[0].command,
      "boxd machine exec vm-1 -- 'tmux has-session -t kc-remote' 2>/dev/null"
    );
    assert.match(commands[1].command, /tmux kill-session -t kc-remote/);
  });

  test("scheduled prompts stay detached and remote", () => {
    scheduleTmuxPrompt("kc-remote", "nudge", 30);
    assert.equal(commands.length, 1);
    assert.equal(commands[0].detached, true);
    assert.match(
      remoteScript(commands[0].command),
      /^sleep 30 && tmux set-buffer -b kc-\d+-\d+ -- nudge/
    );
  });

  test("a scheduled self-compact carries the compact and the follow-up", () => {
    scheduleTmuxSelfCompact("kc-remote", "carry on", 2);
    assert.equal(commands.length, 1);
    assert.equal(commands[0].detached, true);
    const script = remoteScript(commands[0].command);
    assert.match(script, /^sleep 2 && tmux send-keys -t kc-remote Escape/);
    assert.match(script, /tmux set-buffer -b kc-\d+-\d+ -- \/compact/);
    assert.match(script, /tmux set-buffer -b kc-\d+-\d+ -- 'carry on'/);
  });

  test("every scheduled submit re-sends Enter while its text still sits in the composer", () => {
    scheduleTmuxSelfCompact("kc-remote", "carry on with the rebase", 2);
    const script = remoteScript(commands[0].command);
    // One verify loop per submit: the /compact and the follow-up.
    const loops = script.match(/capture-pane -t kc-remote -p \| tail -8 \| grep -qF -- \S+/g) ?? [];
    assert.equal(loops.length, 2);
    assert.match(script, /grep -qF -- \/compact \|\| break/);
    assert.match(script, /grep -qF -- 'carry on with the rebase' \|\| break/);
    // The raw loop runs the machine's tmux, not a Mac path.
    assert.doesNotMatch(script, /%TMUX%/);
  });
});

describe("tmux calls for a local card", () => {
  beforeEach(() => {
    seedLinks([link({ tmuxLink: { sessionName: "kc-local" } })]);
  });

  test("never mention boxd", () => {
    pasteTmuxPrompt("kc-local", "review the diff");
    sendTmuxKeys("kc-local", "/status");
    hasTmuxSession("kc-local");
    assert.ok(commands.length >= 3);
    for (const { command } of commands) assert.doesNotMatch(command, /boxd/);
    assert.match(commands[0].command, /tmux set-buffer -b kc-\d+-\d+ -- 'review the diff'/);
  });
});
