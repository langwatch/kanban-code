#!/usr/bin/env node
import { Command } from "commander";
import { execSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir, userInfo } from "node:os";
import { join, resolve } from "node:path";
import {
  readLinks,
  readSettings,
  listTmuxSessions,
  captureTmuxPane,
  peekTmuxPane,
  sendTmuxEnter,
  sendTmuxKeys,
  pasteTmuxPrompt,
  sendTmuxEscape,
  readLastTranscriptTurns,
  readSessionContext,
  filterActiveCards,
  filterByColumn,
  filterByProject,
  findCard,
  toCardSummary,
  toCardDetail,
} from "./data.js";
import {
  formatCardList,
  formatCardDetail,
  formatTmuxSessions,
} from "./format.js";
import type { KanbanColumn, Link } from "./types.js";
import {
  createChannel,
  deleteChannel,
  renameChannel,
  getChannel,
  joinChannel,
  leaveChannel,
  listChannels,
  normalizeChannelName,
  readMessages,
  readTail,
  readDirectMessages,
  statChannel,
} from "./channels.js";
import {
  cardForTmuxSession,
  currentTmuxSessionName,
  formatChannelBroadcast,
  formatDirectMessage,
  sendAndFanOut,
  sendDirectMessage,
} from "./broadcast.js";
import { deriveHandle, formatHandle, stripAt } from "./handles.js";
import { parseDuration, runShare } from "./share-cli.js";

const program = new Command();

program
  .name("kanban")
  .description("Kanban Code CLI — inspect cards, sessions, and orchestrate agents")
  .version("0.1.0");

// ── Helper: output as JSON or pretty ─────────────────────────────────

function output(data: unknown, opts: { json?: boolean }) {
  if (opts.json) {
    process.stdout.write(JSON.stringify(data, null, 2) + "\n");
  } else if (typeof data === "string") {
    process.stdout.write(data + "\n");
  } else {
    process.stdout.write(JSON.stringify(data, null, 2) + "\n");
  }
}

// ── kanban open [path] ───────────────────────────────────────────────

program
  .command("open")
  .description("Open a project in Kanban Code app")
  .argument("[path]", "Project path (defaults to current directory)", ".")
  .action((path: string) => {
    const resolved = resolve(path);
    const kanbanDir = join(homedir(), ".kanban-code");
    mkdirSync(kanbanDir, { recursive: true });
    writeFileSync(join(kanbanDir, "open-project"), resolved);
    try {
      execSync('open -a "KanbanCode"');
    } catch {
      console.error("Failed to open KanbanCode app");
      process.exit(1);
    }
  });

// Also support bare `kanban .` and `kanban /path` (no subcommand)
// Handled via default command at the bottom

// ── kanban list ──────────────────────────────────────────────────────

program
  .command("list")
  .alias("ls")
  .description("List cards grouped by column")
  .option("-c, --column <column>", "Filter by column (in_progress, requires_attention, in_review, done, backlog)")
  .option("-p, --project <path>", "Filter by project path")
  .option("-a, --all", "Include all_sessions (hidden by default)")
  .option("--with-last-message", "Include last transcript message")
  .option("--with-capture-peek", "Include a short peek at each card's tmux pane")
  .option("-j, --json", "Output as JSON")
  .action((opts) => {
    let links = readLinks();
    const tmux = listTmuxSessions();
    const liveTmux = new Set(tmux.map((t) => t.name));

    if (opts.column) {
      links = filterByColumn(links, opts.column as KanbanColumn);
    } else if (!opts.all) {
      links = filterActiveCards(links);
    }

    if (opts.project) {
      const resolved = resolve(opts.project);
      links = filterByProject(links, resolved);
    }

    // Sort: in_progress first, then by lastActivity desc
    const colOrder: Record<string, number> = {
      in_progress: 0,
      requires_attention: 1,
      in_review: 2,
      done: 3,
      backlog: 4,
      all_sessions: 5,
    };
    links.sort((a, b) => {
      const ca = colOrder[a.column] ?? 9;
      const cb = colOrder[b.column] ?? 9;
      if (ca !== cb) return ca - cb;
      const ta = a.lastActivity || a.updatedAt;
      const tb = b.lastActivity || b.updatedAt;
      return tb.localeCompare(ta);
    });

    const summaries = links.map((l) => {
      const s = toCardSummary(l, liveTmux);
      if (opts.withLastMessage && l.sessionLink?.sessionPath) {
        const turns = readLastTranscriptTurns(l.sessionLink.sessionPath, 1);
        if (turns.length) s.lastMessage = turns[turns.length - 1].text;
      }
      if (
        opts.withCapturePeek &&
        l.tmuxLink?.sessionName &&
        liveTmux.has(l.tmuxLink.sessionName)
      ) {
        const peek = peekTmuxPane(l.tmuxLink.sessionName, 15);
        if (peek.trim()) s.peek = peek;
      }
      return s;
    });

    if (opts.json) {
      output(summaries, { json: true });
    } else {
      output(formatCardList(summaries), { json: false });
    }
  });

