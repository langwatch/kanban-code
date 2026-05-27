import { uuidv5 } from "../uuid.js";

/// A stable, readable identity for a long-lived agent. Everything humans see or
/// type is the readable slug; only the Claude session id is a (deterministic)
/// UUID, because `claude --session-id` requires a valid UUID.
export interface AgentIdentity {
  /// Readable slug, e.g. "dependabot-scout". Source of truth for the identity.
  slug: string;
  /// Deterministic UUIDv5 of the slug — the Claude --session-id / --resume key.
  sessionId: string;
  /// tmux session name (== slug).
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

export function agentIdentity(slug: string): AgentIdentity {
  if (!isValidSlug(slug)) {
    throw new Error(
      `Invalid agent slug "${slug}" (use lowercase letters, digits and hyphens; max 60 chars)`
    );
  }
  return {
    slug,
    sessionId: uuidv5(slug),
    tmuxName: slug,
    cardName: slug,
    worktreeName: slug,
  };
}
