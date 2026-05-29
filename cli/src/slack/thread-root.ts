import { mkdirSync, writeFileSync, readFileSync, renameSync } from "node:fs";
import { dirname, join } from "node:path";
import { kanbanHome } from "../paths.js";

/// Slack thread root (the parent message ts) for an agent's current turn. A
/// received-prompt message opens a thread and the agent's activity for that
/// turn is posted as replies under it, so tool calls don't pile up at the
/// channel root. The prompt mirror and the assistant-turn mirror can run in
/// different processes (for Claude the daemon announces the prompt while the
/// bridge tails the transcript; for Codex the bridge does both), so the ts is
/// shared through this file rather than in-process state.

function rootPath(slug: string): string {
  return join(kanbanHome(), "thread-roots", slug);
}

/// Record the current thread root for an agent. Written atomically (tmp +
/// rename) so a concurrent reader never sees a partial ts.
export function writeThreadRoot(slug: string, ts: string): void {
  if (!slug || !ts) return;
  const path = rootPath(slug);
  mkdirSync(dirname(path), { recursive: true });
  const tmp = `${path}.tmp`;
  writeFileSync(tmp, ts);
  renameSync(tmp, path);
}

/// The current thread root for an agent, or undefined if none recorded yet.
export function readThreadRoot(slug: string): string | undefined {
  try {
    const ts = readFileSync(rootPath(slug), "utf-8").trim();
    return ts || undefined;
  } catch {
    return undefined;
  }
}
