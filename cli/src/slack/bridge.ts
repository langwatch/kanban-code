import { existsSync, statSync, openSync, readSync, closeSync } from "node:fs";
import { join } from "node:path";
import { SocketModeClient } from "@slack/socket-mode";
import { SlackClient, SlackChannelInfo } from "./client.js";
import { matchPendingChannels, PendingAgent } from "./reresolve.js";
import { routeSlackMessage, prefixAuthor, ChannelMapping } from "./inbound.js";
import { formatTranscriptLines, formatCodexRolloutLines, TERMINAL_STOP_REASONS } from "./format.js";
import { loadAgentsConfig } from "../agents/config.js";
import { agentIdentity } from "../agents/identity.js";
import { Runtime } from "../agents/runtime.js";
import { recordAnnounceSuppress } from "./announce-suppress.js";
import { WORKING_PILL_LABEL } from "./announce.js";
import { writeThreadRoot, readThreadRoot } from "./thread-root.js";
import { writeActivePill, readActivePill, clearActivePill } from "./active-pill.js";
import { writeEyesAnchor, readEyesAnchor, clearEyesAnchor, PersistedEyesAnchor } from "./eyes-anchor.js";
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

/// Read up to the last `tailBytes` of a jsonl file and return the parsed
/// objects in order. Used by the restore-time turn-end check to inspect the
/// most recent agent activity without loading the whole transcript (Claude
/// transcripts grow to hundreds of MB). Returns [] on any read error so the
/// caller can fall back to "assume turn is still live".
function readTailObjs(path: string, tailBytes = 64 * 1024): any[] {
  try {
    const size = statSync(path).size;
    const readFrom = Math.max(0, size - tailBytes);
    const fd = openSync(path, "r");
    const buf = Buffer.alloc(size - readFrom);
    readSync(fd, buf, 0, buf.length, readFrom);
    closeSync(fd);
    const text = buf.toString("utf-8");
    // Drop the partial first line when we did not start from byte 0 — it is
    // almost certainly cut mid-JSON and parsing it would just throw.
    const sliceFrom = readFrom > 0 ? text.indexOf("\n") + 1 : 0;
    const objs: any[] = [];
    for (const line of text.slice(sliceFrom).split("\n")) {
      if (!line.trim()) continue;
      try {
        objs.push(JSON.parse(line));
      } catch {
        /* skip malformed */
      }
    }
    return objs;
  } catch {
    return [];
  }
}

/// True when the agent's most recent Claude assistant turn carries a
/// terminal stop_reason (end_turn / stop_sequence / refusal). Used at bridge
/// startup to detect that the live pill state on disk no longer reflects
/// active work — the bridge crashed/restarted AFTER the agent finished a
/// turn, the offset jumped past the end_turn marker, and the normal post
/// loop would never see it again so the refresh loop would re-light the
/// pill forever.
export function claudeTranscriptTurnEnded(path: string): boolean {
  const objs = readTailObjs(path);
  for (let i = objs.length - 1; i >= 0; i--) {
    const o = objs[i];
    if (o?.type !== "assistant") continue;
    const sr = o?.message?.stop_reason;
    return typeof sr === "string" && TERMINAL_STOP_REASONS.has(sr);
  }
  return false;
}

