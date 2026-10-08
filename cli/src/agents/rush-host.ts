import { execFileSync } from "node:child_process";
import { findRush } from "../data.js";

/// Agents on a rush host are found by these host metas: the session name the
/// card uses, and the slug of the agent that owns the host.
export const RUSH_SESSION_META = "kanban_session";
export const RUSH_AGENT_META = "kanban_agent";
export const RUSH_CARD_META = "kanban_card";

/// A rush host as `rush session list --json` and `rush session start --json`
/// print it. Only the fields the agents engine reads.
export interface RushHostInfo {
  id: string;
  sessionId: string;
  cwd?: string;
  name?: string;
  /// starting, working, blocked, idle or stopped.
  state?: string;
  /// What a blocked host waits on: "asks: <question>" for a question, or the
  /// tool call it wants permission for.
  needs?: string;
  alive?: boolean;
  /// A host that went to rest after a turn: not running, and woken by the
  /// next message sent to it.
  sleeping?: boolean;
  meta?: Record<string, string> | null;
}

/// The id rush gives a host started on `sessionId`: its first eight hex
/// digits, dashes left out.
export function rushHostId(sessionId: string): string {
  return sessionId.replaceAll("-", "").slice(0, 8);
}

/// The card session name of the host started on `sessionId`.
export function rushSessionNameFor(sessionId: string): string {
  return `rush-${rushHostId(sessionId)}`;
}

/// A host that is running, or resting until its next message: either way the
/// agent is in place and must not be started again.
export function rushHostInPlace(host: RushHostInfo): boolean {
  return !!host.alive || (!!host.sleeping && host.state !== "stopped");
}

/// The question a blocked host waits on, if it waits on one.
export function rushPendingQuestion(host: RushHostInfo): string | undefined {
  if (host.state !== "blocked" || !host.needs) return undefined;
  const m = /^asks: (.*)$/s.exec(host.needs);
  return m ? m[1].trim() : undefined;
}

/// The environment rush runs with. RUSH_SESSION is left out: rush makes a
/// session started from another rush session's shell that session's
/// subagent, and an agent from agents.yaml is a session of its own.
function rushEnv(): NodeJS.ProcessEnv {
  const env = { ...process.env };
  delete env.RUSH_SESSION;
  return env;
}

function runRush(args: string[], input?: string): string {
  return execFileSync(findRush(), args, {
    encoding: "utf-8",
    env: rushEnv(),
    input,
    stdio: ["pipe", "pipe", "pipe"],
    timeout: 60_000,
  });
}

/// The JSON a rush command printed, also when it exited non-zero: with
/// --json rush prints `{"error": ...}` on failure.
function parseJsonOut<T>(fn: () => string): T {
  let out: string;
  try {
    out = fn();
  } catch (e: any) {
    const stdout = typeof e?.stdout === "string" ? e.stdout : e?.stdout?.toString?.() ?? "";
    const stderr = typeof e?.stderr === "string" ? e.stderr : e?.stderr?.toString?.() ?? "";
    let reason = stderr.trim() || String(e?.message ?? e);
    try {
      const parsed = JSON.parse(stdout.trim());
      if (parsed?.error) reason = parsed.error;
    } catch {
      // not JSON: the stderr says why
    }
    throw new Error(reason);
  }
  const parsed = JSON.parse(out.trim() || "null");
  if (parsed && typeof parsed === "object" && "error" in parsed && parsed.error) {
    throw new Error(String(parsed.error));
  }
  return parsed as T;
}

/// Every host whose metas match, running or not. Empty when rush is missing.
export function listRushHosts(meta: Record<string, string> = {}): RushHostInfo[] {
  const args = ["session", "list", "--json"];
  for (const [k, v] of Object.entries(meta)) args.push("--meta", `${k}=${v}`);
  try {
    return parseJsonOut<RushHostInfo[] | null>(() => runRush(args)) ?? [];
  } catch {
    return [];
  }
}

/// One host as `rush session info --json` prints it, or undefined when there
/// is none.
export function rushHostInfo(id: string): RushHostInfo | undefined {
  try {
    return parseJsonOut<RushHostInfo>(() => runRush(["session", "info", id, "--json"]));
  } catch {
    return undefined;
  }
}

/// The hosts started for an agent.
export function listAgentRushHosts(slug: string): RushHostInfo[] {
  return listRushHosts({ [RUSH_AGENT_META]: slug });
}

export interface RushStartOptions {
  cwd: string;
  sessionId: string;
  resume: boolean;
  name: string;
  model?: string;
  permissionMode?: string;
  binary?: string;
  env: Record<string, string>;
  meta: Record<string, string>;
}

/// The argv of `rush session start` for a Claude agent.
export function rushStartArgs(o: RushStartOptions): string[] {
  const args = ["session", "start", "--agent", "claude", "--cwd", o.cwd, "--session-id", o.sessionId];
  if (o.resume) args.push("--resume");
  args.push("--name", o.name);
  if (o.permissionMode) args.push("--permission-mode", o.permissionMode);
  if (o.model) args.push("--model", o.model);
  if (o.binary) args.push("--binary", o.binary);
  for (const [k, v] of Object.entries(o.env)) args.push("--env", `${k}=${v}`);
  for (const [k, v] of Object.entries(o.meta)) args.push("--meta", `${k}=${v}`);
  args.push("--json");
  return args;
}

/// Start (or bring back) a host and return it as rush reports it.
export function startRushHost(o: RushStartOptions): RushHostInfo {
  return parseJsonOut<RushHostInfo>(() => runRush(rushStartArgs(o)));
}

/// Stop a host. A host already stopped is fine.
export function stopRushHost(id: string): { ok: boolean; error?: string } {
  try {
    runRush(["session", "stop", id]);
    return { ok: true };
  } catch (e: any) {
    return { ok: false, error: String(e?.stderr || e?.message || e) };
  }
}

/// Answer the question a host waits on.
export function answerRushHost(id: string, text: string): { ok: boolean; error?: string } {
  try {
    runRush(["session", "answer", id], text);
    return { ok: true };
  } catch (e: any) {
    return { ok: false, error: String(e?.stderr || e?.message || e) };
  }
}
