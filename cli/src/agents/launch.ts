import { AgentIdentity } from "./identity.js";
import {
  hasTmuxSession,
  createTmuxSession,
  captureTmuxPane,
  sendTmuxKey,
  sendTmuxEnter,
  findSessionJsonl,
  findCodexRollout,
  killTmuxSession,
  rushIdFromSessionName,
} from "../data.js";
import {
  listAgentRushHosts,
  rushHostId,
  rushHostInPlace,
  rushSessionNameFor,
  rushStartArgs,
  startRushHost,
  stopRushHost,
  RushHostInfo,
  RUSH_AGENT_META,
  RUSH_CARD_META,
  RUSH_SESSION_META,
} from "./rush-host.js";
import { upsertCard, isoNow, findCardByName } from "../cards.js";
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

/// Idempotently ensure an agent's session is running and its kanban card
/// reflects reality. An agent whose host is rush goes to ensureRushAgentSession;
/// the rest run in tmux. Decides launch vs resume vs no-op:
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
  if (identity.host === "rush") return ensureRushAgentSession(identity, opts);

  const spec = runtimeSpec(identity.runtime);
  const bin = opts.bin ?? spec.bin;
  const skipPerms = opts.skipPermissions ?? true;

  // An agent moving off rush: its host would run the same conversation next
  // to the tmux one.
  const previous = findCardByName(identity.cardName)?.tmuxLink?.sessionName;
  const previousRushId = previous ? rushIdFromSessionName(previous) : undefined;
  if (previousRushId) stopRushHost(previousRushId);

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
    // Before the process starts, not after: a question the runtime asks on
    // its way up is one nothing here can answer.
    spec.prepareWorkspace?.(opts.cwd);
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

/// The rush half of ensureAgentSession, for a Claude agent on a rush host:
///   - a host of this agent running or resting      -> no-op (a message wakes a resting one)
///   - a saved host that never took a turn           -> no-op (a message wakes it from its own config)
///   - a transcript for the session id               -> `rush session start --resume`
///   - otherwise                                     -> `rush session start`
/// The host id is the first eight hex digits of the session id, so the card's
/// session name `rush-<host id>` is known before the host starts. A tmux
/// session left from before the agent moved to rush is killed first, so two
/// processes never run the same conversation.
export function ensureRushAgentSession(
  identity: AgentIdentity,
  opts: LaunchOptions
): LaunchResult {
  const skipPerms = opts.skipPermissions ?? true;
  const existing = findCardByName(identity.cardName);
  const cardId = existing?.id ?? generateKsuid("card");

  if (hasTmuxSession(identity.slug)) killTmuxSession(identity.slug);

  const hosts = listAgentRushHosts(identity.slug);
  const inPlace = pickHost(hosts.filter(rushHostInPlace), identity.sessionId);

  let action: LaunchAction;
  let command: string | undefined;
  let sessionId: string;
  let hostId: string;

  if (inPlace) {
    action = "noop-running";
    sessionId = inPlace.sessionId;
    hostId = inPlace.id;
  } else {
    sessionId = opts.forceFresh ? randomUUID() : identity.sessionId;
    hostId = rushHostId(sessionId);
    const resume = !opts.forceFresh && !!findSessionJsonl(sessionId);
    const saved = hosts.find((h) => h.id === hostId);
    if (saved && !resume) {
      action = "noop-running";
    } else {
      const start = {
        cwd: opts.cwd,
        sessionId,
        resume,
        name: identity.slug,
        model: opts.model,
        permissionMode: skipPerms ? "bypassPermissions" : undefined,
        binary: opts.bin,
        env: {
          ...(opts.env ?? {}),
          KANBAN_SESSION_ID: sessionId,
          KANBAN_SLUG: identity.slug,
        },
        meta: {
          [RUSH_SESSION_META]: rushSessionNameFor(sessionId),
          [RUSH_AGENT_META]: identity.slug,
          [RUSH_CARD_META]: cardId,
        },
      };
      command = ["rush", ...rushStartArgs(start)].join(" ");
      runtimeSpec(identity.runtime).prepareWorkspace?.(opts.cwd);
      const started = startRushHost(start);
      if (started?.id) hostId = started.id;
      action = resume ? "resumed" : "launched";
    }
  }

  const launchIdentity: AgentIdentity = { ...identity, sessionId, tmuxName: `rush-${hostId}` };
  const card = upsertAgentCard(launchIdentity, opts.cwd, cardId);
  return {
    action,
    identity: launchIdentity,
    sessionId,
    tmuxName: launchIdentity.tmuxName,
    command,
    card,
    named: false,
  };
}

