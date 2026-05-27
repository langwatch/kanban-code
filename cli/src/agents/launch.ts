import { AgentIdentity } from "./identity.js";
import {
  hasTmuxSession,
  createTmuxSession,
  findSessionJsonl,
  readLinks,
} from "../data.js";
import { upsertCard, isoNow } from "../cards.js";
import { generateKsuid } from "../ksuid.js";
import { Link, ManualOverrides } from "../types.js";

export interface LaunchOptions {
  /// Working directory for the session (the agent's workspace / worktree root).
  cwd: string;
  /// Extra args appended to the claude invocation.
  extraArgs?: string[];
  /// Environment variables exported into the tmux session.
  env?: Record<string, string>;
  /// Model alias or full name (claude --model).
  model?: string;
  /// Autonomous agents skip permission prompts by default.
  skipPermissions?: boolean;
  /// Override the claude binary (tests).
  claudeBin?: string;
}

export type LaunchAction = "noop-running" | "launched" | "resumed";

export interface LaunchResult {
  action: LaunchAction;
  identity: AgentIdentity;
  sessionId: string;
  tmuxName: string;
  command?: string;
  card: Link;
}

const DEFAULT_OVERRIDES: ManualOverrides = {
  worktreePath: false,
  tmuxSession: false,
  name: false,
  column: false,
  prLink: false,
  issueLink: false,
};

/// Idempotently ensure an agent's Claude session is running in tmux and its
/// kanban card reflects reality. Decides launch vs resume vs no-op:
///   - tmux session already alive          -> no-op (never restart a live agent)
///   - a transcript exists for the session  -> resume (--resume <uuid>)
///   - neither                               -> fresh launch (--session-id <uuid>)
export function ensureAgentSession(
  identity: AgentIdentity,
  opts: LaunchOptions
): LaunchResult {
  const claudeBin = opts.claudeBin ?? "claude";
  const skipPerms = opts.skipPermissions ?? true;

  const tmuxAlive = hasTmuxSession(identity.tmuxName);
  const sessionExists = !!findSessionJsonl(identity.sessionId);

  let action: LaunchAction;
  let command: string | undefined;

  if (tmuxAlive) {
    action = "noop-running";
  } else {
    const args: string[] = [];
    if (sessionExists) {
      action = "resumed";
      args.push("--resume", identity.sessionId);
    } else {
      action = "launched";
      args.push("--session-id", identity.sessionId, "--name", identity.slug);
    }
    if (skipPerms) args.push("--dangerously-skip-permissions");
    if (opts.model) args.push("--model", opts.model);
    if (opts.extraArgs?.length) args.push(...opts.extraArgs);
    command = [claudeBin, ...args].join(" ");

    const res = createTmuxSession(identity.tmuxName, opts.cwd, command, opts.env ?? {});
    if (!res.ok) {
      throw new Error(`Failed to create tmux session "${identity.tmuxName}": ${res.error}`);
    }
  }

  const card = upsertAgentCard(identity, opts.cwd);
  return {
    action,
    identity,
    sessionId: identity.sessionId,
    tmuxName: identity.tmuxName,
    command,
    card,
  };
}

/// Reconcile the agent's card to current truth. Writes only when something
/// meaningful changed, so a healthy reconcile is a true no-op on disk.
function upsertAgentCard(identity: AgentIdentity, cwd: string): Link {
  const existing = readLinks().find((l) => l.name === identity.cardName);
  const sessionPath = findSessionJsonl(identity.sessionId);

  const unchanged =
    existing &&
    !existing.manuallyArchived &&
    existing.sessionLink?.sessionId === identity.sessionId &&
    existing.sessionLink?.sessionPath === sessionPath &&
    existing.tmuxLink?.sessionName === identity.tmuxName &&
    existing.worktreeLink?.path === cwd;
  if (unchanged) return existing;

  const now = isoNow();
  const card: Link = {
    id: existing?.id ?? generateKsuid("card"),
    name: identity.cardName,
    column: existing?.column ?? "in_progress",
    createdAt: existing?.createdAt ?? now,
    updatedAt: now,
    lastActivity: now,
    manualOverrides: existing?.manualOverrides ?? { ...DEFAULT_OVERRIDES, name: true },
    manuallyArchived: false,
    source: "manual",
    sessionLink: { sessionId: identity.sessionId, sessionPath },
    tmuxLink: { sessionName: identity.tmuxName },
    worktreeLink: { path: cwd },
    assistant: "claude",
    isRemote: false,
  };
  upsertCard(card);
  return card;
}
