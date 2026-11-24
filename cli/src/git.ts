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
  | { kind: "created"; path: string; branch: string; base: string }
  | { kind: "failed"; path: string; reason: string }
  | { kind: "missing"; path: string };

/// Whether the directory is there after `ensureSessionDir`.
export function isUsableSessionDir(outcome: SessionDirOutcome): boolean {
  return outcome.kind === "present" || outcome.kind === "restored" || outcome.kind === "created";
}

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

/// A local or origin branch whose name, with `/` as `-`, is the worktree
/// folder's name (or `worktree-<name>`): `.worktrees/feat-home` is `feat/home`.
function branchNamedLike(root: string, name: string): string | undefined {
  let out = "";
  try {
    out = git(["-C", root, "for-each-ref", "--format=%(refname)", "refs/heads", "refs/remotes/origin"]);
  } catch {
    return undefined;
  }
  for (const ref of out.split("\n")) {
    const branch = ref.replace(/^refs\/heads\//, "").replace(/^refs\/remotes\/origin\//, "");
    if (!branch || branch === "HEAD") continue;
    const flat = branch.replaceAll("/", "-");
    if (flat === name || flat === `worktree-${name}`) return branch;
  }
  return undefined;
}

function gitError(args: string[]): string | undefined {
  try {
    execFileSync("git", args, { stdio: ["ignore", "ignore", "pipe"], encoding: "utf-8" });
    return undefined;
  } catch (e: any) {
    return String(e?.stderr || e?.message || e).replace(/\s+/g, " ").trim() || "git failed";
  }
}

/// Puts a session's deleted worktree back at the same path before a rush
/// host starts in it. The branch is `branch`, else the one git still
/// records, else one named like the folder, else the folder's name. After a
/// prune it is added from the local branch, else from `origin/<branch>`
/// (fetched first), else made from the latest origin default branch.
export function ensureSessionDir(dir: string, branch?: string, repoRoot?: string): SessionDirOutcome {
  if (!dir || existsSync(dir)) return { kind: "present", path: dir };
  const root = repoRoot ?? projectRootOf(dir);
  if (!root || !existsSync(root) || !isGitRepo(root)) return { kind: "missing", path: dir };
  const folder = dir.slice(dir.lastIndexOf("/") + 1);
  const name = branch || recordedBranch(root, dir) || branchNamedLike(root, folder) || folder;
  gitQuiet(["-C", root, "worktree", "prune"]);
  mkdirSync(dirname(dir), { recursive: true });
  if (branchExists(root, name)) {
    const error = gitError(["-C", root, "worktree", "add", dir, name]);
    return error ? { kind: "failed", path: dir, reason: error } : { kind: "restored", path: dir, branch: name };
  }
  gitQuiet(["-C", root, "fetch", "-q", "origin", `+refs/heads/${name}:refs/remotes/origin/${name}`]);
  if (gitQuiet(["-C", root, "show-ref", "--verify", "--quiet", `refs/remotes/origin/${name}`])) {
    const error = gitError(["-C", root, "worktree", "add", "--track", "-b", name, dir, `origin/${name}`]);
    return error ? { kind: "failed", path: dir, reason: error } : { kind: "restored", path: dir, branch: name };
  }
  gitQuiet(["-C", root, "fetch", "-q", "origin"]);
  let originHead = "";
  try {
    originHead = git(["-C", root, "symbolic-ref", "-q", "--short", "refs/remotes/origin/HEAD"]);
  } catch {}
  const base =
    [originHead, "origin/main", "origin/master", "main", "master", "HEAD"].find(
      (c) => c && gitQuiet(["-C", root, "rev-parse", "--verify", "--quiet", `${c}^{commit}`])
    ) ?? "HEAD";
  const error = gitError(["-C", root, "worktree", "add", "--no-track", "-b", name, dir, base]);
  return error ? { kind: "failed", path: dir, reason: error } : { kind: "created", path: dir, branch: name, base };
}

/// Whether a rush failure is rush unable to start a process in a directory
/// that does not exist (`fork/exec <rush>: no such file or directory`).
export function isMissingCwdError(message: string): boolean {
  return message.includes("fork/exec") && message.includes("no such file or directory");
}

/// The error a session whose directory is gone ends with.
export function missingSessionDirMessage(dir: string, outcome: SessionDirOutcome): string {
  if (outcome.kind === "failed") {
    return `the session's working directory ${dir} no longer exists and git could not add the worktree again: ${outcome.reason}`;
  }
  return `the session's working directory ${dir} no longer exists`;
}