/// The host on the agent's stable session id when there is one, else the
/// newest of the others (a forced-fresh launch mints its own id).
function pickHost(hosts: RushHostInfo[], stableSessionId: string): RushHostInfo | undefined {
  return hosts.find((h) => h.sessionId === stableSessionId) ?? hosts[hosts.length - 1];
}

/// How long a runtime named after launch gets to come up. Codex spends a few
/// seconds on its first frame, and a command typed before then is lost.
const NAME_READY_TIMEOUT_MS = 15_000;
/// The gap between pane reads while waiting for that first frame.
const NAME_POLL_MS = 500;
/// How long the typed command gets to show up in the composer. Seeing it is
/// what says the runtime read the keystrokes and drew them, which an Enter
/// sent before then is dropped by.
const NAME_TYPED_MS = 3_000;
/// How long one Enter gets to clear the composer before another is sent. A
/// TUI still loading a resumed session drops the first one silently.
const NAME_SUBMIT_MS = 1_500;
/// How many Enters the command gets. An Enter on a composer the runtime has
/// already cleared does nothing, so retrying costs a keystroke and no more.
const NAME_SUBMIT_ATTEMPTS = 4;

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
      return submit({ tmuxName, command, io });
    }
    io.sleep(NAME_POLL_MS);
  }
  return false;
}

/// Run a command already typed into the composer, and answer whether the
/// runtime ran it.
///
/// The composer is read before the first Enter and after every one. Reading
/// it first is what makes the answer mean anything: a pane that has not yet
/// drawn the command looks exactly like one that has already run it, so an
/// Enter sent before the runtime rendered its own keystrokes would be counted
/// as a success by the very check meant to catch it. That is what named
/// nothing on a box while reporting that it had.
///
/// Then the Enter is repeated. A runtime still loading a resumed session
/// drops the first one with no sign of it, and an Enter on a composer it has
/// since cleared does nothing, so retrying costs a keystroke and never a
/// second command.
function submit({
  tmuxName,
  command,
  io,
}: {
  tmuxName: string;
  command: string;
  io: NameSessionIO;
}): boolean {
  if (!waitUntil({ io, tmuxName, timeoutMs: NAME_TYPED_MS, done: (pane) => pane.includes(command) })) {
    return false;
  }
  for (let attempt = 0; attempt < NAME_SUBMIT_ATTEMPTS; attempt++) {
    if (!io.enter(tmuxName).ok) return false;
    const ran = waitUntil({
      io,
      tmuxName,
      timeoutMs: NAME_SUBMIT_MS,
      done: (pane) => !pane.includes(command),
    });
    if (ran) return true;
  }
  return false;
}

/// Read the pane until it says what we are waiting for, or the time is up.
function waitUntil({
  io,
  tmuxName,
  timeoutMs,
  done,
}: {
  io: NameSessionIO;
  tmuxName: string;
  timeoutMs: number;
  done: (pane: string) => boolean;
}): boolean {
  const deadline = io.now() + timeoutMs;
  while (io.now() < deadline) {
    if (done(io.capture(tmuxName))) return true;
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
function upsertAgentCard(identity: AgentIdentity, cwd: string, cardId?: string): Link {
  const existing = findCardByName(identity.cardName);
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
    id: existing?.id ?? cardId ?? generateKsuid("card"),
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
