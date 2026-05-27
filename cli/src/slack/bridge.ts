import { existsSync, statSync, openSync, readSync, closeSync } from "node:fs";
import { SocketModeClient } from "@slack/socket-mode";
import { SlackClient } from "./client.js";
import { routeSlackMessage, ChannelMapping } from "./inbound.js";
import { formatTranscriptLines } from "./format.js";
import { loadAgentsConfig } from "../agents/config.js";
import { agentIdentity } from "../agents/identity.js";
import { recordAnnounceSuppress } from "./announce-suppress.js";
import { findSessionJsonl, pasteTmuxPrompt } from "../data.js";

export interface BridgeOptions {
  botToken: string;
  appToken: string;
  configPath: string;
  /// Transcript poll interval (ms). Default 1500.
  pollMs?: number;
}

interface TailState {
  slug: string;
  sessionId: string;
  channelId: string;
  path?: string;
  offset: number;
}

function readAppendedLines(path: string, offset: number): { objs: any[]; newOffset: number } {
  const size = statSync(path).size;
  if (size <= offset) return { objs: [], newOffset: size };
  const fd = openSync(path, "r");
  const buf = Buffer.alloc(size - offset);
  readSync(fd, buf, 0, buf.length, offset);
  closeSync(fd);
  const text = buf.toString("utf-8");
  const lastNl = text.lastIndexOf("\n");
  if (lastNl < 0) return { objs: [], newOffset: offset };
  const consumed = offset + Buffer.byteLength(text.slice(0, lastNl + 1), "utf-8");
  const objs: any[] = [];
  for (const line of text.slice(0, lastNl).split("\n")) {
    if (!line.trim()) continue;
    try {
      objs.push(JSON.parse(line));
    } catch {
      /* skip malformed */
    }
  }
  return { objs, newOffset: consumed };
}

/// Run the bidirectional Slack bridge until the process exits.
///   agent -> slack: tail each agent's transcript and post new assistant turns.
///   slack -> agent: relay human channel messages into the agent's tmux session.
export async function runSlackBridge(opts: BridgeOptions): Promise<void> {
  const pollMs = opts.pollMs ?? 1500;
  const file = loadAgentsConfig(opts.configPath);
  const agents = file.agents.filter((a) => a.slackChannel);
  if (agents.length === 0) {
    console.error("No agents with a slackChannel configured; nothing to bridge.");
    return;
  }

  const client = new SlackClient(opts.botToken);
  const botUserId = await client.botUserId();

  const mapping: ChannelMapping = {};
  const tails: TailState[] = [];
  for (const a of agents) {
    const channelId = await client.resolveChannelId(a.slackChannel!);
    if (!channelId) {
      console.error(`Slack channel not found for ${a.slug}: ${a.slackChannel}`);
      continue;
    }
    mapping[channelId] = a.slug;
    const sessionId = agentIdentity(a.slug).sessionId;
    const path = findSessionJsonl(sessionId);
    // Start at EOF so we mirror only new activity, not the whole backlog.
    tails.push({ slug: a.slug, sessionId, channelId, path, offset: path ? statSync(path).size : 0 });
  }

  // agent -> slack
  setInterval(async () => {
    for (const t of tails) {
      if (!t.path) {
        t.path = findSessionJsonl(t.sessionId);
        if (t.path) t.offset = statSync(t.path).size; // skip backlog on first discovery
        continue;
      }
      if (!existsSync(t.path)) continue;
      const { objs, newOffset } = readAppendedLines(t.path, t.offset);
      t.offset = newOffset;
      for (const post of formatTranscriptLines(objs)) {
        try {
          await client.post(t.channelId, post.text);
        } catch (e) {
          console.error(`post to ${t.slug} failed:`, e);
        }
      }
    }
  }, pollMs);

  // slack -> agent
  const socket = new SocketModeClient({ appToken: opts.appToken });
  socket.on("message", async ({ event, ack }: any) => {
    if (ack) await ack();
    const decision = routeSlackMessage(event, mapping, botUserId);
    if (decision.action === "deliver") {
      // Mark this relay so the daemon does not echo it back to the channel
      // (it already appears there as that person's Slack message). Recorded
      // before the paste so the marker is in place before UserPromptSubmit.
      recordAnnounceSuppress(agentIdentity(decision.slug).sessionId);
      pasteTmuxPrompt(decision.slug, decision.text); // tmux session name == slug
    }
  });
  await socket.start();
  console.error(`Slack bridge connected. Mirroring ${tails.length} agent(s).`);
}