// ── kanban show <card> ───────────────────────────────────────────────

program
  .command("show")
  .description("Show detailed card information")
  .argument("<card>", "Card ID, ID prefix, or name search")
  .option("-t, --transcript <n>", "Number of transcript turns to show", "5")
  .option("-j, --json", "Output as JSON")
  .action((cardQuery: string, opts) => {
    const links = readLinks();
    const card = findCard(links, cardQuery);
    if (!card) {
      console.error(`Card not found: ${cardQuery}`);
      process.exit(1);
    }

    const tmux = listTmuxSessions();
    const liveTmux = new Set(tmux.map((t) => t.name));
    const detail = toCardDetail(card, liveTmux, parseInt(opts.transcript));

    if (opts.json) {
      output(detail, { json: true });
    } else {
      output(formatCardDetail(detail), { json: false });
    }
  });

// ── kanban sessions ──────────────────────────────────────────────────

program
  .command("sessions")
  .description("List all tmux sessions with card associations")
  .option("-j, --json", "Output as JSON")
  .action((opts) => {
    const tmux = listTmuxSessions();
    const links = readLinks();

    // Build tmux→card map
    const tmuxToCard = new Map<string, string>();
    for (const link of links) {
      if (link.tmuxLink?.sessionName) {
        tmuxToCard.set(link.tmuxLink.sessionName, link.id);
      }
      for (const extra of link.tmuxLink?.extraSessions || []) {
        tmuxToCard.set(extra, link.id);
      }
    }

    const enriched = tmux.map((s) => ({
      ...s,
      cardId: tmuxToCard.get(s.name) || null,
    }));

    if (opts.json) {
      output(enriched, { json: true });
    } else {
      if (!enriched.length) {
        output("No tmux sessions running.", { json: false });
        return;
      }
      const lines = ["Tmux Sessions:", ""];
      for (const s of enriched) {
        const att = s.attached ? " (attached)" : "";
        const card = s.cardId ? ` -> ${s.cardId}` : "";
        lines.push(`  ${s.name}${att}${card}`);
        if (s.path) lines.push(`    path: ${s.path}`);
      }
      output(lines.join("\n"), { json: false });
    }
  });

// ── kanban capture <card> ────────────────────────────────────────────

program
  .command("capture")
  .description("Capture a card's tmux pane — visible screen by default")
  .argument("<card>", "Card ID, ID prefix, or name search")
  .option("-s, --scrollback <lines>", "Include N lines of scrollback history, or 'all'")
  .option("-j, --json", "Output as JSON")
  .action((cardQuery: string, opts) => {
    const links = readLinks();
    const card = findCard(links, cardQuery);
    if (!card) {
      console.error(`Card not found: ${cardQuery}`);
      process.exit(1);
    }
    if (!card.tmuxLink?.sessionName) {
      console.error(`Card has no tmux session: ${card.id}`);
      process.exit(1);
    }

    const scrollback: number | "all" =
      opts.scrollback === "all"
        ? "all"
        : opts.scrollback
          ? parseInt(opts.scrollback, 10)
          : 0;

    const pane = captureTmuxPane(card.tmuxLink.sessionName, scrollback);

    if (opts.json) {
      output(
        { cardId: card.id, tmuxSession: card.tmuxLink.sessionName, output: pane },
        { json: true }
      );
    } else {
      output(pane, { json: false });
    }
  });

// ── kanban send <card> <message> ─────────────────────────────────────

program
  .command("send")
  .description("Send a message to a card's tmux session (paste + Enter)")
  .argument("<card>", "Card ID, ID prefix, or name search")
  .argument("<message>", "Message to send")
  .option("--keys", "Use send-keys instead of paste-buffer (for short single-line)")
  .option("-j, --json", "Output as JSON")
  .action((cardQuery: string, message: string, opts) => {
    const links = readLinks();
    const card = findCard(links, cardQuery);
    if (!card) {
      console.error(`Card not found: ${cardQuery}`);
      process.exit(1);
    }
    if (!card.tmuxLink?.sessionName) {
      console.error(`Card has no tmux session: ${card.id}`);
      process.exit(1);
    }

    const result = opts.keys
      ? sendTmuxKeys(card.tmuxLink.sessionName, message)
      : pasteTmuxPrompt(card.tmuxLink.sessionName, message);

    if (opts.json) {
      output(
        {
          cardId: card.id,
          tmuxSession: card.tmuxLink.sessionName,
          message,
          ...result,
        },
        { json: true }
      );
    } else {
      if (result.ok) {
        console.log(`Sent to ${card.tmuxLink.sessionName}`);
      } else {
        console.error(`Failed: ${result.error}`);
        process.exit(1);
      }
    }
  });

// ── kanban self-compact [follow-up] ─────────────────────────────────

function readFollowUpFromArgsOrStdin(args: string[]): string {
  if (args.length > 0) return args.join(" ");
  if (process.stdin.isTTY) return "";
  try {
    return readFileSync(0, "utf-8").trimEnd();
  } catch {
    return "";
  }
}

