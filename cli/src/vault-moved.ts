/**
 * Secrets that moved to the Laze vault (docs/vault.md, "Moved to Laze").
 *
 * `vault/moved.json` maps a kv name to the Laze connection it became, or to
 * `deleted:<where it lives now>` for a name deleted outright. kv
 * serves none of them: it names the connection and the `laze vault` command
 * instead, and logs the hit to `vault/moved-hits.jsonl`, so the Kanban
 * copies are deleted only after a week in which nothing asked kv for them.
 */

import { appendFileSync, existsSync, mkdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { kanbanHome } from "./paths.js";

export const EXIT_MOVED = 78;

export function movedPath(home = kanbanHome()): string {
  return join(home, "vault", "moved.json");
}

export function movedHitsPath(home = kanbanHome()): string {
  return join(home, "vault", "moved-hits.jsonl");
}

/** kv name -> Laze connection; empty when the file is missing or unreadable. */
export function readMoved(path = movedPath()): Record<string, string> {
  if (!existsSync(path)) return {};
  try {
    const parsed = JSON.parse(readFileSync(path, "utf8"));
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return {};
    const out: Record<string, string> = {};
    for (const [name, connection] of Object.entries(parsed)) {
      if (typeof connection === "string" && connection) out[name] = connection;
    }
    return out;
  } catch {
    return {};
  }
}

/** The names among `names` (or the secrets they resolved to) that moved, with their connection. */
export function movedAmong(
  names: string[],
  moved: Record<string, string>,
  resolved: Record<string, string> = {}
): Array<{ asked: string; connection: string }> {
  const out: Array<{ asked: string; connection: string }> = [];
  for (const asked of names) {
    const connection = moved[asked] ?? moved[resolved[asked] ?? ""];
    if (connection) out.push({ asked, connection });
  }
  return out;
}

/** A `deleted:<where it lives now>` value marks a name deleted from kv, not moved to a connection. */
export const DELETED_PREFIX = "deleted:";

/** What kv prints for moved names: one line each, then how to ask Laze; deleted names say where they went. */
export function movedMessage(hits: Array<{ asked: string; connection: string }>): string {
  const deleted = hits.filter((h) => h.connection.startsWith(DELETED_PREFIX));
  const moved = hits.filter((h) => !h.connection.startsWith(DELETED_PREFIX));
  const lines = deleted.map((h) => `deleted from the Kanban vault: ${h.asked} (${h.connection.slice(DELETED_PREFIX.length)})`);
  lines.push(...moved.map((h) => `moved to laze vault: ${h.asked} (connection ${h.connection})`));
  const connections = [...new Set(moved.map((h) => h.connection))];
  if (connections.length > 0) {
    lines.push(
      `Use the Laze vault instead: laze vault run ${connections.join(" ")} --reason "<one plain sentence>" -- <cmd>` +
        ` (or laze vault env in a folder whose .env.vault names them)`
    );
  }
  return lines.map((l) => `kv: ${l}`).join("\n");
}

/** One line per asked name in the hits log; a write failure never blocks a command. */
export function logMovedHits(
  hits: Array<{ asked: string; connection: string }>,
  context: { mode: string; cwd: string; cardId?: string },
  path = movedHitsPath()
): void {
  if (hits.length === 0) return;
  try {
    mkdirSync(dirname(path), { recursive: true });
    const at = new Date().toISOString();
    appendFileSync(
      path,
      hits.map((h) => JSON.stringify({ at, name: h.asked, connection: h.connection, ...context }) + "\n").join(""),
      { mode: 0o600 }
    );
  } catch {
    // only for the retirement check
  }
}
