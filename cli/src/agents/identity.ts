import { uuidv5 } from "../uuid.js";
import { Runtime } from "./runtime.js";
import type { AgentHost } from "./config.js";
import { rushSessionNameFor } from "./rush-host.js";

/// A stable, readable identity for a long-lived agent. Everything humans see or
/// type is the readable slug; the session id is a deterministic UUID. For Claude
/// it is the --session-id / --resume key; for Codex (which mints its own id) it
/// is still the stable hook-events correlation key, passed to the hook via env.
export interface AgentIdentity {
  /// Readable slug, e.g. "dependabot-scout". Source of truth for the identity.
  slug: string;
  /// Which agent CLI drives this agent.
  runtime: Runtime;
  /// Where the agent's process runs.
  host: AgentHost;
  /// Deterministic UUIDv5 of the slug. Claude --session-id/--resume key, and the
  /// hook-events correlation key for both runtimes.
  sessionId: string;
  /// The session name on the card: the slug on tmux, `rush-<host id>` on a
  /// rush host, where the host id is the first eight hex digits of sessionId.
  tmuxName: string;
  /// kanban card name (== slug).
  cardName: string;
  /// git worktree name (== slug).
  worktreeName: string;
}

const SLUG_RE = /^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/;

export function isValidSlug(slug: string): boolean {
  return SLUG_RE.test(slug) && slug.length <= 60;
}

export function agentIdentity(
  slug: string,
  runtime: Runtime = "claude",
  host: AgentHost = "tmux"
): AgentIdentity {
  if (!isValidSlug(slug)) {
    throw new Error(
      `Invalid agent slug "${slug}" (use lowercase letters, digits and hyphens; max 60 chars)`
    );
  }
  const sessionId = uuidv5(slug);
  return {
    slug,
    runtime,
    host,
    sessionId,
    tmuxName: host === "rush" ? rushSessionNameFor(sessionId) : slug,
    cardName: slug,
    worktreeName: slug,
  };
}
