/// Runtime abstraction for the headless agent engine. The engine was built for
/// Claude Code; this table lets a single agent be driven by a different CLI
/// (currently Codex) without branching all over launch/daemon/bridge. It mirrors
/// the macOS app's CodingAssistant entity, scoped to what the headless path needs.

export type Runtime = "claude" | "codex";

export const RUNTIMES: readonly Runtime[] = ["claude", "codex"] as const;

export function isRuntime(v: unknown): v is Runtime {
  return v === "claude" || v === "codex";
}

export interface BuildArgsInput {
  /// The stable session id (uuidv5 of the slug). Used as Claude's --session-id
  /// and, for both runtimes, as the hook-events correlation key via env.
  sessionId: string;
  /// Readable agent slug.
  slug: string;
  /// Resume an existing session rather than launching fresh.
  resume: boolean;
  /// Skip permission/approval prompts (autonomous agents).
  skipPermissions: boolean;
  /// Model alias/name, if pinned.
  model?: string;
}

export interface RuntimeSpec {
  /// The CLI binary.
  bin: string;
  /// Build the argv after the binary.
  buildArgs(input: BuildArgsInput): string[];
  /// Whether this runtime can resume a prior session. Claude resumes by our
  /// stable session id (--resume <uuid>); Codex mints its own id but can resume
  /// the most recent session for the launch cwd (resume --last), so a box
  /// restart keeps the agent's context instead of starting from scratch.
  canResume: boolean;
  /// Whether the daemon's context-threshold self-compaction applies. Codex
  /// auto-compacts on its own and exposes no context introspection, so off.
  selfCompact: boolean;
  /// Config dir under $HOME (for hooks/skills install).
  configDirName: string;
  /// The command that names a started session, for a runtime that takes no
  /// name at launch. Claude has none: --name in buildArgs already named it.
  nameCommand?(slug: string): string;
  /// What the pane shows once the runtime will accept that command. Nothing
  /// is typed into a session that has not shown it.
  readyMarker?: string;
}

const claude: RuntimeSpec = {
  bin: "claude",
  canResume: true,
  selfCompact: true,
  configDirName: ".claude",
  buildArgs({ sessionId, slug, resume, skipPermissions, model }) {
    const args: string[] = [];
    // --name on both paths: a fresh session is born named, and a resume
    // re-asserts the slug so sessions created before naming existed pick
    // their name up on the next boot.
    if (resume) args.push("--resume", sessionId, "--name", slug);
    else args.push("--session-id", sessionId, "--name", slug);
    if (skipPermissions) args.push("--dangerously-skip-permissions");
    if (model) args.push("--model", model);
    return args;
  },
};

const codex: RuntimeSpec = {
  bin: "codex",
  canResume: true,
  selfCompact: false,
  configDirName: ".codex",
  // Codex takes no name at launch. It names a thread through its own /rename,
  // which is what `codex resume <name>` and the LangWatch session harvest both
  // read, so the agent's slug is what labels the session in either.
  nameCommand: (slug) => `/rename ${slug}`,
  // The separator codex draws in the status line under its composer, and only
  // once it will accept a command: before that the pane holds its banner, or
  // the directory-trust question, and a command typed into either is lost or
  // answers the wrong question. A separator rather than any wording, so a
  // codex that rewrites its own UI text still names its sessions.
  readyMarker: "·",
  buildArgs({ resume, skipPermissions, model }) {
    // --no-alt-screen keeps Codex inline so tmux send-keys paste works (no TUI
    // alt-screen). The bypass flags are Codex's equivalent of Claude's
    // --dangerously-skip-permissions; --dangerously-bypass-hook-trust skips the
    // interactive hook-trust gate so our hooks run unattended. These are global
    // flags and must come before the `resume` subcommand.
    const args = ["--no-alt-screen"];
    if (skipPermissions) {
      args.push("--dangerously-bypass-approvals-and-sandbox", "--dangerously-bypass-hook-trust");
    }
    if (resume) {
      // Continue the most recent session for the launch cwd. Codex filters
      // resume candidates by cwd, and each agent runs in its own workspace, so
      // --last reliably picks this agent's session. The model is whatever the
      // resumed session already used, so it is not re-passed here.
      args.push("resume", "--last");
    } else if (model) {
      args.push("-m", model);
    }
    return args;
  },
};

const SPECS: Record<Runtime, RuntimeSpec> = { claude, codex };

export function runtimeSpec(runtime: Runtime): RuntimeSpec {
  return SPECS[runtime];
}