function selfCompactTarget(): { card: Link; tmuxSession: string } {
  const tmuxSession = currentTmuxSessionName();
  if (!tmuxSession) {
    throw new Error(
      "Could not detect the current tmux session. `kanban self-compact` must be executed by an agent running inside a tmux session on a Kanban Code card."
    );
  }

  const links = readLinks();
  const card = links.find((l) => l.tmuxLink?.sessionName === tmuxSession);
  if (card) {
    if (card.tmuxLink?.isShellOnly) {
      throw new Error(
        `Tmux session "${tmuxSession}" belongs to a shell-only Kanban Code card terminal. Run this from the card's assistant tmux session.`
      );
    }
    return { card, tmuxSession };
  }

  const extraCard = links.find((l) => l.tmuxLink?.extraSessions?.includes(tmuxSession));
  if (extraCard) {
    throw new Error(
      `Tmux session "${tmuxSession}" is an extra terminal for card ${extraCard.id}, not the card's assistant session. Run this from the agent's primary tmux session.`
    );
  }

  throw new Error(
    `Tmux session "${tmuxSession}" is not linked to any Kanban Code card. ` +
      "`kanban self-compact` should be executed from an agent inside a tmux session on a Kanban Code card."
  );
}

function assertTmuxResult(step: string, result: { ok: boolean; error?: string }): void {
  if (!result.ok) {
    throw new Error(`${step} failed: ${result.error ?? "unknown tmux error"}`);
  }
}

program
  .command("self-compact")
  .description("Send /compact to this agent's own Kanban Code tmux session")
  .argument("[followUp...]", "Optional post-compact prompt. Quote it, or pipe/heredoc multi-line text on stdin.")
  .option("-j, --json", "Output as JSON")
  .addHelpText(
    "after",
    `

Examples:
  kanban self-compact "After compacting, continue with the test run."
  kanban self-compact <<'EOL'
  After compacting:
  1. Re-read the failing test output.
  2. Continue from the current plan.
  EOL
`
  )
  .action((followUpArgs: string[], opts) => {
    try {
      const { card, tmuxSession } = selfCompactTarget();
      const followUp = readFollowUpFromArgsOrStdin(followUpArgs);

      // Flush any pending text, leave transient UI states, request compaction,
      // then provide the optional post-compact continuation prompt.
      assertTmuxResult("send Enter", sendTmuxEnter(tmuxSession));
      assertTmuxResult("send Escape", sendTmuxEscape(tmuxSession));
      assertTmuxResult("send /compact", sendTmuxKeys(tmuxSession, "/compact"));
      if (followUp.trim().length > 0) {
        assertTmuxResult("send post-compact prompt", pasteTmuxPrompt(tmuxSession, followUp));
      }

      const result = {
        ok: true,
        cardId: card.id,
        tmuxSession,
        sentFollowUp: followUp.trim().length > 0,
      };
      if (opts.json) {
        output(result, { json: true });
      } else {
        console.log(
          `Sent /compact to ${tmuxSession}` +
            (result.sentFollowUp ? " with post-compact follow-up." : ".")
        );
      }
    } catch (e) {
      if (opts.json) {
        output({ ok: false, error: String(e instanceof Error ? e.message : e) }, { json: true });
      } else {
        console.error(String(e instanceof Error ? e.message : e));
      }
      process.exit(1);
    }
  });

// ── kanban interrupt <card> ──────────────────────────────────────────

program
  .command("interrupt")
  .description("Send Escape to interrupt the assistant in a card's session")
  .argument("<card>", "Card ID, ID prefix, or name search")
  .option("-j, --json", "Output as JSON")
  .action((cardQuery: string, opts) => {
    const links = readLinks();
    const card = findCard(links, cardQuery);
    if (!card) {
      console.error(`Card not found: ${cardQuery}`);
      process.exit(1);
    }
    if (!card.tmuxLink?.sessionName) {
      console.error(`Card has no tmux session: ${card.id}`);
      process.exit(1);
    }

    const result = sendTmuxEscape(card.tmuxLink.sessionName);

    if (opts.json) {
      output(
        { cardId: card.id, tmuxSession: card.tmuxLink.sessionName, ...result },
        { json: true }
      );
    } else {
      if (result.ok) {
        console.log(`Interrupted ${card.tmuxLink.sessionName}`);
      } else {
        console.error(`Failed: ${result.error}`);
        process.exit(1);
      }
    }
  });

// ── kanban transcript <card> ─────────────────────────────────────────

