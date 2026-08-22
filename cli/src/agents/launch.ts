import { AgentIdentity } from "./identity.js";
import {
  hasTmuxSession,
  createTmuxSession,
  captureTmuxPane,
  sendTmuxKey,
  sendTmuxEnter,
  findSessionJsonl,
  findCodexRollout,
  readLinks,
} from "../data.js";
import { upsertCard, isoNow } from "../cards.js";
import { generateKsuid } from "../ksuid.js";
import { Link, ManualOverrides } from "../types.js";
import { runtimeSpec, RuntimeSpec } from "./runtime.js";
import { randomUUID } from "node:crypto";

export interface LaunchOptions {
  /// Working directory for the session (the agent's workspace / worktree root).
  cwd: string;
  /// Extra args appended to the agent invocation.
  extraArgs?: string[];
  /// Environment variables exported into the tmux session.
  env?: Record<string, string>;
  /// Model alias or full name.
  model?: string;
  /// Autonomous agents skip permission prompts by default.
  skipPermissions?: boolean;
  /// Override the agent binary (tests).
  bin?: string;
  /// Force a fresh session even if a prior one could be resumed. For ephemeral
  /// agents (e.g. a room's swarm) whose readable slug is recycled: resuming
  /// would reload a stale or unrelated conversation under the same id.
  forceFresh?: boolean;
  /// How long a runtime that is named after launch gets to come up before the
  /// name is given up on. A loaded box draws its first frame slowly.
  nameTimeoutMs?: number;
}

export type LaunchAction = "noop-running" | "launched" | "resumed";

export interface LaunchResult {
  action: LaunchAction;
  identity: AgentIdentity;
  sessionId: string;
  tmuxName: string;
  command?: string;
  card: Link;
  /// Whether the session was named after it started. False for a runtime named
  /// by a launch flag, for a session already running, and for one that never
  /// came up in time.
  named: boolean;
}

const DEFAULT_OVERRIDES: ManualOverrides = {
  worktreePath: false,
  tmuxSession: false,
  name: false,
  column: false,
  prLink: false,
  issueLink: false,
};

/// Idempotently ensure an agent's session is running in tmux and its kanban card
/// reflects reality. Decides launch vs resume vs no-op:
///   - tmux session already alive            -> no-op (never restart a live agent)
///   - runtime can resume + prior session     -> resume
///   - otherwise                              -> fresh launch
/// Claude finds its prior session by our stable id (the transcript jsonl);
/// Codex mints its own id, so its prior session is detected by the newest
/// rollout under the launch cwd and resumed with `resume --last`.
export function ensureAgentSession(
  identity: AgentIdentity,
  opts: LaunchOptions
): LaunchResult {
  const spec = runtimeSpec(identity.runtime);
  const bin = opts.bin ?? spec.bin;
  const skipPerms = opts.skipPermissions ?? true;

  const tmuxAlive = hasTmuxSession(identity.tmuxName);
  const sessionExists =
    spec.canResume &&
    !opts.forceFresh &&
    (identity.runtime === "codex"
      ? !!findCodexRollout(opts.cwd)
      : !!findSessionJsonl(identity.sessionId));

  // A forced-fresh ephemeral launch must NOT reuse the stable uuidv5(slug)
  // session id: a recycled slug collides with its own prior transcript, so
  // `claude --session-id <existing>` without --resume errors "Session ID
  // already in use" and the card<->session link breaks. Mint a unique id for
  // that launch so it starts cleanly. The readable tmux name stays stable.
  const launchIdentity: AgentIdentity =
    opts.forceFresh && !tmuxAlive
      ? { ...identity, sessionId: randomUUID() }
      : identity;

  let action: LaunchAction;
  let command: string | undefined;
  let named = false;

  if (tmuxAlive) {
    action = "noop-running";
  } else {
    const args = spec.buildArgs({
      sessionId: launchIdentity.sessionId,
      slug: launchIdentity.slug,
      resume: sessionExists,
      skipPermissions: skipPerms,
      model: opts.model,
    });
    action = sessionExists ? "resumed" : "launched";
    if (opts.extraArgs?.length) args.push(...opts.extraArgs);
    command = [bin, ...args].join(" ");

    // Both runtimes' hooks correlate events to this agent via these env vars,
    // so the daemon/bridge key on our stable session id regardless of the id
    // the runtime mints internally. The session's display name is NOT an env
    // var: claude is named through its own --name flag (see buildArgs), which
    // is what its UI, /resume picker and any observer of the session read.
    const env = {
      ...(opts.env ?? {}),
      KANBAN_SESSION_ID: launchIdentity.sessionId,
      KANBAN_SLUG: launchIdentity.slug,
    };
    const res = createTmuxSession(launchIdentity.tmuxName, opts.cwd, command, env);
    if (!res.ok) {
      throw new Error(`Failed to create tmux session "${identity.tmuxName}": ${res.error}`);
    }
    named = nameStartedSession({
      tmuxName: launchIdentity.tmuxName,
      slug: launchIdentity.slug,
      spec,
      timeoutMs: opts.nameTimeoutMs,
    });
  }

  const card = upsertAgentCard(launchIdentity, opts.cwd);
  return {
    action,
    identity: launchIdentity,
    sessionId: launchIdentity.sessionId,
    tmuxName: launchIdentity.tmuxName,
    command,
    card,
    named,
  };
}

