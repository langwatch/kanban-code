import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { parse as parseYaml } from "yaml";
import { isValidSlug } from "./identity.js";
import { Runtime, isRuntime } from "./runtime.js";

/// One long-lived agent, defined declaratively. Used by the reconciler (slug,
/// repos, model), the scheduler (schedule, dailyPrompt) and the Slack bridge
/// (slackChannel). Prompts live here so the whole agent is one config object.
/// Where an agent's process runs: a tmux session named after the slug, or a
/// rush host, which keeps several Claude accounts signed in and moves the
/// session to another one when the current account runs low.
export type AgentHost = "tmux" | "rush";

export function isAgentHost(v: unknown): v is AgentHost {
  return v === "tmux" || v === "rush";
}

export interface AgentConfig {
  slug: string;
  /// Which agent CLI drives this agent. Optional; defaults to "claude".
  runtime?: Runtime;
  /// Where the agent runs, resolved from the agent's own `host` or the file's.
  /// Rush hosts Claude only, so a Codex agent is always on tmux.
  host?: AgentHost;
  /// GitHub repos the agent works on, as "owner/name".
  repos: string[];
  /// Model alias or full name (claude --model). Optional.
  model?: string;
  /// Slack channel id or name this agent mirrors to / is steered from.
  slackChannel?: string;
  /// Daily nudge schedule. "HH:MM" (box-local) or a systemd OnCalendar string.
  schedule?: string;
  /// System/init context, sent once when the session is first created.
  initPrompt?: string;
  /// The prompt delivered by the daily scheduler.
  dailyPrompt?: string;
}

export interface AgentsFile {
  /// Where bare-ish main clones live. Default ~/agent-repos.
  reposDir: string;
  /// Where per-agent worktree workspaces live. Default ~/agent-workspaces.
  workspacesDir: string;
  /// Default host for every agent. Default tmux.
  host: AgentHost;
  agents: AgentConfig[];
  /// Settings that were accepted but ignored, for the operator to see.
  warnings: string[];
}

function expandHome(p: string): string {
  return p.startsWith("~/") ? join(homedir(), p.slice(2)) : p;
}

const REPO_RE = /^[\w.-]+\/[\w.-]+$/;

/// Parse and validate an agents config. Throws on malformed input so a bad
/// config fails the reconcile loudly rather than silently provisioning nothing.
export function parseAgentsConfig(text: string): AgentsFile {
  const raw = parseYaml(text) ?? {};
  const agentsRaw = Array.isArray(raw.agents) ? raw.agents : [];
  const defaultHost = raw.host ?? "tmux";
  if (!isAgentHost(defaultHost)) {
    throw new Error(`host invalid: ${JSON.stringify(raw.host)} (expected "tmux" or "rush")`);
  }
  const warnings: string[] = [];

  const seen = new Set<string>();
  const agents: AgentConfig[] = agentsRaw.map((a: any, i: number) => {
    if (!a || typeof a !== "object") throw new Error(`agents[${i}] is not an object`);
    if (!isValidSlug(a.slug)) throw new Error(`agents[${i}].slug invalid: ${JSON.stringify(a.slug)}`);
    if (seen.has(a.slug)) throw new Error(`duplicate agent slug: ${a.slug}`);
    seen.add(a.slug);
    const runtime = a.runtime ?? "claude";
    if (!isRuntime(runtime)) {
      throw new Error(`agents[${i}] (${a.slug}) has invalid runtime ${JSON.stringify(a.runtime)} (expected "claude" or "codex")`);
    }
    if (a.host !== undefined && !isAgentHost(a.host)) {
      throw new Error(`agents[${i}] (${a.slug}) has invalid host ${JSON.stringify(a.host)} (expected "tmux" or "rush")`);
    }
    let host: AgentHost = a.host ?? defaultHost;
    if (host === "rush" && runtime !== "claude") {
      if (a.host === "rush") warnings.push(`${a.slug}: host rush runs Claude only, so this ${runtime} agent stays on tmux`);
      host = "tmux";
    }
    const repos = Array.isArray(a.repos) ? a.repos : [];
    for (const r of repos) {
      if (typeof r !== "string" || !REPO_RE.test(r)) {
        throw new Error(`agents[${i}] (${a.slug}) has invalid repo ${JSON.stringify(r)} (expected "owner/name")`);
      }
    }
    return {
      slug: a.slug,
      runtime,
      host,
      repos,
      model: a.model,
      slackChannel: a.slackChannel,
      schedule: a.schedule,
      initPrompt: a.initPrompt,
      dailyPrompt: a.dailyPrompt,
    };
  });

  return {
    reposDir: expandHome(raw.reposDir || "~/agent-repos"),
    workspacesDir: expandHome(raw.workspacesDir || "~/agent-workspaces"),
    host: defaultHost,
    agents,
    warnings,
  };
}

export function loadAgentsConfig(path: string): AgentsFile {
  const file = parseAgentsConfig(readFileSync(path, "utf-8"));
  for (const w of file.warnings) process.stderr.write(`warning: ${w}\n`);
  return file;
}