program
  .command("transcript")
  .description("Show recent transcript for a card's session")
  .argument("<card>", "Card ID, ID prefix, or name search")
  .option("-n, --turns <n>", "Number of turns to show", "10")
  .option("-j, --json", "Output as JSON")
  .action((cardQuery: string, opts) => {
    const links = readLinks();
    const card = findCard(links, cardQuery);
    if (!card) {
      console.error(`Card not found: ${cardQuery}`);
      process.exit(1);
    }
    if (!card.sessionLink?.sessionPath) {
      console.error(`Card has no session transcript: ${card.id}`);
      process.exit(1);
    }

    const turns = readLastTranscriptTurns(
      card.sessionLink.sessionPath,
      parseInt(opts.turns)
    );

    if (opts.json) {
      output(turns, { json: true });
    } else {
      if (!turns.length) {
        console.log("No transcript turns found.");
        return;
      }
      for (const turn of turns) {
        const prefix = turn.role === "user" ? "YOU" : " AI";
        const text = turn.text.slice(0, 300);
        console.log(`[${prefix}] ${text}`);
        console.log("");
      }
    }
  });

// ── kanban projects ──────────────────────────────────────────────────

program
  .command("projects")
  .description("List configured projects")
  .option("-j, --json", "Output as JSON")
  .action((opts) => {
    const settings = readSettings();

    if (opts.json) {
      output(settings.projects, { json: true });
    } else {
      if (!settings.projects.length) {
        console.log("No projects configured.");
        return;
      }
      for (const p of settings.projects) {
        const vis = p.visible ? "" : " (hidden)";
        console.log(`  ${p.name}${vis}`);
        console.log(`    ${p.path}`);
      }
    }
  });

// ── kanban status ────────────────────────────────────────────────────

program
  .command("status")
  .description("Quick overview of active work across all projects")
  .option("-j, --json", "Output as JSON")
  .action((opts) => {
    const links = readLinks();
    const tmux = listTmuxSessions();
    const liveTmux = new Set(tmux.map((t) => t.name));
    const active = filterActiveCards(links);

    const byColumn: Record<string, number> = {};
    let aliveCount = 0;
    let withPR = 0;
    let queued = 0;
    let totalInputTokens = 0;
    let totalOutputTokens = 0;
    let totalCost = 0;

    for (const link of active) {
      byColumn[link.column] = (byColumn[link.column] || 0) + 1;
      if (link.tmuxLink?.sessionName && liveTmux.has(link.tmuxLink.sessionName))
        aliveCount++;
      if (link.prLinks?.length) withPR++;
      if (link.queuedPrompts?.length) queued += link.queuedPrompts.length;
      if (link.sessionLink?.sessionId) {
        const ctx = readSessionContext(link.sessionLink.sessionId);
        if (ctx) {
          totalInputTokens += ctx.totalInputTokens;
          totalOutputTokens += ctx.totalOutputTokens;
          totalCost += ctx.totalCostUsd;
        }
      }
    }

    const summary = {
      totalActive: active.length,
      byColumn,
      liveTerminals: aliveCount,
      totalTmuxSessions: tmux.length,
      cardsWithPRs: withPR,
      queuedPrompts: queued,
      tokens: {
        input: totalInputTokens,
        output: totalOutputTokens,
        total: totalInputTokens + totalOutputTokens,
        cost: Math.round(totalCost * 100) / 100,
      },
    };

    if (opts.json) {
      output(summary, { json: true });
    } else {
      console.log(`Active cards: ${summary.totalActive}`);
      for (const [col, count] of Object.entries(byColumn)) {
        console.log(`  ${col}: ${count}`);
      }
      console.log(`Live terminals: ${aliveCount} / ${tmux.length} tmux sessions`);
      console.log(`Cards with PRs: ${withPR}`);
      if (queued) console.log(`Queued prompts: ${queued}`);
      const tok = summary.tokens;
      if (tok.total > 0) {
        const fmt = (n: number) =>
          n >= 1_000_000
            ? `${(n / 1_000_000).toFixed(1)}M`
            : n >= 1_000
              ? `${(n / 1_000).toFixed(0)}k`
              : `${n}`;
        console.log(
          `Tokens: ${fmt(tok.input)} in / ${fmt(tok.output)} out (${fmt(tok.total)} total) — $${tok.cost.toFixed(2)}`
        );
      }
    }
  });

// ── kanban channel ... ──────────────────────────────────────────────

/**
 * Resolve the caller's card + handle via $TMUX autodetect, or a --as override,
 * or --as-user. Returns { cardId, handle }. cardId=null represents the user.
 */
function humanHandle(): string {
  try {
    const u = userInfo().username;
    const slug = u.toLowerCase().replace(/[^a-z0-9]+/g, "_").replace(/^_+|_+$/g, "");
    return slug || "user";
  } catch {
    return "user";
  }
}