/// True when the agent's most recent Codex turn has a `task_complete` event
/// AFTER any subsequent `user_message`. Mirror of the Claude check above for
/// the codex-runtime side.
export function codexRolloutTurnEnded(path: string): boolean {
  const objs = readTailObjs(path);
  let lastUserAt = -1;
  let lastTaskCompleteAt = -1;
  for (let i = 0; i < objs.length; i++) {
    const p = objs[i]?.type === "event_msg" ? objs[i].payload : undefined;
    if (!p) continue;
    if (p.type === "user_message") lastUserAt = i;
    else if (p.type === "task_complete") lastTaskCompleteAt = i;
  }
  return lastTaskCompleteAt >= 0 && lastTaskCompleteAt > lastUserAt;
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
  // Resolve a Slack user id to a display name once and reuse it, so the agent
  // sees who is steering it on every inbound message without an API call per
  // message. A failed lookup is not cached, so a transient error can recover.
  const userNameCache = new Map<string, string>();
  const resolveUserNameCached = async (userId: string): Promise<string | undefined> => {
    const hit = userNameCache.get(userId);
    if (hit) return hit;
    const name = await client.resolveUserName(userId);
    if (name) userNameCache.set(userId, name);
    return name;
  };
  const consumeRelayEcho = (slug: string, mirrored: string): boolean => {
    const list = recentRelays.get(slug);
    if (!list?.length) return false;
    const now = Date.now();
    const i = list.findIndex((r) => now - r.ts <= RELAY_ECHO_TTL_MS && mirrored.includes(r.text.trim()));
    if (i < 0) return false;
    list.splice(i, 1); // consume so a genuine resend later is not swallowed
    return true;
  };
  // Build a tail + channel→agent mapping for one agent whose channel is known
  // and joinable. Used for agents resolved at startup AND, later, for agents
  // whose channel only becomes usable after the bridge started (the pending
  // re-resolution loop below). Appends live to `tails`/`mapping`, which the poll
  // loop and inbound router read by reference, so a late add needs no restart.
  const agentBySlug = new Map(agents.map((a) => [a.slug, a] as const));
  const buildTail = (a: (typeof agents)[number], channelId: string): void => {
    if (tails.some((t) => t.slug === a.slug)) return; // promote-once: never double-tail
    mapping[channelId] = a.slug;
    const runtime = (a.runtime ?? "claude") as Runtime;
    const sessionId = agentIdentity(a.slug, runtime).sessionId;
    const cwd = join(file.workspacesDir, a.slug);
    const path = runtime === "codex" ? findCodexRollout(cwd) : findSessionJsonl(sessionId);
    // Start at EOF so we mirror only new activity, not the whole backlog.
    tails.push({ slug: a.slug, runtime, sessionId, cwd, channelId, path, offset: path ? statSync(path).size : 0 });
  };

  // Resolve every agent against ONE conversations.list snapshot, gating on bot
  // MEMBERSHIP: a public channel is listed the moment it exists — before the bot
  // is invited — so mirroring on mere presence would post into a channel the bot
  // can't write to and gets no events from (a silent agent — exactly #677).
  // Agents that don't resolve (channel absent, or bot not a member yet) go to
  // `pending` and are retried by the loop below, so a channel created/invited
  // AFTER this restart is picked up with no manual restart.
  let pending: PendingAgent[] = agents.map((a) => ({ slug: a.slug, channel: a.slackChannel! }));
  {
    const snapshot = await client.listChannels();
    const { resolved, stillPending } = matchPendingChannels(pending, snapshot);
    pending = stillPending;
    for (const r of resolved) buildTail(agentBySlug.get(r.slug)!, r.channelId);
  }

  // Per-agent active "working…" pill. Set on each tool/thinking post, cleared
  // implicitly by Slack the moment we post a text reply in the thread (and by
  // Slack's own 2-minute idle TTL when the agent stalls or crashes). We refresh
  // every REFRESH_MS while a turn is open so the TTL does not drop the pill
  // mid-turn during long bash bursts or large diffs.
  const REFRESH_MS = 60_000;
  /// Alias for the shared pill label (kept local for readability in the
  /// dense post loop below). Defined in announce.ts so the bridge and the
  /// kanban CLI's announce path can't drift on what text the pill carries.
  const WORKING_LABEL = WORKING_PILL_LABEL;
  interface ActivePill { channelId: string; threadTs: string; label: string; lastSetMs: number; }
  const active = new Map<string /* slug */, ActivePill>();

  /// Restore pills from disk on startup so a bridge restart (config-sync
  /// triggers one on every bundle apply, sometimes several per hour while
  /// we iterate) doesn't drop the pill until the agent's next text post.
  /// We only restore pills that were set recently — `MAX_RESTORE_AGE_MS`
  /// older and the agent has likely already finished its turn, Slack's
  /// own idle TTL would have cleared the visual pill, and re-lighting
  /// would falsely advertise active work.
  const MAX_RESTORE_AGE_MS = 10 * 60_000;
  for (const a of agents) {
    const pill = readActivePill(a.slug);
    if (!pill) continue;
    if (Date.now() - pill.lastSetMs > MAX_RESTORE_AGE_MS) {
      clearActivePill(a.slug);
      continue;
    }
    // Cross-restart turn-end check. The MAX_RESTORE_AGE_MS guard above is
    // defeated by the refresh loop bumping lastSetMs every minute — even an
    // hours-old idle turn looks "recent" on restore. Tail-scan the agent's
    // transcript / rollout: if the most recent assistant turn already ended
    // (Claude terminal stop_reason or codex task_complete after the last
    // user_message), drop the pill instead of re-lighting it. Without this
    // the channel keeps showing "is working…" for as long as the bridge runs
    // even though Claude's stop_reason landed before this process started.
    const tail = tails.find((t) => t.slug === a.slug);
    const turnEnded =
      tail?.path
        ? tail.runtime === "codex"
          ? codexRolloutTurnEnded(tail.path)
          : claudeTranscriptTurnEnded(tail.path)
        : false;
    if (turnEnded) {
      try {
        await client.setStatus(pill.channelId, pill.threadTs, "");
      } catch (e) {
        console.error(`clear stale pill on restore for ${a.slug} failed:`, e);
      }
      clearActivePill(a.slug);
      // If the pill was anchored on a 👀 ack and the agent's turn already
      // ended without ever posting text (rare: hooks failed, agent crashed,
      // or codex turn produced only tool calls), the ack would orphan in
      // the channel. Delete it too so the restart leaves the channel clean.
      await consumePendingEyes(a.slug);
      continue;
    }
    active.set(a.slug, pill);
    // Re-light immediately rather than waiting for the next refresh tick,
    // so the channel shows "is working…" within seconds of bridge start
    // (the gap that prompted this whole change). Best-effort; the
    // refresh loop will retry every cycle anyway.
    try {
      await client.setStatus(pill.channelId, pill.threadTs, pill.label);
    } catch (e) {
      console.error(`setStatus restore for ${a.slug} failed:`, e);
    }
  }

  function setActivePill(slug: string, pill: ActivePill): void {
    active.set(slug, pill);
    writeActivePill(slug, pill);
  }
  function dropActivePill(slug: string): void {
    active.delete(slug);
    clearActivePill(slug);
  }

  /// 👀 ack messages we posted on Slack-relayed prompts, awaiting deletion
  /// once the agent posts its first real reply. Persisted to disk via
  /// eyes-anchor so a bridge restart still gets to finish the cleanup.
  const pendingEyes = new Map<string /* slug */, PersistedEyesAnchor>();
  for (const a of agents) {
    const anchor = readEyesAnchor(a.slug);
    if (anchor) pendingEyes.set(a.slug, anchor);
  }
  function setPendingEyes(slug: string, anchor: PersistedEyesAnchor): void {
    pendingEyes.set(slug, anchor);
    writeEyesAnchor(slug, anchor);
  }
  async function consumePendingEyes(slug: string): Promise<void> {
    const anchor = pendingEyes.get(slug);
    if (!anchor) return;
    pendingEyes.delete(slug);
    clearEyesAnchor(slug);
    try {
      await client.deleteMessage(anchor.channelId, anchor.ts);
    } catch (e) {
      console.error(`delete eyes anchor for ${slug} failed:`, e);
    }
  }

  // Per-agent buffer of tool/thinking posts that have NOT yet been sent. We
  // hold them until the next text post arrives (or a picker pops), then drain
  // them all into the previous text's thread as a single message. This keeps
  // the channel root showing only the agent's narrative (each text becomes a
  // top-level post) while the tool noise collapses behind a "1 reply" link.
  // The pill therefore always rides the latest channel-root text.
  const buffered = new Map<string /* slug */, string[] /* text bodies */>();
  const drainBuffer = async (slug: string, channelId: string): Promise<void> => {
    const buf = buffered.get(slug);
    if (!buf?.length) return;
    buffered.delete(slug);
    const anchor = readThreadRoot(slug);
    if (!anchor) return; // no prior text to thread under; drop (rare, bridge boot)
    // Single Slack post per drain — concatenating with a blank line is enough
    // for the dozens-of-bash-calls case. Slack's per-message text cap is 40k
    // which is plenty for the typical batch; on overflow Slack drops the
    // excess and we get a `text too long` error which the catch logs.
    const text = buf.join("\n");
    try {
      await client.post(channelId, text, anchor);
    } catch (e) {
      console.error(`drain buffer for ${slug} failed:`, e);
    }
  };

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
      // Cross-batch turn-end safety net. The same-batch case is handled by
      // format.ts marking the final agent_message terminal, but if the rollout
      // tail picks up the agent_message in one poll and the task_complete in
      // the next (rare, but possible if the rollout fsync straddles a poll),
      // the bridge would have already attached a fresh pill to the assistant
      // text and the refresh loop would keep it lit forever. Detect a bare
      // task_complete and clear the active pill without posting anything.
      const codexTurnEnded =
        t.runtime === "codex" &&
        objs.some(
          (o: any) => o?.type === "event_msg" && o?.payload?.type === "task_complete"
        );
      for (const post of posts) {
        // Don't echo a prompt we just relayed from a Slack human (it's already
        // in the channel as their message).
        if (t.runtime === "codex" && post.role === "user" && consumeRelayEcho(t.slug, post.text)) continue;
        try {
          if (post.kind === "text") {
            // A text post (user prompt OR assistant narrative) is the natural
            // beat: first drain the tools that piled up under the PREVIOUS
            // text into its thread, then post this text as the new channel-
            // root anchor and move the "working…" pill onto it. Delete the
            // 👀 ack message (if any) BEFORE posting so the new reply lands
            // next to the human's message instead of below an ack we're
            // about to remove.
            await consumePendingEyes(t.slug);
            await drainBuffer(t.slug, t.channelId);
            // Explicitly clear the pill on the previous anchor. Draining the
            // buffer above auto-clears it (Slack drops the pill when the bot
            // posts in the same thread), but back-to-back narrative texts
            // produce no thread reply between them — without this, the
            // previous pill would sit visible for ~2 minutes until Slack's
            // own idle TTL.
            const prevPill = active.get(t.slug);
            if (prevPill) {
              try {
                await client.setStatus(prevPill.channelId, prevPill.threadTs, "");
              } catch (e) {
                console.error(`clear previous pill for ${t.slug} failed:`, e);
              }
            }
            const ts = await client.post(t.channelId, post.text);
            if (ts) writeThreadRoot(t.slug, ts);
            dropActivePill(t.slug);
            // `terminal: true` posts are the final word of the turn — no more
            // work coming. Skip the WORKING pill entirely so the channel
            // doesn't show a perpetual "is working…" against a state that's
            // already finished. Codex sets this on its final agent_message
            // when task_complete lands in the same poll batch, and on the
            // out-of-credits sentinel. The previous anchor's pill was already
            // cleared above.
            if (ts && !post.terminal) {
              try {
                await client.setStatus(t.channelId, ts, WORKING_LABEL);
                setActivePill(t.slug, { channelId: t.channelId, threadTs: ts, label: WORKING_LABEL, lastSetMs: Date.now() });
              } catch (e) {
                console.error(`setStatus (text) for ${t.slug} failed:`, e);
              }
            }
          } else {
            // Tool / thinking blocks are buffered and only sent on the next
            // text post. The pill keeps refreshing on the current anchor
            // without us touching it — that's the existing refresh loop.
            const buf = buffered.get(t.slug) ?? [];
            buf.push(post.text);
            buffered.set(t.slug, buf);
          }
        } catch (e) {
          console.error(`post to ${t.slug} failed:`, e);
        }
      }
      // After the per-post loop: if this codex batch carried a task_complete
      // but none of the posts above were terminal text (i.e. the agent_message
      // landed in a prior batch and got its pill), clear the pill now.
      if (codexTurnEnded) {
        const pill = active.get(t.slug);
        if (pill) {
          try {
            await client.setStatus(pill.channelId, pill.threadTs, "");
          } catch (e) {
            console.error(`clear pill on codex task_complete for ${t.slug} failed:`, e);
          }
          dropActivePill(t.slug);
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
        // Persist the refresh so a restart right after this tick keeps
        // the pill fresh (and within the MAX_RESTORE_AGE_MS window).
        writeActivePill(slug, pill);
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
  // Schedule unconditionally and iterate `tails` live each tick so a Claude
  // agent whose channel resolves AFTER startup (pending loop below) still gets
  // pickers — a once-built `tails.filter(...)` snapshot would skip it, and zero
  // Claude agents at boot would mean the interval was never scheduled at all.
  {
    setInterval(async () => {
      for (const t of tails) {
        if (t.runtime !== "claude") continue;
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
        // shows them at a glance. Drain any pending tool buffer into the
        // PREVIOUS anchor first so those tools don't get dropped, then the
        // picker becomes the new thread anchor.
        try {
          await drainBuffer(t.slug, t.channelId);
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
  // Slash commands (e.g. /stop) come over the same socket. The command body
  // includes channel_id, so we can look up the agent slug from the same
  // channel→agent mapping the inbound message router uses, then act on its
  // tmux session and announce in-channel what we did.
  socket.on("slash_commands", async ({ body, ack }: any) => {
    const cmd: string = body?.command ?? "";
    const channelId: string | undefined = body?.channel_id;
    const userId: string | undefined = body?.user_id;
    if (cmd !== "/stop") {
      if (ack) await ack({ response_type: "ephemeral", text: `Unknown command: ${cmd}` });
      return;
    }
    const slug = channelId ? mapping[channelId] : undefined;
    if (!slug) {
      if (ack) await ack({ response_type: "ephemeral", text: "This channel is not mapped to any agent." });
      return;
    }
    if (ack) await ack();
    const res = sendTmuxKey(slug, "Escape");
    if (!res.ok) {
      console.error(`/stop -> ${slug} send-keys Escape failed:`, res.error);
      try {
        await client.post(channelId!, `:warning: \`/stop\` failed to interrupt *${slug}* — ${res.error ?? "unknown error"}`);
      } catch (e) {
        console.error(`/stop announce (failure) for ${slug} failed:`, e);
      }
      return;
    }
    try {
      const announce = `:octagonal_sign: Sent Esc to *${slug}* — ${userId ? `<@${userId}>` : "someone"} interrupted the current turn.`;
      await client.post(channelId!, announce);
    } catch (e) {
      console.error(`/stop announce for ${slug} failed:`, e);
    }
    // The user explicitly interrupted, so the agent will not produce a
    // terminal stop_reason / task_complete event the post loop could read
    // to drop the pill. Clear it directly. Also remove the 👀 ack if one
    // is still pending — same reason: no real reply is coming so the eyes
    // would orphan.
    const pill = active.get(slug);
    if (pill) {
      try {
        await client.setStatus(pill.channelId, pill.threadTs, "");
      } catch (e) {
        console.error(`/stop clear pill for ${slug} failed:`, e);
      }
      dropActivePill(slug);
    }
    await consumePendingEyes(slug);
  });

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

    // Prefix the sender so the agent can see who is steering it. Only human
    // messages reach here (bot posts are dropped upstream), so this never
    // double-labels an agent's own "From <Agent>:" line.
    const authorName = decision.user ? await resolveUserNameCached(decision.user) : undefined;
    const authored = prefixAuthor(prompt, authorName);

    // Mark this relay so the daemon does not echo it back to the channel
    // (it already appears there as that person's Slack message). Recorded
    // before the paste so the marker is in place before UserPromptSubmit.
    recordAnnounceSuppress(agentIdentity(decision.slug).sessionId);
    // Also remember it for the in-process Codex rollout-echo guard above.
    const relays = recentRelays.get(decision.slug) ?? [];
    relays.push({ text: authored, ts: Date.now() });
    recentRelays.set(decision.slug, relays);
    pasteTmuxPrompt(decision.slug, authored); // tmux session name == slug

    // Post a 👀 ack and light the working pill on it, ONLY if the agent
    // isn't already mid-turn. The eyes give the channel a visible
    // "received" beat in the 10-20s gap before the agent's first reply
    // for the cold-start case, and double as the app-authored anchor
    // that assistant.threads.setStatus requires (Slack rejects the
    // human's own message ts with invalid_thread_ts). The agent's first
    // real text post in this turn will become the new thread root in
    // the post loop, which is also where we delete this eyes message —
    // so the ack disappears the moment the agent actually replies.
    //
    // If a pill is already active for this slug, the agent IS already
    // working: its existing anchor is the truth, an eyes ack just
    // produces a double-pill flash (one on the eyes, one on the agent's
    // ongoing text) and adds a noise emoji that never gets cleaned up
    // because the next text post will land naturally without consuming
    // a freshly-pushed eyes. Skip the ack entirely in that case — the
    // current pill already says the agent is on it.
    if (event.channel && !active.has(decision.slug)) {
      try {
        const ts = await client.post(event.channel, "👀");
        if (ts) {
          setPendingEyes(decision.slug, { channelId: event.channel, ts });
          try {
            await client.setStatus(event.channel, ts, WORKING_LABEL);
            setActivePill(decision.slug, { channelId: event.channel, threadTs: ts, label: WORKING_LABEL, lastSetMs: Date.now() });
          } catch (e) {
            console.error(`setStatus on eyes anchor for ${decision.slug} failed:`, e);
          }
        }
      } catch (e) {
        console.error(`eyes anchor post for ${decision.slug} failed:`, e);
      }
    }
  });
  // ── Pending-channel re-resolution: the #677 self-heal ───────────────────
  // Retry pending agents against a fresh snapshot on a SELF-RESCHEDULING timer
  // (not setInterval — overlapping ticks under Slack rate-limiting could both
  // see an agent pending and double-append its tail). The chain re-arms only
  // while agents remain pending, so it costs nothing once all are mirrored, and
  // pulls ONE conversations.list snapshot per pass shared across all pending
  // agents. A channel created (or the bot invited) after this restart is picked
  // up within one interval — no manual `systemctl restart` (issue #677).
  const RESOLVE_RETRY_MS = 60_000;
  const resolvePendingOnce = async (): Promise<void> => {
    if (!pending.length) return;
    let snapshot: SlackChannelInfo[];
    try {
      snapshot = await client.listChannels();
    } catch (e) {
      console.error("pending-resolve listChannels failed (will retry):", e);
      return;
    }
    const { resolved, stillPending } = matchPendingChannels(pending, snapshot);
    pending = stillPending;
    for (const r of resolved) {
      const a = agentBySlug.get(r.slug);
      if (!a) continue;
      buildTail(a, r.channelId);
      console.error(`now mirroring ${r.slug}: channel ${a.slackChannel} became reachable (no restart).`);
    }
  };
  const schedulePendingResolve = (): void => {
    if (!pending.length) return;
    setTimeout(() => {
      // Always re-arm (while agents remain pending) even if a pass throws — an
      // unexpected error in one pass must not silently kill the self-heal chain.
      resolvePendingOnce()
        .catch((e) => console.error("pending-resolve pass failed (will retry):", e))
        .finally(() => schedulePendingResolve());
    }, RESOLVE_RETRY_MS);
  };
  if (pending.length) {
    // One log line for the whole pending set (not one per agent per tick) so a
    // permanently-misconfigured channel doesn't spam the journal every pass.
    console.error(
      `${pending.length} agent(s) awaiting a reachable Slack channel (created + bot invited): ${pending
        .map((p) => p.slug)
        .join(", ")}. Retrying every ${RESOLVE_RETRY_MS / 1000}s.`,
    );
    schedulePendingResolve();
  }

  await socket.start();
  console.error(
    `Slack bridge connected. Mirroring ${tails.length} agent(s)${pending.length ? `; ${pending.length} pending channel(s).` : "."}`,
  );

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
