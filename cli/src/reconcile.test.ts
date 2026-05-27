/**
 * Real git + tmux integration test for the reconciler. No mocks: builds a local
 * bare "origin", a canonical clone (standing in for the IaC-provisioned one),
 * and exercises worktree creation, idempotency, the missing-clone error, and
 * prune. `true` stands in for the claude binary so panes stay live shells.
 *
 * Skipped when tmux is unavailable.
 */
import { test, describe, beforeEach, afterEach } from "node:test";
import { strict as assert } from "node:assert";
import { execFileSync, execSync } from "node:child_process";
import { mkdtempSync, rmSync, mkdirSync, writeFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { reconcileAll, reconcileAgent } from "./agents/reconcile.js";
import { AgentsFile } from "./agents/config.js";
import { agentIdentity } from "./agents/identity.js";
import { readLinks } from "./data.js";

const GIT_ENV = {
  GIT_AUTHOR_NAME: "t",
  GIT_AUTHOR_EMAIL: "t@t.dev",
  GIT_COMMITTER_NAME: "t",
  GIT_COMMITTER_EMAIL: "t@t.dev",
};
function g(args: string[], cwd?: string): string {
  return execFileSync("git", args, { cwd, encoding: "utf-8", env: { ...process.env, ...GIT_ENV } }).trim();
}
function hasTmux(): boolean {
  try {
    execSync("tmux -V", { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}
const skipIfNoTmux = { skip: !hasTmux() };

/// Create a bare origin seeded with one commit on main, plus a canonical clone
/// at <reposDir>/<name> (what IaC would provision).
function provisionRepo(root: string, reposDir: string, name: string): void {
  const origin = join(root, `${name}-origin.git`);
  g(["init", "--bare", "-b", "main", origin]);
  const seed = join(root, `${name}-seed`);
  g(["clone", origin, seed]);
  writeFileSync(join(seed, "README.md"), "seed\n");
  g(["add", "."], seed);
  g(["commit", "-m", "init"], seed);
  g(["push", "origin", "main"], seed);
  mkdirSync(reposDir, { recursive: true });
  g(["clone", origin, join(reposDir, name)]);
}

describe("reconciler (real git + tmux)", skipIfNoTmux, () => {
  let root: string;
  let reposDir: string;
  let workspacesDir: string;
  const slugs: string[] = [];

  function makeFile(agents: AgentsFile["agents"]): AgentsFile {
    return { reposDir, workspacesDir, agents };
  }
  function trackSlug(s: string): string {
    slugs.push(s);
    return s;
  }

  beforeEach(() => {
    root = mkdtempSync(join(tmpdir(), "kanban-recon-"));
    reposDir = join(root, "repos");
    workspacesDir = join(root, "workspaces");
    process.env.KANBAN_CODE_HOME = join(root, "kanban-home");
    process.env.CLAUDE_CONFIG_DIR = join(root, "claude-home");
  });

  afterEach(() => {
    for (const s of slugs) {
      try { execSync(`tmux kill-session -t ${s}`, { stdio: "ignore" }); } catch {}
    }
    slugs.length = 0;
    delete process.env.KANBAN_CODE_HOME;
    delete process.env.CLAUDE_CONFIG_DIR;
    rmSync(root, { recursive: true, force: true });
  });

  test("creates a per-agent worktree on agent/<slug> and launches the session", () => {
    provisionRepo(root, reposDir, "myrepo");
    const slug = trackSlug(`recon-a-${Date.now()}`);
    const result = reconcileAll(makeFile([{ slug, repos: ["acme/myrepo"] }]), { claudeBin: "true" });

    const agent = result.agents[0];
    assert.equal(agent.launch.action, "launched");
    assert.equal(agent.repos[0].worktreeCreated, true);

    const worktree = join(workspacesDir, slug, "myrepo");
    assert.ok(existsSync(worktree), "worktree dir should exist");
    assert.equal(g(["-C", worktree, "rev-parse", "--abbrev-ref", "HEAD"]), `agent/${slug}`);

    execSync(`tmux has-session -t ${slug}`); // real session is live

    const card = readLinks().find((c) => c.name === slug)!;
    assert.equal(card.sessionLink?.sessionId, agentIdentity(slug).sessionId);
    assert.equal(card.worktreeLink?.path, join(workspacesDir, slug));
  });

  test("the agent worktree structurally cannot check out main", () => {
    provisionRepo(root, reposDir, "myrepo");
    const slug = trackSlug(`recon-main-${Date.now()}`);
    reconcileAll(makeFile([{ slug, repos: ["acme/myrepo"] }]), { claudeBin: "true" });
    const worktree = join(workspacesDir, slug, "myrepo");
    // main is checked out in the canonical clone, so git refuses it here.
    assert.throws(() => g(["-C", worktree, "checkout", "main"]), /already (used|checked out)/i);
  });

  test("re-running is idempotent: no duplicate worktree, card, or tmux session", () => {
    provisionRepo(root, reposDir, "myrepo");
    const slug = trackSlug(`recon-idem-${Date.now()}`);
    const file = makeFile([{ slug, repos: ["acme/myrepo"] }]);

    const first = reconcileAll(file, { claudeBin: "true" });
    const second = reconcileAll(file, { claudeBin: "true" });

    assert.equal(second.agents[0].launch.action, "noop-running");
    assert.equal(second.agents[0].repos[0].worktreeCreated, false);
    assert.equal(readLinks().filter((c) => c.name === slug).length, 1);
    assert.equal(first.agents[0].launch.card.id, second.agents[0].launch.card.id);
  });

  test("a missing canonical clone is a loud error (IaC owns provisioning)", () => {
    const slug = trackSlug(`recon-missing-${Date.now()}`);
    assert.throws(
      () => reconcileAgent({ slug, repos: ["acme/nope"] }, makeFile([]), { claudeBin: "true" }),
      /Canonical clone .* is missing/
    );
  });

  test("prune tears down an agent removed from config", () => {
    provisionRepo(root, reposDir, "myrepo");
    const slug = trackSlug(`recon-prune-${Date.now()}`);
    reconcileAll(makeFile([{ slug, repos: ["acme/myrepo"] }]), { claudeBin: "true" });
    execSync(`tmux has-session -t ${slug}`);

    const pruneResult = reconcileAll(makeFile([]), { claudeBin: "true", prune: true });
    assert.deepEqual(pruneResult.pruned, [slug]);

    assert.throws(() => execSync(`tmux has-session -t ${slug} 2>/dev/null`), "tmux session should be gone");
    assert.equal(readLinks().find((c) => c.name === slug)?.manuallyArchived, true);
    assert.ok(!existsSync(join(workspacesDir, slug)), "workspace should be removed");
  });
});
