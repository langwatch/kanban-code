import { existsSync, statSync, openSync, readSync, closeSync } from "node:fs";
import { join } from "node:path";
import { SocketModeClient } from "@slack/socket-mode";
import { SlackClient } from "./client.js";
import { routeSlackMessage, ChannelMapping } from "./inbound.js";
import { formatTranscriptLines, formatCodexRolloutLines } from "./format.js";
import { loadAgentsConfig } from "../agents/config.js";
import { agentIdentity } from "../agents/identity.js";
import { Runtime } from "../agents/runtime.js";
import { recordAnnounceSuppress } from "./announce-suppress.js";
import { writeThreadRoot, readThreadRoot } from "./thread-root.js";
import { findSessionJsonl, findCodexRollout, pasteTmuxPrompt } from "../data.js";

export interface BridgeOptions {
  botToken: string;
  appToken: string;
  configPath: string;
  /// Transcript poll interval (ms). Default 1500.
  pollMs?: number;
}

interface TailState {
  slug: string;
  runtime: Runtime;
  sessionId: string;
  /// For Codex, the per-agent workspace used to locate its rollout by cwd.
  cwd?: string;
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

  // Slack-human messages relayed into a Codex agent reappear in that agent's
  // rollout as user_message events, which the poll loop would otherwise echo
  // back to the channel as ">>> Received user message" (a duplicate of the
  // human's own message). Claude suppresses this via the daemon's announce-
  // suppress markers, but the Codex rollout mirror runs in this process, so we
  // track recent relays here and drop the matching echo. Keyed by slug.
  const recentRelays = new Map<string, { text: string; ts: number }[]>();
  const RELAY_ECHO_TTL_MS = 90_000;
  const consumeRelayEcho = (slug: string, mirrored: string): boolean => {
    const list = recentRelays.get(slug);
    if (!list?.length) return false;
    const now = Date.now();
    const i = list.findIndex((r) => now - r.ts <= RELAY_ECHO_TTL_MS && mirrored.includes(r.text.trim()));
    if (i < 0) return false;
    list.splice(i, 1); // consume so a genuine resend later is not swallowed
    return true;
  };
  for (const a of agents) {
    const channelId = await client.resolveChannelId(a.slackChannel!);
    if (!channelId) {
      console.error(`Slack channel not found for ${a.slug}: ${a.slackChannel}`);
      continue;
    }
    mapping[channelId] = a.slug;
    const runtime = (a.runtime ?? "claude") as Runtime;
    const sessionId = agentIdentity(a.slug, runtime).sessionId;
    const cwd = join(file.workspacesDir, a.slug);
    const path = runtime === "codex" ? findCodexRollout(cwd) : findSessionJsonl(sessionId);
    // Start at EOF so we mirror only new activity, not the whole backlog.
    tails.push({ slug: a.slug, runtime, sessionId, cwd, channelId, path, offset: path ? statSync(path).size : 0 });
  }

  // agent -> slack
  setInterval(async () => {
    for (const t of tails) {
      if (!t.path) {
        t.path = t.runtime === "codex" ? findCodexRollout(t.cwd!) : findSessionJsonl(t.sessionId);
        if (t.path) t.offset = statSync(t.path).size; // skip backlog on first discovery
        continue;
      }
      // Codex writes a fresh rollout file per session, so a restart (or its own
      // auto-compaction) rotates the file. Follow the newest one from its start
      // so a relaunched agent keeps mirroring without restarting the bridge.
      if (t.runtime === "codex") {
        const latest = findCodexRollout(t.cwd!);
        if (latest && latest !== t.path) {
          t.path = latest;
          t.offset = 0;
        }
      }
      if (!existsSync(t.path)) continue;
      const { objs, newOffset } = readAppendedLines(t.path, t.offset);
      t.offset = newOffset;
      const posts = t.runtime === "codex" ? formatCodexRolloutLines(objs) : formatTranscriptLines(objs);
      for (const post of posts) {
        // Don't echo a prompt we just relayed from a Slack human (it's already
        // in the channel as their message).
        if (t.runtime === "codex" && post.role === "user" && consumeRelayEcho(t.slug, post.text)) continue;
        try {
          if (post.role === "user") {
            // A received prompt opens a new thread; the agent's work for this
            // turn replies under it instead of cluttering the channel root.
            // (Claude's received prompt is posted by the daemon's announce,
            // which records the same root, so Claude threads too.)
            const ts = await client.post(t.channelId, post.text);
            if (ts) writeThreadRoot(t.slug, ts);
          } else {
            await client.post(t.channelId, post.text, readThreadRoot(t.slug));
          }
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
      // Also remember it for the in-process Codex rollout-echo guard above.
      const relays = recentRelays.get(decision.slug) ?? [];
      relays.push({ text: decision.text, ts: Date.now() });
      recentRelays.set(decision.slug, relays);
      pasteTmuxPrompt(decision.slug, decision.text); // tmux session name == slug
    }
  });
  await socket.start();
  console.error(`Slack bridge connected. Mirroring ${tails.length} agent(s).`);
}
