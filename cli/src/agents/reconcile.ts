import { mkdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import { AgentsFile, AgentConfig } from "./config.js";
import { agentIdentity } from "./identity.js";
import { ensureAgentSession, LaunchResult } from "./launch.js";
import { isGitRepo, ensureWorktree } from "../git.js";
import { readLinks, killTmuxSession } from "../data.js";
import { upsertCard, isoNow } from "../cards.js";

export interface ReconcileOptions {
  /// Override the claude binary (tests).
  claudeBin?: string;
  /// Tear down agent-managed sessions/cards/worktrees no longer in config.
  prune?: boolean;
}

export interface RepoReconcileResult {
  name: string;
  worktreeCreated: boolean;
  worktree: string;
}

export interface AgentReconcileResult {
  slug: string;
  workspace: string;
  repos: RepoReconcileResult[];
  launch: LaunchResult;
}

export interface ReconcileResult {
  agents: AgentReconcileResult[];
  pruned: string[];
}

const agentBranch = (slug: string) => `agent/${slug}`;
const repoName = (spec: string) => spec.split("/")[1];

/// Reconcile a single agent. The canonical clone is provisioned and kept clean
/// + current by IaC; the reconciler only ensures a per-agent worktree of each
/// repo and launches/resumes the session with the workspace as cwd. Idempotent.
export function reconcileAgent(
  agent: AgentConfig,
  file: AgentsFile,
  opts: ReconcileOptions = {}
): AgentReconcileResult {
  const workspace = join(file.workspacesDir, agent.slug);
  mkdirSync(workspace, { recursive: true });

  const repos: RepoReconcileResult[] = [];
  for (const spec of agent.repos) {
    const name = repoName(spec);
    const repoDir = join(file.reposDir, name);
    if (!isGitRepo(repoDir)) {
      throw new Error(
        `Canonical clone for ${spec} is missing at ${repoDir}. ` +
          `Repo clones are provisioned and kept current by IaC, not the reconciler.`
      );
    }
    const worktree = join(workspace, name);
    const { created } = ensureWorktree(repoDir, worktree, agentBranch(agent.slug));
    repos.push({ name, worktreeCreated: created, worktree });
  }

  const launch = ensureAgentSession(agentIdentity(agent.slug), {
    cwd: workspace,
    model: agent.model,
    claudeBin: opts.claudeBin,
  });

  return { slug: agent.slug, workspace, repos, launch };
}

/// Reconcile every agent in the config, optionally pruning de-configured ones.
export function reconcileAll(file: AgentsFile, opts: ReconcileOptions = {}): ReconcileResult {
  mkdirSync(file.workspacesDir, { recursive: true });

  const agents = file.agents.map((a) => reconcileAgent(a, file, opts));
  const pruned = opts.prune ? pruneStale(file) : [];
  return { agents, pruned };
}

/// Tear down agent-managed cards whose slug is no longer configured. A card is
/// "agent-managed" when its worktree path is exactly <workspacesDir>/<name> —
/// the layout reconcileAgent creates — which avoids touching unrelated cards.
function pruneStale(file: AgentsFile): string[] {
  const configured = new Set(file.agents.map((a) => a.slug));
  const pruned: string[] = [];

  for (const card of readLinks()) {
    if (card.manuallyArchived) continue;
    const name = card.name;
    if (!name || configured.has(name)) continue;
    const managedPath = join(file.workspacesDir, name);
    if (card.worktreeLink?.path !== managedPath) continue;

    if (card.tmuxLink?.sessionName) killTmuxSession(card.tmuxLink.sessionName);
    upsertCard({ ...card, manuallyArchived: true, updatedAt: isoNow() });
    try {
      rmSync(managedPath, { recursive: true, force: true });
    } catch {
      /* best effort */
    }
    pruned.push(name);
  }
  return pruned;
}