/// How long a runtime named after launch gets to come up. Codex spends a few
/// seconds on its first frame, and a command typed before then is lost.
const NAME_READY_TIMEOUT_MS = 15_000;
/// The gap between pane reads while waiting for that first frame.
const NAME_POLL_MS = 500;
/// The gap between typing the command and the Enter that submits it. A TUI
/// that sees the whole line and the Enter arrive together reads the Enter as
/// part of a paste and keeps the line in its composer instead of running it.
const NAME_SUBMIT_MS = 100;
/// How long the command gets to leave the composer before it counts as not
/// submitted.
const NAME_CONFIRM_MS = 3_000;

/// What naming a started session needs from the outside, so the wait can be
/// driven by a test without a real runtime on the other end.
export interface NameSessionIO {
  capture(tmuxName: string): string;
  type(tmuxName: string, text: string): { ok: boolean; error?: string };
  enter(tmuxName: string): { ok: boolean; error?: string };
  alive(tmuxName: string): boolean;
  sleep(ms: number): void;
  now(): number;
}

const REAL_NAME_SESSION_IO: NameSessionIO = {
  capture: (tmuxName) => captureTmuxPane(tmuxName),
  type: (tmuxName, text) => sendTmuxKey(tmuxName, text),
  enter: (tmuxName) => sendTmuxEnter(tmuxName),
  alive: (tmuxName) => hasTmuxSession(tmuxName),
  sleep: sleepMs,
  now: () => Date.now(),
};

/// Give a just-started session the name its runtime takes no launch flag for.
/// Answers whether the runtime took the name, not merely whether keys were
/// sent: a command that stayed in the composer named nothing.
///
/// Only ever called on a session that has just started and has been given no
/// prompt, so the command cannot land in the middle of a turn. A runtime that
/// does not come up in time is left unnamed rather than typed into blind: a
/// command sitting in the composer would ride out with the agent's first real
/// prompt.
export function nameStartedSession(
  {
    tmuxName,
    slug,
    spec,
    timeoutMs = NAME_READY_TIMEOUT_MS,
  }: {
    tmuxName: string;
    slug: string;
    spec: RuntimeSpec;
    timeoutMs?: number;
  },
  io: NameSessionIO = REAL_NAME_SESSION_IO
): boolean {
  const command = spec.nameCommand?.(slug);
  const marker = spec.readyMarker;
  if (!command || !marker) return false;

  const deadline = io.now() + timeoutMs;
  while (io.now() < deadline) {
    if (!io.alive(tmuxName)) return false;
    if (paneAccepts(io.capture(tmuxName), marker)) {
      if (!io.type(tmuxName, command).ok) return false;
      io.sleep(NAME_SUBMIT_MS);
      if (!io.enter(tmuxName).ok) return false;
      return commandLeftTheComposer({ tmuxName, command, io });
    }
    io.sleep(NAME_POLL_MS);
  }
  return false;
}

/// A submitted command is gone from the pane: the runtime clears its composer
/// and answers on a line of its own. One still on screen was typed and never
/// run, which is a session that is not named.
function commandLeftTheComposer({
  tmuxName,
  command,
  io,
}: {
  tmuxName: string;
  command: string;
  io: NameSessionIO;
}): boolean {
  const deadline = io.now() + NAME_CONFIRM_MS;
  while (io.now() < deadline) {
    if (!io.capture(tmuxName).includes(command)) return true;
    io.sleep(NAME_POLL_MS);
  }
  return false;
}

/// A runtime's status line is the last thing it draws, so the marker is looked
/// for there rather than anywhere in the pane: a banner scrolled off the top
/// must not read as ready.
function paneAccepts(pane: string, marker: string): boolean {
  const lines = pane.split("\n").filter((line) => line.trim() !== "");
  const last = lines[lines.length - 1];
  return last !== undefined && last.includes(marker);
}

/// Synchronous sleep: the launch path is synchronous end to end, so a wait
/// must actually hold it.
function sleepMs(ms: number): void {
  if (ms <= 0) return;
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
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
    assistant: identity.runtime,
    isRemote: false,
  };
  upsertCard(card);
  return card;
}
