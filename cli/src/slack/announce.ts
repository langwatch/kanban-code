import { SlackClient } from "./client.js";
import { loadAgentsConfig } from "../agents/config.js";
import { join } from "node:path";
import { homedir } from "node:os";

/// Mirrors every prompt injected into an agent (scheduled nudges, self-compact,
/// auto-sent queued prompts, and any `kanban send` someone runs by hand) to the
/// agent's Slack channel. Messages relayed *from* a Slack human must NOT go
/// through here, they already appear in Slack as that person's message.

/// Header shown above each mirrored prompt. It marks the text as the input the
/// agent received (not the agent's own reply), so a reader can tell the two
/// apart in the channel.
export const RECEIVED_MESSAGE_HEADER = ">>> Received user message";

/// Format an injected prompt for the channel: the header, then the body in
/// italics (Slack mrkdwn uses _underscores_ for italic; * and ** do not work).
export function formatReceivedMessage(text: string): string {
  return `${RECEIVED_MESSAGE_HEADER}\n\n_${text}_`;
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
    await c.post(channel, formatReceivedMessage(text));
    return true;
  } catch {
    return false;
  }
}
