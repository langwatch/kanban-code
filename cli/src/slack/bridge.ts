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
import { downloadSlackFile, formatPromptWithAttachments, DownloadedFile, sweepInbox, DEFAULT_RETENTION_DAYS } from "./inbox.js";
import { parsePicker, Picker } from "./picker.js";
import { findSessionJsonl, findCodexRollout, pasteTmuxPrompt, captureTmuxPane, sendTmuxKey } from "../data.js";

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

/// Per-claude-agent picker state. Tracks the hash of the most recently posted
/// picker so the poller does not repost the same picker every tick, and the
/// Slack message ts so a button click can update the message in place to show
/// which option was chosen.
interface PickerState {
  hash: string;
  options: { number: number; title: string }[];
  messageTs: string;
  channelId: string;
}

/// Build the Block Kit payload for a picker. Numbered buttons map 1:1 to the
/// agent's picker; the action_id encodes (slug, hash, number) so the click
/// handler can route safely even if a stale message is clicked.
function pickerBlocks(slug: string, picker: Picker): { text: string; blocks: any[] } {
  const fallback = picker.question || "Claude is asking you to pick an option.";
  const bullets = picker.options
    .map((o) => {
      const head = `*${o.number}.* ${o.title}`;
      return o.description ? `${head}\n_${o.description}_` : head;
    })
    .join("\n\n");
  const header = picker.question ? `*${picker.question}*\n\n${bullets}` : bullets;
  return {
    text: fallback,
    blocks: [
      { type: "section", text: { type: "mrkdwn", text: header } },
      {
        type: "actions",
        elements: picker.options.map((o) => ({
          type: "button",
          text: { type: "plain_text", text: String(o.number) },
          value: String(o.number),
          action_id: `picker:${slug}:${picker.hash}:${o.number}`,
        })),
      },
    ],
  };
}

