import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";

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

export type SessionDirOutcome =
  | { kind: "present"; path: string }
  | { kind: "restored"; path: string; branch: string }
  | { kind: "projectRoot"; path: string }
  | { kind: "missing"; path: string };

/// The project root a worktree path belongs to: the part before
/// `/.claude/worktrees/` or `/.worktrees/`.
export function projectRootOf(dir: string): string | undefined {
  for (const marker of ["/.claude/worktrees/", "/.worktrees/"]) {
    const i = dir.lastIndexOf(marker);
    if (i > 0) return dir.slice(0, i);
  }
  return undefined;
}

/// The branch git still records for a worktree whose directory is gone.
function recordedBranch(root: string, dir: string): string | undefined {
  const tail = dir.slice(root.length);
  let out = "";
  try {
    out = git(["-C", root, "worktree", "list", "--porcelain"]);
  } catch {
    return undefined;
  }
  let current = "";
  for (const line of out.split("\n")) {
    if (line.startsWith("worktree ")) current = line.slice("worktree ".length);
    else if (line.startsWith("branch refs/heads/") && current.endsWith(tail)) {
      return line.slice("branch refs/heads/".length);
    }
  }
  return undefined;
}

/// Leaves a session's working directory in place before a rush host starts
/// in it: a worktree deleted under a card is added again from its branch (the
/// one git still records, else `branch`, else the directory's name); with
/// that branch gone too, the project root is returned instead.
export function ensureSessionDir(dir: string, branch?: string, repoRoot?: string): SessionDirOutcome {
  if (!dir || existsSync(dir)) return { kind: "present", path: dir };
  const root = repoRoot ?? projectRootOf(dir);
  if (!root || !existsSync(root) || !isGitRepo(root)) return { kind: "missing", path: dir };
  const name = branch || recordedBranch(root, dir) || dir.slice(dir.lastIndexOf("/") + 1);
  gitQuiet(["-C", root, "worktree", "prune"]);
  mkdirSync(dirname(dir), { recursive: true });
  if (branchExists(root, name) && gitQuiet(["-C", root, "worktree", "add", dir, name])) {
    return { kind: "restored", path: dir, branch: name };
  }
  if (
    gitQuiet(["-C", root, "show-ref", "--verify", "--quiet", `refs/remotes/origin/${name}`]) &&
    gitQuiet(["-C", root, "worktree", "add", "--track", "-b", name, dir, `origin/${name}`])
  ) {
    return { kind: "restored", path: dir, branch: name };
  }
  return { kind: "projectRoot", path: root };
}

/// Whether a rush failure is rush unable to start a process in a directory
/// that does not exist (`fork/exec <rush>: no such file or directory`).
export function isMissingCwdError(message: string): boolean {
  return message.includes("fork/exec") && message.includes("no such file or directory");
}

/// The error a session whose directory is gone ends with.
export function missingSessionDirMessage(dir: string, outcome: SessionDirOutcome): string {
  if (outcome.kind === "projectRoot") {
    return `the session's working directory ${dir} no longer exists and its branch is gone too; resume the card to continue in the project root ${outcome.path}`;
  }
  return `the session's working directory ${dir} no longer exists`;
}