function resolveCaller(
  opts: { as?: string; asUser?: boolean; asCardId?: string },
  channelName: string | undefined
): { cardId: string | null; handle: string } {
  if (opts.asUser) return { cardId: null, handle: humanHandle() };
  const links = readLinks();
  if (opts.as) {
    const handle = stripAt(opts.as);
    // Explicit cardId override wins.
    if (opts.asCardId) {
      return { cardId: opts.asCardId, handle };
    }
    // Prefer a live card whose handle matches in the target channel.
    if (channelName) {
      const ch = getChannel(channelName);
      const m = ch?.members.find((x) => x.handle === handle);
      if (m) return { cardId: m.cardId, handle };
    }
    // Fallback: no specific card, just the chosen handle.
    return { cardId: null, handle };
  }
  const session = currentTmuxSessionName();
  if (!session) {
    throw new Error(
      "Could not detect your tmux session. Run inside tmux or pass --as <handle> / --as-user."
    );
  }
  const card = cardForTmuxSession(links, session);
  if (!card) {
    throw new Error(
      `Tmux session "${session}" is not linked to any kanban card. Pass --as <handle> or --as-user.`
    );
  }
  // Handle: prefer the already-registered handle for this channel, else derive.
  if (channelName) {
    const ch = getChannel(channelName);
    const m = ch?.members.find((x) => x.cardId === card.id);
    if (m) return { cardId: card.id, handle: m.handle };
    const taken = new Set((ch?.members ?? []).map((x) => x.handle));
    const handle = deriveHandle(card.name ?? card.id, taken);
    return { cardId: card.id, handle };
  }
  // No channel context — generate handle from display name alone.
  const handle = deriveHandle(card.name ?? card.id, new Set());
  return { cardId: card.id, handle };
}

function relativeTime(iso: string): string {
  const then = new Date(iso).getTime();
  const now = Date.now();
  const secs = Math.max(1, Math.round((now - then) / 1000));
  if (secs < 60) return `${secs}s ago`;
  const mins = Math.round(secs / 60);
  if (mins < 60) return `${mins}m ago`;
  const hrs = Math.round(mins / 60);
  if (hrs < 24) return `${hrs}h ago`;
  const days = Math.round(hrs / 24);
  return `${days}d ago`;
}

function liveTmuxSet(): Set<string> {
  try {
    return new Set(listTmuxSessions().map((s) => s.name));
  } catch {
    return new Set();
  }
}

const channelCmd = program.command("channel").description("Chat channels for multi-agent coordination");

channelCmd
  .command("list")
  .description("List all channels with member count and last activity")
  .option("-j, --json", "Output as JSON")
  .action((opts) => {
    const channels = listChannels();
    const live = liveTmuxSet();
    const links = readLinks();
    const rows = channels.map((ch) => {
      const st = statChannel(ch.name);
      const onlineCount = ch.members.filter((m) => {
        if (m.cardId === null) return true;
        const link = links.find((l) => l.id === m.cardId);
        return link?.tmuxLink?.sessionName && live.has(link.tmuxLink.sessionName);
      }).length;
      return {
        name: ch.name,
        members: ch.members.length,
        online: onlineCount,
        lastMessageAt: st?.lastMessageAt,
        lastMessagePreview: st?.lastMessage?.body?.slice(0, 80),
      };
    });
    if (opts.json) {
      output(rows, { json: true });
      return;
    }
    if (rows.length === 0) {
      console.log("No channels yet. Create one: kanban channel create <name>");
      return;
    }
    for (const r of rows) {
      const ago = r.lastMessageAt ? relativeTime(r.lastMessageAt) : "—";
      console.log(`#${r.name.padEnd(20)} ${r.online}/${r.members} online  ${ago.padEnd(10)} ${r.lastMessagePreview ?? ""}`);
    }
  });

channelCmd
  .command("create")
  .description("Create a new channel")
  .argument("<name>", "Channel name (letters, digits, _ -)")
  .option("--as <handle>", "Act as this handle")
    .option("--as-card-id <id>", "Explicit card id for the --as handle (testing + overrides)")
  .option("--as-user", "Act as the human user")
  .option("-j, --json", "Output as JSON")
  .action((name: string, opts) => {
    try {
      const clean = normalizeChannelName(name);
      const caller = resolveCaller(opts, undefined);
      const ch = createChannel(clean, { createdBy: caller });
      // Auto-join the creator.
      joinChannel(clean, caller);
      if (opts.json) {
        output({ channel: ch, joined: caller }, { json: true });
      } else {
        console.log(`Created #${clean} (joined as ${formatHandle(caller.handle)})`);
      }
    } catch (e) {
      console.error(String(e instanceof Error ? e.message : e));
      process.exit(1);
    }
  });

channelCmd
  .command("join")
  .description("Join a channel")
  .argument("<name>", "Channel name")
  .option("--as <handle>", "Act as this handle")
    .option("--as-card-id <id>", "Explicit card id for the --as handle (testing + overrides)")
  .option("--as-user", "Act as the human user")
  .option("-n, --tail <N>", "Print the last N messages as catch-up", "10")
  .option("-j, --json", "Output as JSON")
  .action((name: string, opts) => {
    try {
      const clean = normalizeChannelName(name);
      const ch = getChannel(clean);
      if (!ch) {
        console.error(`Channel "#${clean}" does not exist`);
        process.exit(1);
      }
      const caller = resolveCaller(opts, clean);
      const { alreadyMember, channel } = joinChannel(clean, caller);
      const tailN = parseInt(String(opts.tail ?? "10"), 10);
      const tail = readTail(clean, isNaN(tailN) ? 10 : tailN);
      if (opts.json) {
        output({ alreadyMember, channel, tail }, { json: true });
        return;
      }
      if (alreadyMember) {
        console.log(`Already a member of #${clean} as ${formatHandle(caller.handle)}`);
      } else {
        console.log(`Joined #${clean} as ${formatHandle(caller.handle)}`);
      }
      if (tail.length > 0) {
        console.log(`\nRecent (${tail.length}):`);
        for (const m of tail) {
          console.log(`  ${formatHandle(m.from.handle)}: ${m.body}`);
        }
      }
    } catch (e) {
      console.error(String(e instanceof Error ? e.message : e));
      process.exit(1);
    }
  });

