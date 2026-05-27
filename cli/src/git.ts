import { execFileSync } from "node:child_process";

function git(args: string[], cwd?: string): string {
  return execFileSync("git", args, { cwd, encoding: "utf-8" }).trim();
}

function gitQuiet(args: string[], cwd?: string): boolean {
  try {
    execFileSync("git", args, { cwd, stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}

export function isGitRepo(dir: string): boolean {
  return gitQuiet(["-C", dir, "rev-parse", "--is-inside-work-tree"]);
}

/// The repo's default branch (origin/HEAD target), falling back to "main".
export function detectDefaultBranch(repoDir: string): string {
  try {
    const ref = git(["-C", repoDir, "symbolic-ref", "refs/remotes/origin/HEAD"]);
    return ref.replace("refs/remotes/origin/", "") || "main";
  } catch {
    return "main";
  }
}

function branchExists(repoDir: string, branch: string): boolean {
  return gitQuiet(["-C", repoDir, "show-ref", "--verify", "--quiet", `refs/heads/${branch}`]);
}

export interface WorktreeResult {
  created: boolean;
  path: string;
}

/// Ensure a git worktree for `repoDir` exists at `worktreePath` on `branch`.
///
/// First creation branches from `baseRef` (default origin/<default>). On
/// subsequent runs the existing worktree (with whatever WIP the agent has) is
/// left untouched, so reconcile never clobbers the agent's working state.
///
/// Because the IaC-managed canonical clone keeps `main` checked out, git itself
/// refuses to let this worktree check out `main` — that is the structural
/// guarantee that an agent is never working on the main branch. Keeping the
/// canonical clone clean and current is IaC's job, not the reconciler's.
export function ensureWorktree(
  repoDir: string,
  worktreePath: string,
  branch: string,
  baseRef?: string
): WorktreeResult {
  if (isGitRepo(worktreePath)) {
    return { created: false, path: worktreePath };
  }
  // Drop any stale administrative entry for a path that no longer exists.
  gitQuiet(["-C", repoDir, "worktree", "prune"]);

  const base = baseRef ?? `origin/${detectDefaultBranch(repoDir)}`;
  if (branchExists(repoDir, branch)) {
    git(["-C", repoDir, "worktree", "add", worktreePath, branch]);
  } else {
    git(["-C", repoDir, "worktree", "add", "-b", branch, worktreePath, base]);
  }
  return { created: true, path: worktreePath };
}

/// Remove a worktree (used when pruning a de-configured agent).
export function removeWorktree(repoDir: string, worktreePath: string): void {
  gitQuiet(["-C", repoDir, "worktree", "remove", "--force", worktreePath]);
  gitQuiet(["-C", repoDir, "worktree", "prune"]);
}
