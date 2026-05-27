/**
 * Real tmux + filesystem integration test for headless agent launch/resume.
 * No mocks: spins a real tmux session, writes a real links.json, and exercises
 * the launch -> idempotent re-run -> resume lifecycle. Uses `true` as a stand-in
 * for the claude binary so the pane stays a live shell without needing Claude.
 *
 * Skipped when tmux is unavailable (CI without tmux).
 */
import { test, describe, before, after, beforeEach, afterEach } from "node:test";
import { strict as assert } from "node:assert";
import { execSync } from "node:child_process";
import { mkdtempSync, rmSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { agentIdentity } from "./agents/identity.js";
import { ensureAgentSession } from "./agents/launch.js";
import { readLinks } from "./data.js";

function hasTmux(): boolean {
  try {
    execSync("tmux -V", { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}

const skipIfNoTmux = { skip: !hasTmux() };

describe("headless agent launch/resume (real tmux)", skipIfNoTmux, () => {
  let home: string;
  let claudeHome: string;
  let workspace: string;
  const slug = `kanban-test-${Date.now()}`;
  const identity = agentIdentity(slug);

  beforeEach(() => {
    home = mkdtempSync(join(tmpdir(), "kanban-launch-home-"));
    claudeHome = mkdtempSync(join(tmpdir(), "kanban-launch-claude-"));
    workspace = mkdtempSync(join(tmpdir(), "kanban-launch-ws-"));
    process.env.KANBAN_CODE_HOME = home;
    process.env.CLAUDE_CONFIG_DIR = claudeHome;
  });

  afterEach(() => {
    try { execSync(`tmux kill-session -t ${identity.tmuxName}`, { stdio: "ignore" }); } catch {}
    delete process.env.KANBAN_CODE_HOME;
    delete process.env.CLAUDE_CONFIG_DIR;
    rmSync(home, { recursive: true, force: true });
    rmSync(claudeHome, { recursive: true, force: true });
    rmSync(workspace, { recursive: true, force: true });
  });

  test("fresh launch creates a tmux session and a stable card", () => {
    const result = ensureAgentSession(identity, { cwd: workspace, claudeBin: "true" });
    assert.equal(result.action, "launched");
    assert.match(result.command!, /true --session-id .* --name /);

    // Real tmux session exists.
    execSync(`tmux has-session -t ${identity.tmuxName}`);

    const cards = readLinks();
    assert.equal(cards.length, 1);
    const card = cards[0];
    assert.equal(card.name, slug);
    assert.equal(card.sessionLink?.sessionId, identity.sessionId);
    assert.equal(card.tmuxLink?.sessionName, identity.tmuxName);
    assert.equal(card.worktreeLink?.path, workspace);
    assert.equal(card.column, "in_progress");
    assert.equal(card.assistant, "claude");
  });

  test("re-running while alive is a no-op: no restart, no duplicate card", () => {
    const first = ensureAgentSession(identity, { cwd: workspace, claudeBin: "true" });
    const firstCardId = first.card.id;

    const second = ensureAgentSession(identity, { cwd: workspace, claudeBin: "true" });
    assert.equal(second.action, "noop-running");
    assert.equal(second.command, undefined, "must not build a launch command when already running");

    const cards = readLinks();
    assert.equal(cards.length, 1, "must not create a duplicate card");
    assert.equal(cards[0].id, firstCardId, "card id must be stable across reconciles");
  });

  test("after the tmux session dies but a transcript exists, it resumes", () => {
    // Simulate a prior session: a transcript file for this session id.
    const projDir = join(claudeHome, "projects", "some-encoded-cwd");
    mkdirSync(projDir, { recursive: true });
    writeFileSync(join(projDir, `${identity.sessionId}.jsonl`), '{"type":"user"}\n');

    const result = ensureAgentSession(identity, { cwd: workspace, claudeBin: "true" });
    assert.equal(result.action, "resumed");
    assert.match(result.command!, new RegExp(`true --resume ${identity.sessionId}`));
    execSync(`tmux has-session -t ${identity.tmuxName}`);

    // The card records the discovered transcript path.
    const card = readLinks()[0];
    assert.equal(card.sessionLink?.sessionPath, join(projDir, `${identity.sessionId}.jsonl`));
  });
});
