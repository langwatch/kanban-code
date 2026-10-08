/**
 * Agents on rush hosts: agents.yaml `host: rush` starts a Claude agent with
 * `rush session start`, names its card `rush-<host id>`, never restarts a
 * host that is running or resting, and moves an agent between tmux and rush
 * without leaving two processes on one conversation.
 *
 * A fake rush (a small node script) stands in for the binary: it records
 * every call and keeps its hosts in a JSON file, so the tests see the exact
 * argv and can stage running, resting and dead hosts. tmux is real.
 */
import { test, describe, beforeEach, afterEach } from "node:test";
import { strict as assert } from "node:assert";
import { execSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { parseAgentsConfig } from "./agents/config.js";
import { agentIdentity } from "./agents/identity.js";
import { ensureAgentSession } from "./agents/launch.js";
import { rushHostId, rushPendingQuestion } from "./agents/rush-host.js";
import { agentSessionName, deliverAgentMessage } from "./agents/session-name.js";
import { rushQuestionText } from "./slack/bridge.js";
import { listRushSessions, readLinks, setRushPath } from "./data.js";
import { upsertCard, isoNow } from "./cards.js";

function hasTmux(): boolean {
  try {
    execSync("tmux -V", { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}

const FAKE_RUSH = `#!/usr/bin/env node
const fs = require("fs");
const dir = process.env.FAKE_RUSH_DIR;
const hostsPath = dir + "/hosts.json";
const args = process.argv.slice(2);
const stdin = args[1] === "answer" || args[1] === "send" ? fs.readFileSync(0, "utf-8") : undefined;
fs.appendFileSync(dir + "/calls.jsonl", JSON.stringify({ args, stdin, rushSession: process.env.RUSH_SESSION ?? null }) + "\\n");
const hosts = fs.existsSync(hostsPath) ? JSON.parse(fs.readFileSync(hostsPath, "utf-8")) : [];
const save = () => fs.writeFileSync(hostsPath, JSON.stringify(hosts));
const flag = (name) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : undefined; };
const all = (name) => args.flatMap((a, i) => (a === name ? [args[i + 1]] : []));
const [, sub, id] = args;
if (sub === "list") {
  const want = all("--meta").map((kv) => kv.split("="));
  console.log(JSON.stringify(hosts.filter((h) => want.every(([k, v]) => (h.meta || {})[k] === v))));
} else if (sub === "start") {
  const sessionId = flag("--session-id");
  const hid = sessionId.replace(/-/g, "").slice(0, 8);
  const meta = Object.fromEntries(all("--meta").map((kv) => kv.split("=")));
  const host = { id: hid, sessionId, cwd: flag("--cwd"), name: flag("--name"), state: "idle", alive: true, meta };
  const i = hosts.findIndex((h) => h.id === hid);
  if (i >= 0) hosts[i] = host; else hosts.push(host);
  save();
  console.log(JSON.stringify(host));
} else if (sub === "stop") {
  const h = hosts.find((h) => h.id === id);
  if (h) { h.alive = false; h.state = "stopped"; save(); }
  console.log("stopped " + id);
} else if (sub === "info") {
  const h = hosts.find((h) => h.id === id);
  if (!h) { console.log(JSON.stringify({ error: "not found" })); process.exit(1); }
  console.log(JSON.stringify(h));
} else {
  console.log("ok");
}
`;

interface Call {
  args: string[];
  stdin?: string;
  rushSession: string | null;
}

describe("agents.yaml host", () => {
  test("defaults to tmux for every agent", () => {
    const f = parseAgentsConfig(`agents:\n  - slug: a\n    repos: []\n`);
    assert.equal(f.host, "tmux");
    assert.equal(f.agents[0].host, "tmux");
    assert.deepEqual(f.warnings, []);
  });

  test("a top-level host applies to every agent, an agent's own host wins", () => {
    const f = parseAgentsConfig(
      `host: rush\nagents:\n  - slug: a\n    repos: []\n  - slug: b\n    host: tmux\n    repos: []\n`
    );
    assert.equal(f.agents[0].host, "rush");
    assert.equal(f.agents[1].host, "tmux");
  });

  test("a Codex agent stays on tmux, with a warning when it asked for rush", () => {
    const f = parseAgentsConfig(
      `host: rush\nagents:\n  - slug: a\n    runtime: codex\n    repos: []\n  - slug: b\n    runtime: codex\n    host: rush\n    repos: []\n`
    );
    assert.equal(f.agents[0].host, "tmux");
    assert.equal(f.agents[1].host, "tmux");
    assert.equal(f.warnings.length, 1);
    assert.match(f.warnings[0], /^b: host rush runs Claude only/);
  });

  test("an unknown host is refused", () => {
    assert.throws(() => parseAgentsConfig(`host: docker\nagents: []\n`), /host invalid/);
    assert.throws(
      () => parseAgentsConfig(`agents:\n  - slug: a\n    host: screen\n    repos: []\n`),
      /invalid host "screen"/
    );
  });

  test("a rush agent's session name is rush-<first eight hex of its session id>", () => {
    const id = agentIdentity("scout", "claude", "rush");
    assert.equal(id.host, "rush");
    assert.equal(id.tmuxName, `rush-${id.sessionId.replaceAll("-", "").slice(0, 8)}`);
    assert.equal(rushHostId(id.sessionId), id.tmuxName.slice("rush-".length));
    assert.equal(agentIdentity("scout").tmuxName, "scout");
  });
});

describe("rush questions", () => {
  test("only a blocked host asking a question has one pending", () => {
    assert.equal(rushPendingQuestion({ id: "x", sessionId: "s", state: "blocked", needs: "asks: Which DB?" }), "Which DB?");
    assert.equal(rushPendingQuestion({ id: "x", sessionId: "s", state: "blocked", needs: "Bash rm -rf /" }), undefined);
    assert.equal(rushPendingQuestion({ id: "x", sessionId: "s", state: "idle", needs: "asks: stale" }), undefined);
  });

  test("the Slack text names the agent and says how to answer", () => {
    assert.equal(rushQuestionText("scout", "Which DB?"), ":question: *scout* asks: *Which DB?*\nReply in this channel to answer.");
  });
});

describe("agents on rush hosts", { skip: !hasTmux() }, () => {
  let root: string;
  let fakeDir: string;
  let workspace: string;
  let claudeHome: string;
  const slug = `kanban-rush-test-${process.pid}`;
  const identity = agentIdentity(slug, "claude", "rush");
  const hostId = rushHostId(identity.sessionId);
  const savedRushSession = process.env.RUSH_SESSION;

  const calls = (): Call[] => {
    const p = join(fakeDir, "calls.jsonl");
    if (!existsSync(p)) return [];
    return readFileSync(p, "utf-8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l));
  };
  const starts = () => calls().filter((c) => c.args[1] === "start");
  const setHosts = (hosts: unknown[]) => writeFileSync(join(fakeDir, "hosts.json"), JSON.stringify(hosts));
  const writeTranscript = () => {
    const projDir = join(claudeHome, "projects", "encoded-cwd");
    mkdirSync(projDir, { recursive: true });
    writeFileSync(join(projDir, `${identity.sessionId}.jsonl`), '{"type":"user"}\n');
  };
  const tmuxAlive = (name: string) => {
    try {
      execSync(`tmux has-session -t ${name}`, { stdio: "ignore" });
      return true;
    } catch {
      return false;
    }
  };

  beforeEach(() => {
    root = mkdtempSync(join(tmpdir(), "kanban-rush-agents-"));
    fakeDir = join(root, "fake");
    workspace = join(root, "ws");
    claudeHome = join(root, "claude");
    for (const d of [fakeDir, workspace, claudeHome, join(root, "home")]) mkdirSync(d, { recursive: true });
    const bin = join(fakeDir, "rush");
    writeFileSync(bin, FAKE_RUSH);
    chmodSync(bin, 0o755);
    setRushPath(bin);
    process.env.FAKE_RUSH_DIR = fakeDir;
    process.env.KANBAN_CODE_HOME = join(root, "home");
    process.env.CLAUDE_CONFIG_DIR = claudeHome;
    process.env.RUSH_SESSION = "parent01";
  });

  afterEach(() => {
    try {
      execSync(`tmux kill-session -t ${slug}`, { stdio: "ignore" });
    } catch {}
    setRushPath(undefined);
    delete process.env.FAKE_RUSH_DIR;
    delete process.env.KANBAN_CODE_HOME;
    delete process.env.CLAUDE_CONFIG_DIR;
    if (savedRushSession === undefined) delete process.env.RUSH_SESSION;
    else process.env.RUSH_SESSION = savedRushSession;
    rmSync(root, { recursive: true, force: true });
  });

  test("a new agent starts a rush host and its card names it", () => {
    const result = ensureAgentSession(identity, { cwd: workspace, model: "haiku", env: { FOO: "bar" } });
    assert.equal(result.action, "launched");
    assert.equal(result.tmuxName, `rush-${hostId}`);

    const [start] = starts();
    const card = readLinks().find((l) => l.name === slug)!;
    assert.deepEqual(start.args, [
      "session", "start", "--agent", "claude", "--cwd", workspace,
      "--session-id", identity.sessionId,
      "--name", slug,
      "--permission-mode", "bypassPermissions",
      "--model", "haiku",
      "--env", "FOO=bar",
      "--env", `KANBAN_SESSION_ID=${identity.sessionId}`,
      "--env", `KANBAN_SLUG=${slug}`,
      "--meta", `kanban_session=rush-${hostId}`,
      "--meta", `kanban_agent=${slug}`,
      "--meta", `kanban_card=${card.id}`,
      "--json",
    ]);
    assert.equal(start.rushSession, null, "an agent is not started as another rush session's subagent");
    assert.equal(card.tmuxLink?.sessionName, `rush-${hostId}`);
    assert.equal(card.sessionLink?.sessionId, identity.sessionId);
    assert.equal(card.worktreeLink?.path, workspace);
    assert.equal(agentSessionName(slug), `rush-${hostId}`);
  });

  test("a running host is never started again, and the card is left as it is", () => {
    const first = ensureAgentSession(identity, { cwd: workspace });
    const before = readFileSync(join(process.env.KANBAN_CODE_HOME!, "links.json"), "utf-8");
    const second = ensureAgentSession(identity, { cwd: workspace });
    assert.equal(second.action, "noop-running");
    assert.equal(second.command, undefined);
    assert.equal(starts().length, 1);
    assert.equal(second.card.id, first.card.id);
    assert.equal(readFileSync(join(process.env.KANBAN_CODE_HOME!, "links.json"), "utf-8"), before);
  });

  test("a resting host counts as in place: the next message wakes it", () => {
    setHosts([{ id: hostId, sessionId: identity.sessionId, alive: false, sleeping: true, state: "idle", meta: { kanban_agent: slug } }]);
    writeTranscript();
    const result = ensureAgentSession(identity, { cwd: workspace });
    assert.equal(result.action, "noop-running");
    assert.equal(starts().length, 0);
    assert.equal(result.card.tmuxLink?.sessionName, `rush-${hostId}`);
  });

  test("a dead host with a transcript is resumed", () => {
    setHosts([{ id: hostId, sessionId: identity.sessionId, alive: false, state: "stopped", meta: { kanban_agent: slug } }]);
    writeTranscript();
    const result = ensureAgentSession(identity, { cwd: workspace });
    assert.equal(result.action, "resumed");
    const [start] = starts();
    assert.ok(start.args.includes("--resume"));
    assert.equal(start.args[start.args.indexOf("--session-id") + 1], identity.sessionId);
  });

  test("a saved host that never took a turn is left for its next message to wake", () => {
    setHosts([{ id: hostId, sessionId: identity.sessionId, alive: false, state: "stopped", meta: { kanban_agent: slug } }]);
    const result = ensureAgentSession(identity, { cwd: workspace });
    assert.equal(result.action, "noop-running");
    assert.equal(starts().length, 0);
  });

  test("forceFresh starts a host on a new session id", () => {
    writeTranscript();
    const result = ensureAgentSession(identity, { cwd: workspace, forceFresh: true });
    assert.equal(result.action, "launched");
    assert.notEqual(result.sessionId, identity.sessionId);
    const [start] = starts();
    assert.ok(!start.args.includes("--resume"));
    assert.equal(result.tmuxName, `rush-${rushHostId(result.sessionId)}`);
  });

  test("moving an agent from tmux to rush kills its tmux session first", () => {
    const tmux = ensureAgentSession(agentIdentity(slug), { cwd: workspace, bin: "true" });
    assert.ok(tmuxAlive(slug));
    const rush = ensureAgentSession(identity, { cwd: workspace });
    assert.equal(rush.action, "launched");
    assert.equal(tmuxAlive(slug), false);
    assert.equal(rush.card.id, tmux.card.id, "the same card follows the agent");
    assert.equal(readLinks().find((l) => l.name === slug)?.tmuxLink?.sessionName, `rush-${hostId}`);
  });

  test("moving an agent back to tmux stops its rush host", () => {
    ensureAgentSession(identity, { cwd: workspace });
    const tmux = ensureAgentSession(agentIdentity(slug), { cwd: workspace, bin: "true" });
    assert.ok(calls().some((c) => c.args[1] === "stop" && c.args[2] === hostId));
    assert.equal(tmux.card.tmuxLink?.sessionName, slug);
    assert.equal(agentSessionName(slug), slug);
  });

  test("a message to a host blocked on a question answers it", () => {
    ensureAgentSession(identity, { cwd: workspace });
    setHosts([{ id: hostId, sessionId: identity.sessionId, alive: true, state: "blocked", needs: "asks: Which DB?", meta: { kanban_agent: slug } }]);
    const res = deliverAgentMessage(`rush-${hostId}`, "Postgres");
    assert.deepEqual(res, { ok: true, answered: true });
    const answer = calls().find((c) => c.args[1] === "answer");
    assert.deepEqual(answer?.args, ["session", "answer", hostId]);
    assert.equal(answer?.stdin, "Postgres");
  });

  test("a message to a host not waiting on a question is sent as a prompt", () => {
    ensureAgentSession(identity, { cwd: workspace });
    const res = deliverAgentMessage(`rush-${hostId}`, "pong please");
    assert.equal(res.ok, true);
    const send = calls().find((c) => c.args[1] === "send");
    assert.deepEqual(send?.args, ["session", "send", hostId]);
    assert.equal(send?.stdin, "pong please");
  });

  test("an agent with no card is addressed by its slug", () => {
    assert.equal(agentSessionName("no-such-agent"), "no-such-agent");
  });

  test("an archived card loses to the live one", () => {
    const now = isoNow();
    const base = {
      createdAt: now, updatedAt: now, column: "in_progress", source: "manual", isRemote: false,
      manualOverrides: { worktreePath: false, tmuxSession: false, name: true, column: false, prLink: false, issueLink: false },
    } as const;
    upsertCard({ ...base, id: "card_old", name: slug, manuallyArchived: true, tmuxLink: { sessionName: slug } } as any);
    upsertCard({ ...base, id: "card_new", name: slug, manuallyArchived: false, tmuxLink: { sessionName: `rush-${hostId}` } } as any);
    assert.equal(agentSessionName(slug), `rush-${hostId}`);
  });

  test("a resting host counts as a live session, a stopped one does not", () => {
    setHosts([
      { id: "aaaaaaaa", sessionId: "s1", alive: false, sleeping: true, state: "idle", meta: { kanban_session: "rush-aaaaaaaa" } },
      { id: "bbbbbbbb", sessionId: "s2", alive: false, sleeping: true, state: "stopped", meta: { kanban_session: "rush-bbbbbbbb" } },
      { id: "cccccccc", sessionId: "s3", alive: true, state: "working", meta: { kanban_session: "rush-cccccccc" } },
    ]);
    assert.deepEqual(listRushSessions().map((s) => s.name).sort(), ["rush-aaaaaaaa", "rush-cccccccc"]);
  });
});