channelCmd
  .command("leave")
  .description("Leave a channel")
  .argument("<name>", "Channel name")
  .option("--as <handle>", "Act as this handle")
    .option("--as-card-id <id>", "Explicit card id for the --as handle (testing + overrides)")
  .option("--as-user", "Act as the human user")
  .option("-j, --json", "Output as JSON")
  .action((name: string, opts) => {
    try {
      const clean = normalizeChannelName(name);
      const caller = resolveCaller(opts, clean);
      const ch = leaveChannel(clean, { cardId: caller.cardId, handle: caller.handle });
      if (!ch) {
        console.error(`Channel "#${clean}" does not exist`);
        process.exit(1);
      }
      if (opts.json) {
        output({ channel: ch }, { json: true });
      } else {
        console.log(`Left #${clean}`);
      }
    } catch (e) {
      console.error(String(e instanceof Error ? e.message : e));
      process.exit(1);
    }
  });

channelCmd
  .command("members")
  .description("List members of a channel with online status")
  .argument("<name>", "Channel name")
  .option("-j, --json", "Output as JSON")
  .action((name: string, opts) => {
    const clean = normalizeChannelName(name);
    const ch = getChannel(clean);
    if (!ch) {
      console.error(`Channel "#${clean}" does not exist`);
      process.exit(1);
    }
    const live = liveTmuxSet();
    const links = readLinks();
    const rows = ch.members.map((m) => {
      let online = false;
      if (m.cardId === null) online = true;
      else {
        const link = links.find((l) => l.id === m.cardId);
        const s = link?.tmuxLink?.sessionName;
        online = !!(s && live.has(s));
      }
      return { handle: m.handle, cardId: m.cardId, online, joinedAt: m.joinedAt };
    });
    if (opts.json) {
      output(rows, { json: true });
      return;
    }
    console.log(`#${clean} — ${rows.length} member(s)`);
    for (const r of rows) {
      const dot = r.online ? "●" : "○";
      console.log(`  ${dot} ${formatHandle(r.handle).padEnd(24)} ${r.cardId ?? "(user)"}`);
    }
  });

channelCmd
  .command("send")
  .description("Send a message to a channel (broadcasts to all members)")
  .argument("<name>", "Channel name")
  .argument("<message...>", "Message body (joined with spaces)")
  .option("--as <handle>", "Act as this handle")
    .option("--as-card-id <id>", "Explicit card id for the --as handle (testing + overrides)")
  .option("--as-user", "Act as the human user")
  .option("--no-fanout", "Write to log but do not tmux-broadcast")
  .option(
    "--image <path>",
    "Attach an image (repeat to attach multiple)",
    (v: string, acc: string[]) => (acc ? [...acc, v] : [v]),
    [] as string[]
  )
  .option("-j, --json", "Output as JSON")
  .action((name: string, message: string[], opts) => {
    try {
      const clean = normalizeChannelName(name);
      const ch = getChannel(clean);
      if (!ch) {
        console.error(`Channel "#${clean}" does not exist`);
        process.exit(1);
      }
      const caller = resolveCaller(opts, clean);
      // Auto-join on first send so we stay consistent.
      joinChannel(clean, caller);
      const links = readLinks();
      const body = message.join(" ");
      const live = liveTmuxSet();
      const imagePaths: string[] = Array.isArray(opts.image) ? opts.image : [];
      const { msg, result } = sendAndFanOut(
        clean,
        caller,
        body,
        links,
        undefined,
        {
          sender: opts.fanout === false ? () => ({ ok: true }) : undefined,
          liveSessionProbe: (s) => live.has(s),
        },
        imagePaths
      );
      if (opts.json) {
        output({ msg, result }, { json: true });
      } else {
        console.log(`${formatHandle(caller.handle)} → #${clean}: ${body}`);
        if (result.delivered.length > 0) {
          console.log(`  delivered to: ${result.delivered.map((d) => formatHandle(d.handle)).join(", ")}`);
        }
        if (result.skippedOffline.length > 0) {
          console.log(`  skipped: ${result.skippedOffline.map((d) => `${formatHandle(d.handle)} (${d.reason})`).join(", ")}`);
        }
      }
    } catch (e) {
      console.error(String(e instanceof Error ? e.message : e));
      process.exit(1);
    }
  });

