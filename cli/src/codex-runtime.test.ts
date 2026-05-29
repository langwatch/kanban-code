/**
 * Unit tests for the codex runtime: the runtime descriptor (arg building),
 * config parsing of the `runtime` field, codex hook installation, and that a
 * codex agent launches fresh (never tries Claude --resume) and tags its card.
 */
import { test, describe, beforeEach, afterEach } from "node:test";
import { strict as assert } from "node:assert";
import { execSync } from "node:child_process";
import { mkdtempSync, rmSync, mkdirSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { runtimeSpec, isRuntime } from "./agents/runtime.js";
import { formatCodexRolloutLines } from "./slack/format.js";
import { writeThreadRoot, readThreadRoot } from "./slack/thread-root.js";
import { parseAgentsConfig } from "./agents/config.js";
import { agentIdentity } from "./agents/identity.js";
import { ensureAgentSession } from "./agents/launch.js";
import { installCodexHooks } from "./hooks.js";
import { readLinks } from "./data.js";

describe("runtime descriptor", () => {
  test("claude builds --session-id / --resume args", () => {
    const c = runtimeSpec("claude");
    assert.equal(c.bin, "claude");
    assert.equal(c.canResume, true);
    assert.equal(c.selfCompact, true);
    assert.deepEqual(
      c.buildArgs({ sessionId: "sid", slug: "agent", resume: false, skipPermissions: true, model: "opus" }),
      ["--session-id", "sid", "--name", "agent", "--dangerously-skip-permissions", "--model", "opus"]
    );
    assert.deepEqual(
      c.buildArgs({ sessionId: "sid", slug: "agent", resume: true, skipPermissions: true }),
      ["--resume", "sid", "--dangerously-skip-permissions"]
    );
  });

  test("codex builds inline + full-auto bypass args and never uses session-id", () => {
    const x = runtimeSpec("codex");
    assert.equal(x.bin, "codex");
    assert.equal(x.canResume, true);
    assert.equal(x.selfCompact, false);
    const args = x.buildArgs({ sessionId: "sid", slug: "agent", resume: false, skipPermissions: true, model: "gpt-5.5" });
    assert.deepEqual(args, [
      "--no-alt-screen",
      "--dangerously-bypass-approvals-and-sandbox",
      "--dangerously-bypass-hook-trust",
      "-m",
      "gpt-5.5",
    ]);
    assert.ok(!args.includes("--session-id"));
    assert.ok(!args.includes("--resume"));
  });

  test("codex resume keeps the global flags before the subcommand and uses resume --last", () => {
    const x = runtimeSpec("codex");
    const args = x.buildArgs({ sessionId: "sid", slug: "agent", resume: true, skipPermissions: true });
    assert.deepEqual(args, [
      "--no-alt-screen",
      "--dangerously-bypass-approvals-and-sandbox",
      "--dangerously-bypass-hook-trust",
      "resume",
      "--last",
    ]);
    // The bypass flags must precede the subcommand (they are global, not
    // resume-subcommand options), and no model is re-passed on resume.
    assert.ok(args.indexOf("--dangerously-bypass-approvals-and-sandbox") < args.indexOf("resume"));
    assert.ok(!args.includes("-m"));
  });

  test("thread root round-trips per slug and shares across the announce/bridge split", () => {
    const home = mkdtempSync(join(tmpdir(), "kanban-threads-"));
    const prev = process.env.KANBAN_CODE_HOME;
    process.env.KANBAN_CODE_HOME = home;
    try {
      assert.equal(readThreadRoot("dependabot-scout"), undefined);
      // daemon announce records the root; bridge reads it for assistant turns
      writeThreadRoot("dependabot-scout", "1700000000.000100");
      assert.equal(readThreadRoot("dependabot-scout"), "1700000000.000100");
      // a new prompt overwrites the root (start of a new thread)
      writeThreadRoot("dependabot-scout", "1700000999.000200");
      assert.equal(readThreadRoot("dependabot-scout"), "1700000999.000200");
      // roots are per-agent
      assert.equal(readThreadRoot("pr-reviewer"), undefined);
    } finally {
      if (prev === undefined) delete process.env.KANBAN_CODE_HOME;
      else process.env.KANBAN_CODE_HOME = prev;
      rmSync(home, { recursive: true, force: true });
    }
  });

  test("isRuntime guards the union", () => {
    assert.ok(isRuntime("claude"));
    assert.ok(isRuntime("codex"));
    assert.ok(!isRuntime("gemini"));
    assert.ok(!isRuntime(undefined));
  });
});

describe("formatCodexRolloutLines", () => {
  test("mirrors received prompts, agent messages and exec commands, skips reasoning/system noise", () => {
    const objs = [
      { type: "session_meta", payload: { cwd: "/x" } },
      { type: "event_msg", payload: { type: "user_message", message: "Please review PR 519.", images: [] } },
      { type: "event_msg", payload: { type: "task_started" } },
      { type: "event_msg", payload: { type: "agent_message", message: "I'll review the PR now." } },
      { type: "response_item", payload: { type: "reasoning", encrypted_content: "..." } },
      { type: "event_msg", payload: { type: "exec_command_begin", command: ["gh", "pr", "view", "519"] } },
      { type: "event_msg", payload: { type: "agent_message", message: "No blockers; 2 nits." } },
    ];
    const posts = formatCodexRolloutLines(objs);
    assert.equal(posts.length, 4);
    // The injected prompt is mirrored like the Claude UserPromptSubmit announce.
    assert.equal(posts[0].role, "user");
    assert.match(posts[0].text, /^>>> Received user message/);
    assert.match(posts[0].text, /Please review PR 519\./);
    assert.equal(posts[1].text, "I'll review the PR now.");
    assert.match(posts[2].text, /gh pr view 519/);
    assert.equal(posts[3].text, "No blockers; 2 nits.");
    assert.ok(posts.slice(1).every((p) => p.role === "assistant"));
  });

  test("mirrors an out-of-credits failure when a turn produces no output", () => {
    const objs = [
      { type: "event_msg", payload: { type: "user_message", message: "Please review PR 4288.", images: [] } },
      { type: "event_msg", payload: { type: "task_started" } },
      {
        type: "event_msg",
        payload: {
          type: "token_count",
          rate_limits: { plan_type: "plus", credits: { has_credits: false, balance: "0" } },
        },
      },
      { type: "event_msg", payload: { type: "task_complete", last_agent_message: null } },
    ];
    const posts = formatCodexRolloutLines(objs);
    assert.equal(posts.length, 2);
    assert.equal(posts[0].role, "user");
    assert.match(posts[1].text, /out of credits/i);
    assert.match(posts[1].text, /plan: plus, balance 0/);
    assert.match(posts[1].text, /chatgpt\.com\/codex\/settings\/usage/);
  });

  test("does not warn when a turn completes with output", () => {
    const objs = [
      {
        type: "event_msg",
        payload: { type: "token_count", rate_limits: { plan_type: "plus", credits: { has_credits: true, balance: "5" } } },
      },
      { type: "event_msg", payload: { type: "agent_message", message: "Reviewed, LGTM." } },
      { type: "event_msg", payload: { type: "task_complete", last_agent_message: "Reviewed, LGTM." } },
    ];
    const posts = formatCodexRolloutLines(objs);
    assert.equal(posts.length, 1);
    assert.equal(posts[0].text, "Reviewed, LGTM.");
  });
});

describe("agents config runtime field", () => {
  test("defaults to claude and accepts codex", () => {
    const f = parseAgentsConfig(`agents:\n  - slug: a\n    repos: ["acme/x"]\n  - slug: b\n    runtime: codex\n    repos: ["acme/y"]\n`);
    assert.equal(f.agents[0].runtime, "claude");
    assert.equal(f.agents[1].runtime, "codex");
  });

  test("rejects an unknown runtime", () => {
    assert.throws(
      () => parseAgentsConfig(`agents:\n  - slug: a\n    runtime: gemini\n    repos: []\n`),
      /invalid runtime/
    );
  });
});

describe("installCodexHooks", () => {
  let codexHome: string;
  beforeEach(() => {
    codexHome = mkdtempSync(join(tmpdir(), "kanban-codex-"));
  });
  afterEach(() => rmSync(codexHome, { recursive: true, force: true }));

  test("writes hooks.json pointing at the shared hook.sh, idempotently", () => {
    const hooksPath = join(codexHome, "hooks.json");
    const hookScriptPath = join(codexHome, "hook.sh");
    const r = installCodexHooks({ hooksPath, hookScriptPath });
    assert.deepEqual(r.events, ["SessionStart", "UserPromptSubmit", "Stop"]);
    const json = JSON.parse(readFileSync(hooksPath, "utf-8"));
    // Codex requires the top-level "hooks" wrapper.
    assert.ok(json.hooks, "events must be nested under a top-level hooks key");
    for (const ev of r.events) {
      assert.equal(json.hooks[ev][0].hooks[0].command, hookScriptPath);
    }
    // Re-install does not duplicate the entry.
    installCodexHooks({ hooksPath, hookScriptPath });
    const json2 = JSON.parse(readFileSync(hooksPath, "utf-8"));
    assert.equal(json2.hooks.Stop[0].hooks.length, 1);
  });
});

function hasTmux(): boolean {
  try { execSync("tmux -V", { stdio: "ignore" }); return true; } catch { return false; }
}

describe("codex agent launch (real tmux)", { skip: !hasTmux() }, () => {
  let home: string;
  let workspace: string;
  const slug = `kanban-codex-test-${Date.now()}`;
  const identity = agentIdentity(slug, "codex");

  beforeEach(() => {
    home = mkdtempSync(join(tmpdir(), "kanban-codex-home-"));
    workspace = mkdtempSync(join(tmpdir(), "kanban-codex-ws-"));
    process.env.KANBAN_CODE_HOME = home;
  });
  afterEach(() => {
    try { execSync(`tmux kill-session -t ${identity.tmuxName}`, { stdio: "ignore" }); } catch {}
    delete process.env.KANBAN_CODE_HOME;
    rmSync(home, { recursive: true, force: true });
    rmSync(workspace, { recursive: true, force: true });
  });

  test("launches codex fresh (no resume) and tags the card assistant=codex", () => {
    const result = ensureAgentSession(identity, { cwd: workspace, bin: "true" });
    assert.equal(result.action, "launched");
    assert.match(result.command!, /true --no-alt-screen --dangerously-bypass-approvals-and-sandbox/);
    const card = readLinks().find((l) => l.name === slug);
    assert.equal(card?.assistant, "codex");
    // A second reconcile is a no-op while the session is alive.
    const again = ensureAgentSession(identity, { cwd: workspace, bin: "true" });
    assert.equal(again.action, "noop-running");
  });
});
