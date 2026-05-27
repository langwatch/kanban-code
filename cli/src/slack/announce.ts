import { SlackClient } from "./client.js";
import { loadAgentsConfig } from "../agents/config.js";
import { join } from "node:path";
import { homedir } from "node:os";

/// Posts "automated" agent traffic (scheduled nudges, auto-compact notes,
/// auto-sent queued prompts) to an agent's Slack channel. Human messages
/// relayed *from* Slack must NOT go through here (they already appear in Slack).

/// Marker prepended to every announced message. Because only automated,
/// system-originated traffic flows through this module (never messages typed by
/// a human in Slack), the marker lets anyone reading the channel tell a
/// system-injected prompt (cron nudge, self-compact, auto-sent queued prompt)
/// apart from the agent's own replies.
export const SYSTEM_MESSAGE_PREFIX = "[SYSTEM MESSAGE]";

/// Prepend the system marker to an automated announcement.
export function formatSystemAnnouncement(text: string): string {
  return `${SYSTEM_MESSAGE_PREFIX}\n${text}`;
}

function defaultConfigPath(): string {
  return process.env.KANBAN_AGENTS_CONFIG || join(homedir(), ".kanban-code", "agents.yaml");
}

// slug -> resolved channel id, cached per process.
const channelCache = new Map<string, string | null>();
let cachedClient: SlackClient | undefined;

function client(token?: string): SlackClient | undefined {
  const t = token || process.env.SLACK_BOT_TOKEN;
  if (!t) return undefined;
  if (!cachedClient) cachedClient = new SlackClient(t);
  return cachedClient;
}

async function channelForSlug(slug: string, configPath: string, c: SlackClient): Promise<string | undefined> {
  if (channelCache.has(slug)) return channelCache.get(slug) ?? undefined;
  let id: string | undefined;
  try {
    const file = loadAgentsConfig(configPath);
    const agent = file.agents.find((a) => a.slug === slug);
    if (agent?.slackChannel) id = await c.resolveChannelId(agent.slackChannel);
  } catch {
    /* no config / unresolvable */
  }
  channelCache.set(slug, id ?? null);
  return id;
}

export interface AnnounceOptions {
  token?: string;
  configPath?: string;
}

/// Announce text to an agent's channel. No-op (returns false) if no token is
/// configured or the agent has no resolvable channel.
export async function announceToSlack(slug: string, text: string, opts: AnnounceOptions = {}): Promise<boolean> {
  const c = client(opts.token);
  if (!c) return false;
  const channel = await channelForSlug(slug, opts.configPath ?? defaultConfigPath(), c);
  if (!channel) return false;
  try {
    await c.post(channel, formatSystemAnnouncement(text));
    return true;
  } catch {
    return false;
  }
}