channelCmd
  .command("history")
  .description("Show channel message history")
  .argument("<name>", "Channel name")
  .option("-n, --tail <N>", "Show last N messages (default all)", "50")
  .option("-j, --json", "Output as JSON")
  .action((name: string, opts) => {
    const clean = normalizeChannelName(name);
    const ch = getChannel(clean);
    if (!ch) {
      console.error(`Channel "#${clean}" does not exist`);
      process.exit(1);
    }
    const n = parseInt(String(opts.tail ?? "50"), 10);
    const msgs = isNaN(n) ? readMessages(clean) : readTail(clean, n);
    if (opts.json) {
      output(msgs, { json: true });
      return;
    }
    for (const m of msgs) {
      const ago = relativeTime(m.ts);
      const tag = m.type === "message" ? "" : `[${m.type}] `;
      console.log(`  ${ago.padEnd(10)} ${formatHandle(m.from.handle).padEnd(20)} ${tag}${m.body}`);
    }
  });

channelCmd
  .command("delete")
  .description("Delete a channel (does not delete history file)")
  .argument("<name>", "Channel name")
  .option("-j, --json", "Output as JSON")
  .action((name: string, opts) => {
    const clean = normalizeChannelName(name);
    const ok = deleteChannel(clean);
    if (opts.json) {
      output({ deleted: ok }, { json: true });
      return;
    }
    if (ok) console.log(`Deleted #${clean}`);
    else {
      console.error(`Channel "#${clean}" does not exist`);
      process.exit(1);
    }
  });

channelCmd
  .command("open")
  .description("Open a channel in the Kanban Code app via kanbancode:// deep link.")
  .argument("<name>", "Channel name (with or without leading #)")
  .action((name: string) => {
    const clean = normalizeChannelName(name);
    try {
      execSync(`open "kanbancode://channel/${clean}"`, { stdio: "ignore" });
      console.log(`Opened #${clean}`);
    } catch (err) {
      console.error(`Failed to open app: ${(err as Error).message ?? err}`);
      process.exit(1);
    }
  });

channelCmd
  .command("rename")
  .description("Rename a channel. Moves the .jsonl log file to the new name.")
  .argument("<old>", "Current channel name")
  .argument("<new>", "New channel name")
  .option("-j, --json", "Output as JSON")
  .action((oldName: string, newName: string, opts) => {
    try {
      const ok = renameChannel(oldName, newName);
      const oldClean = normalizeChannelName(oldName);
      const newClean = normalizeChannelName(newName);
      if (opts.json) {
        output({ renamed: ok, from: oldClean, to: newClean }, { json: true });
        return;
      }
      if (ok) console.log(`Renamed #${oldClean} → #${newClean}`);
      else {
        console.error(`Channel "#${oldClean}" does not exist`);
        process.exit(1);
      }
    } catch (err) {
      console.error(String((err as Error).message ?? err));
      process.exit(1);
    }
  });

// ── kanban channel share ────────────────────────────────────────────

channelCmd
  .command("share")
  .description(
    "Start a public share link for a channel. Runs a local Express server, " +
      "opens a cloudflared tunnel, and keeps running until the duration expires. " +
      "Writes url/token/port/expiresAt on stdout (one per line) for parent processes.",
  )
  .argument("<name>", "Channel name to share")
  .option("-d, --duration <d>", "How long the link stays live (e.g. 5m, 1h)", "15m")
  .option("--web-dist <path>", "Directory with the built web client to serve at /")
  .action(async (name: string, opts: { duration: string; webDist?: string }) => {
    const clean = normalizeChannelName(name);
    const ch = getChannel(clean);
    if (!ch) {
      console.error(`Channel "#${clean}" does not exist`);
      process.exit(1);
    }
    let durationMs: number;
    try { durationMs = parseDuration(opts.duration); } catch (err) {
      console.error(String(err instanceof Error ? err.message : err));
      process.exit(1);
    }

    // Bundled with the app? Default web dist lives alongside the CLI bundle.
    // Swift passes --web-dist explicitly so we only fall through to the
    // next lookup when run standalone.
    const webDist = opts.webDist;

    let handle: Awaited<ReturnType<typeof runShare>>;
    try {
      handle = await runShare({
        channelName: clean,
        durationMs,
        loadLinks: () => readLinks(),
        sender: pasteTmuxPrompt,
        liveSessionProbe: (s) => listTmuxSessions().some((t) => t.name === s),
        baseDir: join(homedir(), ".kanban-code"),
        webDistDir: webDist,
      });
    } catch (err) {
      console.error(`Failed to start share: ${err instanceof Error ? err.message : err}`);
      process.exit(1);
    }

    // Teardown on parent-initiated signals so the tunnel doesn't outlive us.
    const shutdown = async (): Promise<void> => {
      await handle.stop();
      await handle.done;
      process.exit(0);
    };
    process.on("SIGTERM", () => { void shutdown(); });
    process.on("SIGINT", () => { void shutdown(); });
    // Parent (Swift app) closes our stdin when it quits — treat as shutdown.
    process.stdin.on("end", () => { void shutdown(); });
    process.stdin.resume();

    await handle.done;
    process.exit(0);
  });

