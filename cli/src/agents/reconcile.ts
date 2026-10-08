import { mkdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import { AgentsFile, AgentConfig } from "./config.js";
import { agentIdentity } from "./identity.js";
import { ensureAgentSession, LaunchResult } from "./launch.js";
import { isGitRepo, ensureWorktree } from "../git.js";
import { readLinks, killTmuxSession } from "../data.js";
import { upsertCard, isoNow } from "../cards.js";

export interface ReconcileOptions {
  /// Override the agent binary (tests).
  bin?: string;
  /// Tear down agent-managed sessions/cards/worktrees no longer in config.
  prune?: boolean;
  /// Override the stagger between real launches (tests: 0).
  launchGapMs?: number;
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

  const launch = ensureAgentSession(agentIdentity(agent.slug, agent.runtime, agent.host), {
    cwd: workspace,
    model: agent.model,
    bin: opts.bin,
  });

  return { slug: agent.slug, workspace, repos, launch };
}

/// How long the first launched agent gets to refresh a shared credential
/// before the next one starts. Twelve claude agents resuming in the same
/// second all saw an expired OAuth access token, all raced the refresh, and
/// the provider's refresh-token rotation let one win: the other eleven came
/// up "Login expired" and sat dead until relaunched by hand. The leader
/// refreshes and writes the new token pair inside this window; everyone
/// after reads a fresh token and never refreshes at all.
const LEADER_CREDENTIAL_WINDOW_MS = 20_000;
/// The gap between the remaining launches, so a boot is not a stampede.
const FOLLOWER_LAUNCH_GAP_MS = 3_000;

/// Synchronous sleep: the reconcile path is synchronous end to end, and a
/// boot-time pause must actually hold the next launch back.
function sleepMs(ms: number): void {
  if (ms <= 0) return;
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

/// Reconcile every agent in the config, optionally pruning de-configured ones.
/// Launches are staggered: agents whose session is already in place cost no
/// wait, so a routine reconcile over a healthy fleet stays instant and the
/// gaps only spend time when processes actually start (boot, or a recovery).
export function reconcileAll(file: AgentsFile, opts: ReconcileOptions = {}): ReconcileResult {
  mkdirSync(file.workspacesDir, { recursive: true });

  const agents: AgentReconcileResult[] = [];
  let launched = 0;
  let pendingGapMs = 0;
  for (const a of file.agents) {
    // The gap trails a real launch, so a fleet whose sessions are all alive
    // reconciles with no waiting at all.
    sleepMs(pendingGapMs);
    pendingGapMs = 0;
    const result = reconcileAgent(a, file, opts);
    agents.push(result);
    if (result.launch.action !== "noop-running") {
      launched += 1;
      pendingGapMs =
        opts.launchGapMs ??
        (launched === 1 ? LEADER_CREDENTIAL_WINDOW_MS : FOLLOWER_LAUNCH_GAP_MS);
    }
  }
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
