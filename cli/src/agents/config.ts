import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { parse as parseYaml } from "yaml";
import { isValidSlug } from "./identity.js";

/// One long-lived agent, defined declaratively. Used by the reconciler (slug,
/// repos, model), the scheduler (schedule, dailyPrompt) and the Slack bridge
/// (slackChannel). Prompts live here so the whole agent is one config object.
export interface AgentConfig {
  slug: string;
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
  agents: AgentConfig[];
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

  const seen = new Set<string>();
  const agents: AgentConfig[] = agentsRaw.map((a: any, i: number) => {
    if (!a || typeof a !== "object") throw new Error(`agents[${i}] is not an object`);
    if (!isValidSlug(a.slug)) throw new Error(`agents[${i}].slug invalid: ${JSON.stringify(a.slug)}`);
    if (seen.has(a.slug)) throw new Error(`duplicate agent slug: ${a.slug}`);
    seen.add(a.slug);
    const repos = Array.isArray(a.repos) ? a.repos : [];
    for (const r of repos) {
      if (typeof r !== "string" || !REPO_RE.test(r)) {
        throw new Error(`agents[${i}] (${a.slug}) has invalid repo ${JSON.stringify(r)} (expected "owner/name")`);
      }
    }
    return {
      slug: a.slug,
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
    agents,
  };
}

export function loadAgentsConfig(path: string): AgentsFile {
  return parseAgentsConfig(readFileSync(path, "utf-8"));
}