// ── kanban dm ───────────────────────────────────────────────────────

function findCardByHandle(handle: string): Link | undefined {
  const want = stripAt(handle);
  const channels = listChannels();
  for (const ch of channels) {
    const m = ch.members.find((x) => x.handle === want);
    if (m && m.cardId) {
      const l = readLinks().find((x) => x.id === m.cardId);
      if (l) return l;
    }
  }
  return undefined;
}

const dmCmd = program.command("dm").description("Send a direct message to another agent");

dmCmd
  .command("send", { isDefault: true })
  .description("Send a DM (default action)")
  .argument("<handle>", "Target handle (with or without @)")
  .argument("<message...>", "Message body")
  .option("--as <handle>", "Act as this handle")
    .option("--as-card-id <id>", "Explicit card id for the --as handle (testing + overrides)")
  .option("--as-user", "Act as the human user")
  .option(
    "--image <path>",
    "Attach an image (repeat to attach multiple)",
    (v: string, acc: string[]) => (acc ? [...acc, v] : [v]),
    [] as string[]
  )
  .option("-j, --json", "Output as JSON")
  .action((handle: string, message: string[], opts) => {
    try {
      const caller = resolveCaller(opts, undefined);
      const target = findCardByHandle(handle);
      if (!target) {
        console.error(`Unknown handle "${handle}"`);
        process.exit(1);
      }
      const body = message.join(" ");
      const live = liveTmuxSet();
      const links = readLinks();
      const imagePaths: string[] = Array.isArray(opts.image) ? opts.image : [];
      const { msg, delivered, error } = sendDirectMessage(
        caller,
        { cardId: target.id, handle: stripAt(handle) },
        body,
        links,
        undefined,
        { liveSessionProbe: (s) => live.has(s) },
        imagePaths
      );
      if (opts.json) {
        output({ msg, delivered, error }, { json: true });
      } else {
        const tag = delivered ? "delivered" : (error ?? "not delivered");
        console.log(`${formatHandle(caller.handle)} → ${formatHandle(stripAt(handle))}: ${body} [${tag}]`);
      }
      if (!delivered) process.exit(2);
    } catch (e) {
      console.error(String(e instanceof Error ? e.message : e));
      process.exit(1);
    }
  });

dmCmd
  .command("history")
  .description("Show DM history with another handle")
  .argument("<handle>", "Other party's handle")
  .option("--as <handle>", "Act as this handle")
    .option("--as-card-id <id>", "Explicit card id for the --as handle (testing + overrides)")
  .option("--as-user", "Act as the human user")
  .option("-j, --json", "Output as JSON")
  .action((handle: string, opts) => {
    try {
      const caller = resolveCaller(opts, undefined);
      const target = findCardByHandle(handle);
      const other = target ? target.id : `@${stripAt(handle)}`;
      const self = caller.cardId ?? `@${caller.handle}`;
      const msgs = readDirectMessages(self, other);
      if (opts.json) {
        output(msgs, { json: true });
        return;
      }
      for (const m of msgs) {
        console.log(`  ${relativeTime(m.ts).padEnd(10)} ${formatHandle(m.from.handle)}: ${m.body}`);
      }
    } catch (e) {
      console.error(String(e instanceof Error ? e.message : e));
      process.exit(1);
    }
  });

dmCmd
  .command("open")
  .description("Open a DM with another handle in the Kanban Code app.")
  .argument("<handle>", "Other party's handle (with or without @)")
  .action((handle: string) => {
    const clean = stripAt(handle);
    const card = findCardByHandle(handle);
    const url = card
      ? `kanbancode://dm/${clean}?cardId=${card.id}`
      : `kanbancode://dm/${clean}`;
    try {
      execSync(`open "${url}"`, { stdio: "ignore" });
      console.log(`Opened DM with @${clean}`);
    } catch (err) {
      console.error(`Failed to open app: ${(err as Error).message ?? err}`);
      process.exit(1);
    }
  });

// ── Default: kanban [path] opens the app ─────────────────────────────

// Handle the case where user runs `kanban .` or `kanban /some/path`
// without a subcommand — this is the original bash script behavior.
program
  .argument("[path]", "Project path to open (defaults to current directory)")
  .action((path: string | undefined) => {
    if (!path) {
      // Bare `kanban` with no args — show help
      program.help();
      return;
    }
    const resolved = resolve(path);
    if (existsSync(resolved)) {
      const kanbanDir = join(homedir(), ".kanban-code");
      mkdirSync(kanbanDir, { recursive: true });
      writeFileSync(join(kanbanDir, "open-project"), resolved);
      try {
        execSync('open -a "KanbanCode"');
      } catch {
        console.error("Failed to open KanbanCode app");
        process.exit(1);
      }
      return;
    }
    // Not a folder and not a known command — help the user out
    console.error(
      `'${path}' is not a folder or known command. Did you mean to run a command?\n`
    );
    program.help({ error: true });
  });

program.parse();
