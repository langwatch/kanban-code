/**
 * A rush host whose worktree was deleted under it: rush starts a resting host
 * again in its cwd and fails with `fork/exec <rush>: no such file or
 * directory` when that directory is gone. Kanban adds the worktree again from
 * its branch before a send or a start, and otherwise names the missing
 * directory.
 */

import { strict as assert } from "node:assert";
import { execFileSync } from "node:child_process";
import { chmodSync, existsSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, test } from "node:test";
import { pasteTmuxPrompt, setRushPath, setTmuxCommandRunner } from "./data.js";
import { ensureSessionDir, isMissingCwdError } from "./git.js";

const NAME = "clear-meadow-a7ec";
let root: string;
let worktree: string;

function sh(script: string): string {
  return execFileSync("/bin/sh", ["-c", script], { cwd: root, encoding: "utf-8" });
}

function deleteWorktree(): void {
  sh(`rm -rf .claude/worktrees/${NAME} && git worktree prune`);
}

beforeEach(() => {
  root = realpathSync(mkdtempSync(join(tmpdir(), "kanban-sessiondir-")));
  worktree = join(root, ".claude/worktrees", NAME);
  sh(
    `git init -q -b main && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init && git worktree add -q -b ${NAME} .claude/worktrees/${NAME}`
  );
});

afterEach(() => {
  setTmuxCommandRunner(undefined);
  setRushPath(undefined);
  rmSync(root, { recursive: true, force: true });
});

describe("ensureSessionDir", () => {
  test("adds a deleted worktree again from its branch", () => {
    deleteWorktree();
    const outcome = ensureSessionDir(worktree);
    assert.deepEqual(outcome, { kind: "restored", path: worktree, branch: NAME });
    assert.equal(sh(`git -C .claude/worktrees/${NAME} rev-parse --abbrev-ref HEAD`).trim(), NAME);
  });

  test("uses the branch git still records for the deleted worktree", () => {
    sh(`git -C .claude/worktrees/${NAME} checkout -q -b feat/run-concurrency && rm -rf .claude/worktrees/${NAME}`);
    const outcome = ensureSessionDir(worktree);
    assert.deepEqual(outcome, { kind: "restored", path: worktree, branch: "feat/run-concurrency" });
  });

  test("makes a branch gone locally and on origin again from origin's default branch, at the same path", () => {
    sh(`git init -q --bare -b main .origin.git && git remote add origin "$PWD/.origin.git" && git push -q origin main && git fetch -q origin && git remote set-head origin main`);
    deleteWorktree();
    sh(`git branch -q -D ${NAME}`);
    assert.deepEqual(ensureSessionDir(worktree), { kind: "created", path: worktree, branch: NAME, base: "origin/main" });
    assert.equal(sh(`git -C .claude/worktrees/${NAME} rev-parse --abbrev-ref HEAD`).trim(), NAME);
  });

  test("a pruned worktree whose branch has a slash comes back on that branch", () => {
    const dir = join(root, ".worktrees/feat-home-makeover");
    sh(`git worktree add -q -b feat/home-makeover .worktrees/feat-home-makeover && rm -rf .worktrees/feat-home-makeover && git worktree prune`);
    assert.deepEqual(ensureSessionDir(dir), { kind: "restored", path: dir, branch: "feat/home-makeover" });
  });

  test("reports git refusing to add the worktree, and never picks another folder", () => {
    deleteWorktree();
    sh(`git worktree add -q .worktrees/other ${NAME}`);
    const outcome = ensureSessionDir(worktree);
    assert.equal(outcome.kind, "failed");
    assert.ok(!existsSync(worktree));
  });

  test("tells rush's missing-cwd failure apart", () => {
    assert.ok(isMissingCwdError("rush: fork/exec /usr/local/bin/rush: no such file or directory"));
    assert.ok(!isMissingCwdError("session not found"));
  });
});

describe("a send to a rush host whose worktree is gone", () => {
  function fakeRush(cwd: string): void {
    const bin = join(root, "fake-rush");
    writeFileSync(
      bin,
      `#!/bin/sh\nif [ "$2" = info ]; then printf '{"id":"%s","sessionId":"s","cwd":"%s","state":"stopped","alive":false}' "$3" '${cwd}'; fi\n`
    );
    chmodSync(bin, 0o755);
    setRushPath(bin);
  }

  test("restores the worktree before the message goes", () => {
    deleteWorktree();
    fakeRush(worktree);
    const sent: string[] = [];
    setTmuxCommandRunner((command) => {
      sent.push(command);
      return "";
    });
    assert.deepEqual(pasteTmuxPrompt("rush-22d7452e", "hello"), { ok: true });
    assert.ok(existsSync(worktree));
    assert.equal(sent.length, 1);
  });

  test("names the missing directory when it cannot come back", () => {
    deleteWorktree();
    sh(`git worktree add -q .worktrees/other ${NAME}`);
    fakeRush(worktree);
    setTmuxCommandRunner(() => "");
    const result = pasteTmuxPrompt("rush-22d7452e", "hello");
    assert.equal(result.ok, false);
    assert.match(result.error ?? "", new RegExp(`${worktree.replaceAll("/", "\\/")} no longer exists`));
  });
});