function pickerSelectedBlocks(picker: Picker, choice: number, by: string): { text: string; blocks: any[] } {
  const chosen = picker.options.find((o) => o.number === choice);
  const label = chosen ? `${choice}. ${chosen.title}` : String(choice);
  const text = `${picker.question || "Selected"} — picked: *${label}* by <@${by}>`;
  return { text, blocks: [{ type: "section", text: { type: "mrkdwn", text } }] };
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

  // Per-agent active "working…" pill. Set on each tool/thinking post, cleared
  // implicitly by Slack the moment we post a text reply in the thread (and by
  // Slack's own 2-minute idle TTL when the agent stalls or crashes). We refresh
  // every REFRESH_MS while a turn is open so the TTL does not drop the pill
  // mid-turn during long bash bursts or large diffs.
  const REFRESH_MS = 60_000;
  interface ActivePill { channelId: string; threadTs: string; label: string; lastSetMs: number; }
  const active = new Map<string /* slug */, ActivePill>();

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
          // Text posts (user prompts AND assistant text) sit at the channel
          // root and become the new thread anchor; tool/thinking blocks reply
          // under that anchor. This keeps the channel readable as a single
          // back-and-forth while the tool noise lives in the threads.
          // (Claude's received-prompt path goes through the daemon's announce,
          // which writes the same thread-root file the bridge reads here.)
          if (post.kind === "text") {
            const ts = await client.post(t.channelId, post.text);
            if (ts) writeThreadRoot(t.slug, ts);
            // A text reply auto-clears the "working…" pill in Slack — drop
            // our refresh state so we do not redundantly keep it alive after
            // the turn settled.
            active.delete(t.slug);
            // For a user prompt (codex user_message lands here), light an
            // immediate "💭 thinking…" pill so the channel reflects that the
            // agent has started work before its first tool call shows up.
            // Assistant text posts wrap up a turn, so they do not get a pill.
            if (post.role === "user" && ts) {
              const label = "💭 thinking…";
              try {
                await client.setStatus(t.channelId, ts, label);
                active.set(t.slug, { channelId: t.channelId, threadTs: ts, label, lastSetMs: Date.now() });
              } catch (e) {
                console.error(`setStatus (prompt) for ${t.slug} failed:`, e);
              }
            }
          } else {
            const threadTs = readThreadRoot(t.slug);
            await client.post(t.channelId, post.text, threadTs);
            // Light the pill (or refresh it with the latest tool's label) so
            // the channel shows the agent is still working between text
            // posts. If we have no thread root yet (no announce or codex
            // user_message landed), skip — there is nowhere to anchor it.
            if (threadTs && post.statusLabel) {
              try {
                await client.setStatus(t.channelId, threadTs, post.statusLabel);
                active.set(t.slug, {
                  channelId: t.channelId,
                  threadTs,
                  label: post.statusLabel,
                  lastSetMs: Date.now(),
                });
              } catch (e) {
                console.error(`setStatus for ${t.slug} failed:`, e);
              }
            }
          }
        } catch (e) {
          console.error(`post to ${t.slug} failed:`, e);
        }
      }
    }
  }, pollMs);

  // Refresh "working…" pills that Slack would otherwise drop after its
  // built-in 2-minute idle TTL. We re-set every REFRESH_MS so an agent grinding
  // through a long bash sequence keeps the channel visibly active.
  setInterval(async () => {
    const now = Date.now();
    for (const [slug, pill] of active) {
      if (now - pill.lastSetMs < REFRESH_MS) continue;
      try {
        await client.setStatus(pill.channelId, pill.threadTs, pill.label);
        pill.lastSetMs = now;
      } catch (e) {
        console.error(`setStatus refresh for ${slug} failed:`, e);
      }
    }
  }, Math.floor(REFRESH_MS / 2));

  // Picker poller (Claude runtime only). Claude Code renders interactive
  // numbered pickers in the terminal that never appear in the transcript;
  // we capture the pane every second, detect the picker, and post one Slack
  // Block Kit message with N buttons. A click round-trips back via the
  // interactivity socket as a tmux send-keys of the chosen digit (no Enter
  // — Claude Code commits on the bare digit). Codex agents are skipped to
  // avoid send-keys-ing into a session that does not have this UI.
  const pickerByAgent = new Map<string, PickerState>();
  const PICKER_POLL_MS = 1000;
  const claudeAgents = tails.filter((t) => t.runtime === "claude");
  if (claudeAgents.length) {
    setInterval(async () => {
      for (const t of claudeAgents) {
        const pane = captureTmuxPane(t.slug);
        if (!pane) continue;
        const picker = parsePicker(pane);
        const prev = pickerByAgent.get(t.slug);
        if (!picker) {
          // Picker dismissed (agent moved on). Drop our state so the next
          // picker — even one with the same hash recycled — gets reposted.
          if (prev) pickerByAgent.delete(t.slug);
          continue;
        }
        if (prev && prev.hash === picker.hash) continue; // already posted
        const { text, blocks } = pickerBlocks(t.slug, picker);
        // Pickers go to the channel root, not into the current thread: they
        // are the agent blocking on YOU, so they need to be where the channel
        // shows them at a glance. Also becomes the new thread anchor so
        // subsequent tool calls thread under it cleanly.
        try {
          const ts = await client.postBlocks(t.channelId, text, blocks);
          if (ts) {
            writeThreadRoot(t.slug, ts);
            active.delete(t.slug); // clear stale "working…" pill state
            pickerByAgent.set(t.slug, {
              hash: picker.hash,
              options: picker.options.map((o) => ({ number: o.number, title: o.title })),
              messageTs: ts,
              channelId: t.channelId,
            });
          }
        } catch (e) {
          console.error(`picker post for ${t.slug} failed:`, e);
        }
      }
    }, PICKER_POLL_MS);
  }

  // slack -> agent
  const socket = new SocketModeClient({ appToken: opts.appToken });
  // Block Kit button clicks land here over the same socket connection. The
  // action_id is `picker:<slug>:<hash>:<N>` — we look up the active picker
  // for that slug, send the digit to its tmux session, and update the Slack
  // message in place so the channel shows what was picked and by whom.
  socket.on("interactive", async ({ body, ack }: any) => {
    if (ack) await ack();
    const actions = body?.actions ?? [];
    for (const a of actions) {
      const id: string = a.action_id ?? "";
      if (!id.startsWith("picker:")) continue;
      const [, slug, hash, numStr] = id.split(":");
      const chosen = parseInt(numStr, 10);
      const state = pickerByAgent.get(slug);
      if (!state || state.hash !== hash) {
        console.error(`picker click for ${slug}#${hash} but state is stale; ignoring`);
        continue;
      }
      const known = state.options.find((o) => o.number === chosen);
      if (!known) {
        console.error(`picker click for ${slug} chose ${chosen} but options are ${state.options.map((o) => o.number).join(",")}`);
        continue;
      }
      const res = sendTmuxKey(slug, String(chosen));
      if (!res.ok) {
        console.error(`send-key ${chosen} -> ${slug} failed:`, res.error);
        continue;
      }
      // Reconstruct enough of the picker to render the "selected" message;
      // descriptions are not needed for the resolved view.
      const fauxPicker: Picker = {
        question: body?.message?.text ?? "",
        options: state.options.map((o) => ({ number: o.number, title: o.title })),
        hash: state.hash,
      };
      const who = body?.user?.id ?? "user";
      const { text, blocks } = pickerSelectedBlocks(fauxPicker, chosen, who);
      try {
        await client.update(state.channelId, state.messageTs, text, blocks);
      } catch (e) {
        console.error(`picker message update for ${slug} failed:`, e);
      }
      // Drop the state so the next picker (with potentially recycled numbers)
      // posts fresh on the next poll tick.
      pickerByAgent.delete(slug);
    }
  });

  socket.on("message", async ({ event, ack }: any) => {
    if (ack) await ack();
    const decision = routeSlackMessage(event, mapping, botUserId);
    if (decision.action !== "deliver") return;

    // Slack file attachments: download each into the per-agent inbox and
    // inline the local paths into the prompt. The agent reads them with its
    // own tools (Read handles images natively; PDFs/zips work file-by-file).
    // Per-file errors are reported but never block the text delivery.
    const downloaded: DownloadedFile[] = [];
    for (const f of decision.files) {
      try {
        downloaded.push(await downloadSlackFile(f, { botToken: opts.botToken, slug: decision.slug }));
      } catch (e) {
        console.error(`download for ${decision.slug} (${f.name ?? f.id}) failed:`, e);
      }
    }
    const prompt = formatPromptWithAttachments(decision.text, downloaded);
    if (!prompt) return; // text empty AND every attachment failed -> nothing to relay

    // Mark this relay so the daemon does not echo it back to the channel
    // (it already appears there as that person's Slack message). Recorded
    // before the paste so the marker is in place before UserPromptSubmit.
    recordAnnounceSuppress(agentIdentity(decision.slug).sessionId);
    // Also remember it for the in-process Codex rollout-echo guard above.
    const relays = recentRelays.get(decision.slug) ?? [];
    relays.push({ text: prompt, ts: Date.now() });
    recentRelays.set(decision.slug, relays);
    pasteTmuxPrompt(decision.slug, prompt); // tmux session name == slug
  });
  await socket.start();
  console.error(`Slack bridge connected. Mirroring ${tails.length} agent(s).`);

  // Drop attachments older than the retention window so the inbox does not
  // grow without bound. We sweep on startup and then every hour. Override the
  // window with SLACK_INBOX_RETENTION_DAYS=0 to disable, or any positive
  // integer to override the default.
  const retentionDays = Number.parseInt(process.env.SLACK_INBOX_RETENTION_DAYS ?? "", 10);
  const sweepOpts = Number.isFinite(retentionDays)
    ? { retentionDays }
    : { retentionDays: DEFAULT_RETENTION_DAYS };
  const runSweep = () => {
    try {
      const { removedFiles, removedDirs } = sweepInbox(sweepOpts);
      if (removedFiles || removedDirs) {
        console.error(`inbox sweep: removed ${removedFiles} file(s), ${removedDirs} empty dir(s)`);
      }
    } catch (e) {
      console.error("inbox sweep failed:", e);
    }
  };
  runSweep();
  setInterval(runSweep, 60 * 60 * 1000);
}
