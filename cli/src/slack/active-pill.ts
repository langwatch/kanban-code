import { mkdirSync, writeFileSync, readFileSync, renameSync, unlinkSync } from "node:fs";
import { dirname, join } from "node:path";
import { kanbanHome } from "../paths.js";

/// On-disk record of the "is working…" pill the bridge has set on an
/// agent's current channel-root anchor. The bridge keeps an in-memory
/// `active` map already; this file mirrors that map so a bridge restart
/// (config-sync triggers one on every applied bundle) doesn't drop the
/// pill until the agent's NEXT text post relights it. An agent that
/// goes long on tools with no intermediate text — common when it's
/// debugging or planning — would otherwise have its channel look dead
/// for the rest of the turn after a restart.
///
/// Same pattern as thread-root: atomic write (tmp + rename) per slug,
/// stored under ~/.kanban-code/active-pills/<slug>. We keep the record
/// even after a pill is cleared on a non-terminal turn-end so the
/// restart path always has SOMETHING to re-light to.

export interface PersistedPill {
  channelId: string;
  threadTs: string;
  label: string;
  /// Wall-clock when the pill was last set/refreshed. Used by the
  /// restore path: if a pill is much older than Slack's own idle
  /// behaviour suggests an agent is still working (say, 10 minutes
  /// without any refresh), we don't blindly re-light it on restart —
  /// the agent probably finished and Slack has already cleared it.
  lastSetMs: number;
}

function pillPath(slug: string): string {
  return join(kanbanHome(), "active-pills", slug);
}

export function writeActivePill(slug: string, pill: PersistedPill): void {
  if (!slug) return;
  const path = pillPath(slug);
  mkdirSync(dirname(path), { recursive: true });
  const tmp = `${path}.tmp`;
  writeFileSync(tmp, JSON.stringify(pill));
  renameSync(tmp, path);
}

export function readActivePill(slug: string): PersistedPill | undefined {
  try {
    const raw = readFileSync(pillPath(slug), "utf-8");
    const parsed = JSON.parse(raw) as Partial<PersistedPill>;
    if (!parsed.channelId || !parsed.threadTs || !parsed.label) return undefined;
    if (typeof parsed.lastSetMs !== "number") return undefined;
    return parsed as PersistedPill;
  } catch {
    return undefined;
  }
}

/// Best-effort delete. Used when the bridge explicitly clears a pill
/// (e.g. a terminal text post) so the next restart doesn't restore
/// something that was deliberately turned off.
export function clearActivePill(slug: string): void {
  if (!slug) return;
  try {
    unlinkSync(pillPath(slug));
  } catch {
    /* file may not exist — that's fine */
  }
}
