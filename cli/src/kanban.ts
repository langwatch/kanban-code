#!/usr/bin/env node
import { Command } from "commander";
import { execSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync, writeSync } from "node:fs";
import { homedir, userInfo } from "node:os";
import { join, resolve } from "node:path";
import {
  readLinks,
  readSettings,
  listTmuxSessions,
  captureTmuxPane,
  peekTmuxPane,
  sendTmuxKeys,
  sendTmuxEnter,
  pasteTmuxPrompt,
  interruptTmuxPrompt,
  sendTmuxEscape,
  scheduleTmuxSelfCompact,
  findSessionJsonl,
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
  formatCardSummary,
  formatTmuxSessions,
} from "./format.js";
import { agentIdentity } from "./agents/identity.js";
import { ensureAgentSession } from "./agents/launch.js";
import { loadAgentsConfig } from "./agents/config.js";
import { reconcileAll } from "./agents/reconcile.js";
import { installHooks } from "./hooks.js";
import { Daemon } from "./agents/daemon.js";
import { slackAppManifest, MANIFEST_INSTRUCTIONS } from "./slack/manifest.js";
import { runSlackBridge } from "./slack/bridge.js";
import { announceToSlack, announceRawToSlack } from "./slack/announce.js";
import { SlackClient } from "./slack/client.js";
import { postToSlack } from "./slack/post.js";
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
import { parseDeliveryMode, type DeliveryMode } from "./delivery.js";
import { queueCardPrompt } from "./cards.js";
import { parseDuration, runShare } from "./share-cli.js";
import {
  assertOwnedSubagent,
  buildSubagentPrompt,
  currentCardOrThrow,
  descendantIds,
  kanbanCodeIsRunning,
  makeSubagentRequest,
  missingForkSessionError,
  appliesModelSwitchDirectly,
  missingHandleError,
  modelSwitchCommand,
  needsModelSwitchConfirmation,
  normalizeSubagentHandle,
  resolveSubagentPrompt,
  subagentDepth,
  submitSubagentRequest,
  validateCanSpawn,
} from "./subagents.js";
import type { CodingAssistant } from "./types.js";
import { cardSelfCompactRules, parseContextThreshold, tokenLabel } from "./self-compact.js";

const program = new Command();

/**
 * Commander writes help and then exits. On a pipe `process.stdout.write` is
 * asynchronous, so `process.exit` can drop everything past the first buffer and
 * agents piping `--help` into `head` see a truncated command list. Writing the
 * file descriptor synchronously makes the whole page survive.
 */
function writeSyncToFd(fd: number, text: string): void {
  const buffer = Buffer.from(text, "utf8");
  let offset = 0;
  while (offset < buffer.length) {
    try {
      offset += writeSync(fd, buffer, offset, buffer.length - offset);
    } catch (error) {
      const code = (error as NodeJS.ErrnoException).code;
      if (code === "EAGAIN") continue;
      if (code === "EPIPE") return;
      throw error;
    }
  }
}

program
  .name("kanban")
  .description(
    "Kanban Code CLI — inspect cards, sessions, and orchestrate agents\n" +
      "Read this help in full. Do not pipe it through head or tail; the command list continues below."
  )
  .version("0.1.0")
  .configureOutput({
    writeOut: (str) => writeSyncToFd(1, str),
    writeErr: (str) => writeSyncToFd(2, str),
  });

function sortTopLevelCommands(names: string[]): void {
  const rank = new Map(names.map((name, index) => [name, index]));
  const originalIndex = new Map(program.commands.map((cmd, index) => [cmd, index]));
  const commands = program.commands as unknown as Command[];
  commands.sort((a: Command, b: Command) => {
    const aRank = rank.get(a.name()) ?? Number.MAX_SAFE_INTEGER;
    const bRank = rank.get(b.name()) ?? Number.MAX_SAFE_INTEGER;
    if (aRank !== bRank) return aRank - bRank;
    return (originalIndex.get(a) ?? 0) - (originalIndex.get(b) ?? 0);
  });
}

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
  .description("List cards grouped by column, including context token usage when available")
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

    // Child sessions live under their parent instead of in workflow lanes.
    // Use `kanban subagent list` from the parent to inspect them.
    links = links.filter((link) => !link.parentCardId);

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

// ── kanban relink <card> <session> ───────────────────────────────────

program
  .command("relink")
  .description("Point a card at a different session transcript")
  .argument("<card>", "Card ID, ID prefix, or name search")
  .argument("<session>", "Session ID of the transcript to link")
  .option("-j, --json", "Output as JSON")
  .action(async (cardQuery: string, sessionId: string, opts) => {
    try {
      const card = findCard(readLinks(), cardQuery);
      if (!card) throw new Error(`Card not found: ${cardQuery}`);
      const sessionPath = findSessionJsonl(sessionId);
      if (!sessionPath) throw new Error(`No transcript found for session ${sessionId}`);
      // Reconciliation never moves a card off a session it already has, and the
      // running app flushes its own board over links.json, so the relink has to
      // be the app's own write.
      if (!kanbanCodeIsRunning()) {
        throw new Error("Kanban Code is not running. Start it so the relink is not overwritten.");
      }
      const response = await submitSubagentRequest(
        makeSubagentRequest("relinkSession", card.id, { cardId: card.id, sessionId, sessionPath })
      );
      if (!response.ok) throw new Error(response.error ?? "unknown error");
      if (opts.json) output({ cardId: card.id, sessionId, sessionPath }, { json: true });
      else console.log(`Relinked ${card.name ?? card.id} to ${sessionId}`);
    } catch (error) {
      console.error(String(error instanceof Error ? error.message : error));
      process.exit(1);
    }
  });

// ── kanban send <card> <message> ─────────────────────────────────────

/** A bad --mode is a usage error, not a crash. */
function deliveryModeOrExit(raw: string | undefined): DeliveryMode {
  try {
    return parseDeliveryMode(raw);
  } catch (error) {
    console.error(String(error instanceof Error ? error.message : error));
    process.exit(1);
  }
}

/**
 * Append a prompt to a card's queue. A running Kanban Code owns links.json and
 * flushes its own in-memory board over it, so the write has to go through the
 * command mailbox; without the app there is nothing to race with.
 */
async function queuePromptForCard(
  card: Link,
  message: string,
  opts: { json?: boolean }
): Promise<void> {
  if (kanbanCodeIsRunning()) {
    const response = await submitSubagentRequest(
      makeSubagentRequest("enqueuePrompt", card.id, { cardId: card.id, prompt: message })
    );
    if (!response.ok) {
      console.error(`Failed: ${response.error ?? "unknown error"}`);
      process.exit(1);
    }
  } else if (!queueCardPrompt(card.id, message)) {
    console.error(`Card not found: ${card.id}`);
    process.exit(1);
  }

  if (opts.json) {
    output({ cardId: card.id, mode: "queue", message, ok: true }, { json: true });
  } else {
    console.log(`Queued for ${card.name ?? card.id}`);
  }
}

program
  .command("send")
  .description("Low-level: deliver a message to one card's session (not channel chat)")
  .argument("<card>", "Card ID, ID prefix, or name search")
  .argument("<message>", "Message to send")
  .option(
    "--mode <mode>",
    "steer (paste now, read between turns), queue (wait for the agent to go idle), or interrupt (Escape first, then send)",
    "steer"
  )
  .option("--keys", "Use send-keys instead of paste-buffer (for short single-line)")
  .option("--announce", "(deprecated, no-op: prompts are mirrored to Slack on confirmed receipt by the daemon)")
  .option("-j, --json", "Output as JSON")
  .action(async (cardQuery: string, message: string, opts) => {
    const mode = deliveryModeOrExit(opts.mode);
    const links = readLinks();
    const card = findCard(links, cardQuery);
    if (!card) {
      console.error(`Card not found: ${cardQuery}`);
      process.exit(1);
    }

    if (mode === "queue") {
      await queuePromptForCard(card, message, { json: opts.json });
      return;
    }

    if (!card.tmuxLink?.sessionName) {
      console.error(`Card has no tmux session: ${card.id}`);
      process.exit(1);
    }

    const send = opts.keys ? sendTmuxKeys : pasteTmuxPrompt;
    const result = mode === "interrupt"
      ? interruptTmuxPrompt(card.tmuxLink.sessionName, message, send)
      : send(card.tmuxLink.sessionName, message);

    // No announce here: the prompt is mirrored to Slack only once the agent's
    // UserPromptSubmit hook confirms it was actually received (the daemon does
    // it), so a paste that never becomes a submitted prompt is never falsely
    // announced as received.

    if (opts.json) {
      output(
        {
          cardId: card.id,
          tmuxSession: card.tmuxLink.sessionName,
          mode,
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

// ── kanban launch <slug> ─────────────────────────────────────────────

program
  .command("launch")
  .description("Launch or resume a long-lived agent session in tmux with a stable, readable identity")
  .argument("<slug>", "Readable agent slug, e.g. dependabot-scout")
  .requiredOption("--cwd <path>", "Working directory for the session (the agent's worktree/workspace)")
  .option("--model <model>", "Model alias or full name")
  .option("--no-skip-permissions", "Do NOT pass --dangerously-skip-permissions")
  .option("--no-resume", "Always start a fresh session, never resume a prior one under this slug (for ephemeral agents)")
  .option("-j, --json", "Output as JSON")
  .action((slug: string, opts) => {
    try {
      const cwd = resolve(opts.cwd);
      if (!existsSync(cwd)) throw new Error(`cwd does not exist: ${cwd}`);
      const identity = agentIdentity(slug);
      const result = ensureAgentSession(identity, {
        cwd,
        model: opts.model,
        skipPermissions: opts.skipPermissions,
        forceFresh: opts.resume === false,
      });
      if (opts.json) {
        output(result, opts);
      } else {
        const verb = {
          "noop-running": "already running",
          launched: "launched",
          resumed: "resumed",
        }[result.action];
        output(
          `Agent "${slug}" ${verb} (session ${result.sessionId}, tmux ${result.tmuxName}, card ${result.card.id})`,
          opts
        );
      }
    } catch (e) {
      process.stderr.write(`Error: ${(e as Error).message}\n`);
      process.exit(1);
    }
  });

// ── kanban reconcile ─────────────────────────────────────────────────

program
  .command("reconcile")
  .description("Idempotently reconcile all configured agents: clean+pull repos, ensure worktrees, launch/resume sessions")
  .option(
    "--config <path>",
    "Path to agents.yaml",
    process.env.KANBAN_AGENTS_CONFIG || join(homedir(), ".kanban-code", "agents.yaml")
  )
  .option("--prune", "Tear down agent sessions/cards no longer in the config")
  .option("-j, --json", "Output as JSON")
  .action((opts) => {
    try {
      const file = loadAgentsConfig(opts.config);
      const result = reconcileAll(file, { prune: !!opts.prune });
      if (opts.json) {
        output(result, opts);
        return;
      }
      const lines: string[] = [];
      for (const a of result.agents) {
        const repoNote = a.repos
          .map((r) => `${r.name}${r.worktreeCreated ? " (worktree+)" : ""}`)
          .join(", ");
        lines.push(`${a.slug}: ${a.launch.action} [${repoNote}]`);
      }
      if (result.pruned.length) lines.push(`pruned: ${result.pruned.join(", ")}`);
      output(lines.join("\n") || "no agents configured", opts);
    } catch (e) {
      process.stderr.write(`Error: ${(e as Error).message}\n`);
      process.exit(1);
    }
  });

// ── kanban hooks install ─────────────────────────────────────────────

const hooksCmd = program.command("hooks").description("Manage Claude Code hooks for headless operation");
hooksCmd
  .command("install")
  .description("Install the Kanban hook + statusline scripts and register them in Claude settings")
  .option("-j, --json", "Output as JSON")
  .action((opts) => {
    try {
      const result = installHooks();
      output(
        opts.json
          ? result
          : `Installed hooks (${result.events.join(", ")})\n  hook:       ${result.hookScriptPath}\n  statusline: ${result.statuslinePath}\n  settings:   ${result.settingsPath}`,
        opts
      );
    } catch (e) {
      process.stderr.write(`Error: ${(e as Error).message}\n`);
      process.exit(1);
    }
  });

// ── kanban daemon ────────────────────────────────────────────────────

program
  .command("daemon")
  .description("Run the headless engine: auto-send queued prompts on Stop, auto-compact long sessions")
  .option("--poll-interval <ms>", "Auto-compact poll interval in ms", "30000")
  .option("--no-self-compact", "Disable auto-compaction")
  .action((opts) => {
    const daemon = new Daemon({
      pollIntervalMs: parseInt(opts.pollInterval, 10),
      selfCompact: { enabled: opts.selfCompact },
      announce: process.env.SLACK_BOT_TOKEN
        ? (slug, text) => {
            void announceToSlack(slug, text);
          }
        : undefined,
    });
    daemon.start();
    process.stdout.write(
      `kanban daemon started (poll ${opts.pollInterval}ms, self-compact ${opts.selfCompact ? "on" : "off"})\n`
    );
    const shutdown = () => {
      daemon.stop();
      process.exit(0);
    };
    process.on("SIGINT", shutdown);
    process.on("SIGTERM", shutdown);
  });

// ── kanban slack ─────────────────────────────────────────────────────

const slackCmd = program.command("slack").description("Slack bridge for observing and steering agents");
slackCmd
  .command("manifest")
  .description("Print a Slack app manifest (Socket Mode) plus setup instructions")
  .action(() => {
    process.stdout.write(slackAppManifest() + "\n# ---\n" + MANIFEST_INSTRUCTIONS + "\n");
  });
slackCmd
  .command("bridge")
  .description("Run the bidirectional Slack <-> agent bridge (needs SLACK_BOT_TOKEN and SLACK_APP_TOKEN)")
  .option(
    "--config <path>",
    "Path to agents.yaml",
    process.env.KANBAN_AGENTS_CONFIG || join(homedir(), ".kanban-code", "agents.yaml")
  )
  .action(async (opts) => {
    const botToken = process.env.SLACK_BOT_TOKEN;
    const appToken = process.env.SLACK_APP_TOKEN;
    if (!botToken || !appToken) {
      process.stderr.write("Error: SLACK_BOT_TOKEN and SLACK_APP_TOKEN must be set\n");
      process.exit(1);
    }
    await runSlackBridge({ botToken, appToken, configPath: opts.config });
  });
slackCmd
  .command("post")
  .description("Post a message to a Slack channel as the bot (needs SLACK_BOT_TOKEN)")
  .argument("<channel>", "Channel name (e.g. #dev) or id")
  .argument("<message>", "Message text (Slack mrkdwn)")
  .option("-j, --json", "Output as JSON")
  .action(async (channel: string, message: string, opts) => {
    const token = process.env.SLACK_BOT_TOKEN;
    if (!token) {
      process.stderr.write("Error: SLACK_BOT_TOKEN must be set\n");
      process.exit(1);
    }
    const result = await postToSlack(new SlackClient(token), channel, message);
    if (opts.json) {
      output(result, { json: true });
      if (!result.ok) process.exit(1);
      return;
    }
    if (result.ok) {
      process.stdout.write(`Posted to ${channel} (${result.channelId})\n`);
    } else {
      process.stderr.write(`Failed to post to ${channel}: ${result.error}\n`);
      if (String(result.error).includes("not_in_channel")) {
        process.stderr.write("The bot is not a member of that channel — invite it there first.\n");
      }
      process.exit(1);
    }
  });

// ── kanban self-compact [follow-up] ─────────────────────────────────

async function readStdinText(label: string): Promise<string> {
  const chunks: Buffer[] = [];
  try {
    for await (const chunk of process.stdin) {
      chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
    }
  } catch (error) {
    throw new Error(`Failed to read ${label} from stdin: ${String(error)}`);
  }
  return Buffer.concat(chunks).toString("utf-8").trimEnd();
}

async function readFollowUpFromArgsOrStdin(args: string[]): Promise<string> {
  const explicitStdin = args.length === 1 && args[0] === "-";
  if (args.length > 0 && !explicitStdin) return args.join(" ");
  if (process.stdin.isTTY) {
    if (explicitStdin) throw new Error("Expected a post-compact prompt on stdin after `-`, but stdin is a terminal.");
    return "";
  }
  const followUp = await readStdinText("post-compact prompt");
  if (explicitStdin && !followUp.trim()) {
    throw new Error("Expected a post-compact prompt on stdin after `-`, but stdin was empty.");
  }
  return followUp;
}

async function readMessageFromArgsOrStdin(args: string[]): Promise<string> {
  const explicitStdin = args.length === 1 && args[0] === "-";
  if (args.length > 0 && !explicitStdin) {
    return args.join(" ");
  }
  if (process.stdin.isTTY) {
    if (explicitStdin) throw new Error("Expected a message on stdin after `-`, but stdin is a terminal.");
    return "";
  }
  const message = await readStdinText("message");
  if (explicitStdin && !message.trim()) {
    throw new Error("Expected a message on stdin after `-`, but stdin was empty.");
  }
  return message;
}

async function readSubagentPromptFromArgsOrStdin(args: string[]): Promise<string> {
  if (args.length > 0 && !(args.length === 1 && args[0] === "-")) {
    return resolveSubagentPrompt(args, "");
  }
  if (process.stdin.isTTY) return resolveSubagentPrompt(args, "");
  return resolveSubagentPrompt(args, await readStdinText("subagent goal"));
}

function selfCompactTarget(): { card: Link; tmuxSession: string } {
  const tmuxSession = currentTmuxSessionName();
  if (!tmuxSession) {
    throw new Error(
      "Could not detect the current tmux session. `kanban self-compact` must be executed by an agent running inside a tmux session on a Kanban Code card."
    );
  }

  const links = readLinks();
  const card = cardForTmuxSession(links, tmuxSession);
  if (card) {
    if (card.tmuxLink?.sessionName !== tmuxSession) {
      throw new Error(
        `Tmux session "${tmuxSession}" is an extra terminal for card ${card.id}, not the card's assistant session. Run this from the agent's primary tmux session.`
      );
    }
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
  .option("--follow-up-delay <seconds>", "Seconds to wait after /compact before sending the follow-up", "1")
  .option("-j, --json", "Output as JSON")
  .argument("[followUp...]", "Optional post-compact prompt. Quote it, or pass - with piped/heredoc stdin.")
  .addHelpText(
    "after",
    `

Examples:
  kanban self-compact "After compacting, continue with the test run."
  kanban self-compact - <<'EOL'
  After compacting:
  1. Re-read the failing test output.
  2. Continue from the current plan.
  EOL
`
  )
  .action(async (followUpArgs: string[], opts) => {
    try {
      // Consume a pipe before running tmux subprocesses. Claude's Bash tool can
      // expose stdin as a nonblocking pipe, where readFileSync may race the
      // heredoc writer and throw EAGAIN. Awaiting the stream preserves the full
      // handoff instead of silently turning a transient read into no follow-up.
      const followUp = await readFollowUpFromArgsOrStdin(followUpArgs);
      const { card, tmuxSession } = selfCompactTarget();
      const followUpDelay = Number.parseFloat(opts.followUpDelay);

      // This command is normally launched from Claude Code's own Bash tool.
      // Sending keys to that same pane interrupts the tool, so the entire
      // sequence must be detached before touching the pane. Otherwise `/compact`
      // can be pasted but the later Enter/follow-up steps never run.
      assertTmuxResult(
        "schedule self-compact",
        scheduleTmuxSelfCompact(tmuxSession, followUp, Number.isFinite(followUpDelay) ? followUpDelay : 1)
      );

      // Surface the compact in Slack — the bridge's buffer-until-next-text
      // would otherwise hold the agent's "I'm compacting" Bash tool entry
      // until the post-compact session produces a fresh text post, leaving
      // the channel silent for the entire compact + warm-up window. Also
      // opens a new thread anchor for the resumed session and lights the
      // pill so the post-compact tool calls don't end up under a stale
      // pre-compact thread. Fire-and-forget; the CLI exits when scheduling
      // is done, the announce flushes in the background.
      const announceText = followUp.trim()
        ? `:arrows_counterclockwise: Self-compact triggered — context refresh, resuming with: _${followUp.trim()}_`
        : ":arrows_counterclockwise: Self-compact triggered — context refresh in progress.";
      void announceRawToSlack(tmuxSession, announceText);

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
    const active = filterActiveCards(links).filter((link) => !link.parentCardId);

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
    // `--as` is a handle override, not a request to become a userlike
    // participant. When an agent runs inside its Kanban tmux session, preserve
    // that card identity so channel fanout and mention navigation keep working.
    const session = currentTmuxSessionName();
    if (session) {
      const card = cardForTmuxSession(links, session);
      if (card) return { cardId: card.id, handle };
    }
    // Outside tmux, prefer an existing channel member for this handle so
    // helper scripts can keep posting as the same card-backed participant.
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

function cardParticipant(card: Link): { cardId: string; handle: string } {
  for (const channel of listChannels()) {
    const member = channel.members.find((candidate) => candidate.cardId === card.id);
    if (member) return { cardId: card.id, handle: member.handle };
  }
  return { cardId: card.id, handle: deriveHandle(card.name ?? card.id, new Set()) };
}

function requireSubagentTarget(caller: Link, query: string, links: Link[]): Link {
  const target = findCard(links, query);
  if (!target) throw new Error(`Subagent card not found: ${query}`);
  assertOwnedSubagent(caller, target, links);
  return target;
}

function requestedAssistant(raw: string): CodingAssistant | undefined {
  if (raw === "inherit") return undefined;
  if (raw === "claude" || raw === "codex" || raw === "gemini") return raw;
  throw new Error(`Unknown assistant "${raw}". Use inherit, claude, codex, or gemini.`);
}

async function runSubagentCreate(
  operation: "spawn" | "fork",
  promptArgs: string[],
  opts: {
    assistant: string;
    handle?: string;
    model?: string;
    contextThreshold?: string;
    from?: string;
    json?: boolean;
  }
): Promise<void> {
  const links = readLinks();
  const parent = currentCardOrThrow(links);
  validateCanSpawn(parent, links);
  if (!opts.handle?.trim()) throw new Error(missingHandleError);
  const handle = normalizeSubagentHandle(opts.handle);
  // A fork copies a transcript, so it may start from this card or from any
  // subagent this card already owns. Either way the new card belongs to the
  // caller, so forking a child produces a sibling rather than a grandchild.
  const source = operation === "fork" && opts.from
    ? requireSubagentTarget(parent, opts.from, links)
    : parent;
  if (operation === "fork" && !source.sessionLink?.sessionPath) {
    throw new Error(missingForkSessionError(source.id));
  }
  const prompt = await readSubagentPromptFromArgsOrStdin(promptArgs);
  if (!prompt.trim()) {
    throw new Error("A subagent goal is required. Pass it as arguments or use `-` with stdin.");
  }
  const contextThresholdTokens = opts.contextThreshold === undefined
    ? undefined
    : parseContextThreshold(opts.contextThreshold);
  const assistantOverride = requestedAssistant(opts.assistant);
  const targetAssistant = assistantOverride ?? source.assistant ?? "claude";
  if (contextThresholdTokens !== undefined && targetAssistant !== "claude") {
    throw new Error("Per-card context thresholds are currently available for Claude subagents only.");
  }
  const request = makeSubagentRequest(operation, parent.id, {
    sourceCardId: source.id === parent.id ? undefined : source.id,
    name: handle,
    prompt: buildSubagentPrompt(parent, prompt, contextThresholdTokens, handle),
    assistant: assistantOverride,
    model: opts.model,
    contextThresholdTokens,
  });
  const response = await submitSubagentRequest(request);
  if (!response.ok) throw new Error(response.error ?? "Kanban Code rejected the subagent command.");
  if (opts.json) {
    output(response, { json: true });
  } else {
    console.log(`${operation === "spawn" ? "Spawned" : "Forked"} subagent ${response.cardId}`);
  }
}

const subagentCmd = program
  .command("subagent")
  .description("Create and manage child card sessions owned by the current Kanban Code card")
  .addHelpText(
    "after",
    `

Subagents are normal Kanban Code cards with their own tmux session, transcript,
auto-compact protection, and assistant. Commands must run from the parent card's
primary tmux session.

Every child needs --handle, which becomes its card name and its @handle in chat,
so DMs read as @parser-bug instead of a slug of the first line of the goal.
Use a quoted argument for short goals, or stdin for long goals:

  kanban subagent spawn --handle parser-bug - <<'EOF'
  Investigate the failing integration test.
  Report the root cause and a tested fix.
  EOF

Use --context-threshold 250k for a Claude child to override global compaction.
It gets a queued nudge at 250k, a steered reminder at 350k, and an interrupt with
/compact at 450k.

Fork copies a transcript into a new child. Without --from it copies this card;
with --from it copies one of your own subagents so the same work can continue
in another direction, and the copy becomes that subagent's sibling:

  kanban subagent fork --from card_abc123 --handle cache-path "try the cache path"

Parent management aliases are guarded so they only target owned descendants:
  kanban subagent capture|transcript|dm|send <card-id> ...

The low-level send alias is intended for assistant commands such as /compact.
`
  );

for (const operation of ["spawn", "fork"] as const) {
  const command = subagentCmd
    .command(operation)
    .description(
      operation === "spawn"
        ? "Start a new child session"
        : "Fork this card or an owned subagent into a new child, migrating when the assistant changes"
    )
    .argument("[prompt...]", "Goal text, or pass - and pipe/heredoc stdin");
  if (operation === "fork") {
    command.option(
      "--from <card>",
      "Fork an owned subagent instead of this card; the copy becomes its sibling"
    );
  }
  command
    .requiredOption("--handle <handle>", "Short chat handle and card name for the child, e.g. parser-bug")
    .option("--assistant <assistant>", "inherit, claude, codex, or gemini", "inherit")
    .option("--model <model>", "Assistant model alias or full model name")
    .option("--context-threshold <tokens>", "Claude card self-compact nudge threshold, e.g. 250k or 250000")
    .option("-j, --json", "Output as JSON")
    .action(async (prompt: string[], opts) => {
      try {
        await runSubagentCreate(operation, prompt, opts);
      } catch (error) {
        console.error(String(error instanceof Error ? error.message : error));
        process.exitCode = 1;
      }
    });
}

subagentCmd
  .command("list")
  .alias("ls")
  .description("List active and archived descendants with context usage and live pane peeks")
  .option("--no-capture-peek", "Do not include the live tmux pane preview")
  .option("-j, --json", "Output as JSON")
  .action((opts) => {
    try {
      const links = readLinks();
      const parent = currentCardOrThrow(links);
      const ids = descendantIds(parent.id, links);
      const rows = links
        .filter((link) => ids.has(link.id))
        .sort((a, b) => (b.lastActivity ?? b.updatedAt).localeCompare(a.lastActivity ?? a.updatedAt));
      const live = liveTmuxSet();
      const summaries = rows.map((card) => {
        const summary = toCardSummary(card, live);
        summary.subagentDepth = subagentDepth(card.id, links);
        const session = card.tmuxLink?.sessionName;
        if (opts.capturePeek !== false && session && live.has(session)) {
          const peek = peekTmuxPane(session, 15);
          if (peek.trim()) summary.peek = peek;
        }
        return summary;
      });
      if (opts.json) {
        output(summaries, { json: true });
        return;
      }
      const byId = new Map(summaries.map((summary) => [summary.id, summary]));
      const printGroup = (title: string, cards: Link[]) => {
        console.log(`${title} (${cards.length})`);
        if (cards.length === 0) console.log("  none");
        for (const card of cards) {
          const summary = byId.get(card.id);
          if (summary) console.log(formatCardSummary(summary));
        }
      };
      const archived = rows.filter((card) => card.manuallyArchived);
      printGroup("Active", rows.filter((card) => !archived.includes(card)));
      console.log("");
      printGroup("Archived", archived);
    } catch (error) {
      console.error(String(error instanceof Error ? error.message : error));
      process.exitCode = 1;
    }
  });

for (const operation of ["archive", "resume"] as const) {
  subagentCmd
    .command(operation)
    .description(`${operation === "archive" ? "Archive" : "Resume"} an owned subagent card`)
    .argument("<card>", "Owned subagent card ID, prefix, or name")
    .option("-j, --json", "Output as JSON")
    .action(async (query: string, opts) => {
      try {
        const links = readLinks();
        const parent = currentCardOrThrow(links);
        const target = requireSubagentTarget(parent, query, links);
        const response = await submitSubagentRequest(
          makeSubagentRequest(operation, parent.id, { cardId: target.id })
        );
        if (!response.ok) throw new Error(response.error ?? "Kanban Code rejected the command.");
        if (opts.json) output(response, { json: true });
        else console.log(`${operation === "archive" ? "Archived" : "Resumed"} ${target.id}`);
      } catch (error) {
        console.error(String(error instanceof Error ? error.message : error));
        process.exitCode = 1;
      }
    });
}

subagentCmd
  .command("capture")
  .description("Capture an owned subagent's visible tmux pane")
  .argument("<card>", "Owned subagent card")
  .option("-s, --scrollback <lines>", "Include N lines, or all")
  .action((query: string, opts) => {
    try {
      const links = readLinks();
      const caller = currentCardOrThrow(links);
      const target = requireSubagentTarget(caller, query, links);
      const session = target.tmuxLink?.sessionName;
      if (!session) throw new Error(`Subagent ${target.id} has no tmux session.`);
      const scrollback = opts.scrollback === "all" ? "all" : Number.parseInt(opts.scrollback ?? "0", 10);
      output(captureTmuxPane(session, scrollback), { json: false });
    } catch (error) {
      console.error(String(error instanceof Error ? error.message : error));
      process.exitCode = 1;
    }
  });

subagentCmd
  .command("transcript")
  .description("Read recent conversation turns from an owned subagent")
  .argument("<card>", "Owned subagent card")
  .option("-n, --tail <turns>", "Number of turns", "50")
  .option("-j, --json", "Output as JSON")
  .action((query: string, opts) => {
    try {
      const links = readLinks();
      const caller = currentCardOrThrow(links);
      const target = requireSubagentTarget(caller, query, links);
      const path = target.sessionLink?.sessionPath;
      if (!path) throw new Error(`Subagent ${target.id} has no transcript path.`);
      const turns = readLastTranscriptTurns(path, Math.max(1, Number.parseInt(opts.tail, 10) || 50));
      if (opts.json) output(turns, { json: true });
      else for (const turn of turns) console.log(`${turn.role}: ${turn.text}\n`);
    } catch (error) {
      console.error(String(error instanceof Error ? error.message : error));
      process.exitCode = 1;
    }
  });

subagentCmd
  .command("send")
  .description("Low-level: deliver a message directly into an owned subagent's session")
  .argument("<card>", "Owned subagent card")
  .argument("<message...>", "Message or assistant command")
  .option(
    "--mode <mode>",
    "steer (paste now, read between turns), queue (wait for the agent to go idle), or interrupt (Escape first, then send)",
    "steer"
  )
  .option("--keys", "Use send-keys instead of paste-buffer for a short single-line command")
  .option("-j, --json", "Output as JSON")
  .action(async (query: string, message: string[], opts) => {
    try {
      const mode = parseDeliveryMode(opts.mode);
      const links = readLinks();
      const caller = currentCardOrThrow(links);
      const target = requireSubagentTarget(caller, query, links);
      const body = await readMessageFromArgsOrStdin(message);
      if (mode === "queue") {
        await queuePromptForCard(target, body, { json: opts.json });
        return;
      }
      const session = target.tmuxLink?.sessionName;
      if (!session) throw new Error(`Subagent ${target.id} has no tmux session.`);
      const send = opts.keys ? sendTmuxKeys : pasteTmuxPrompt;
      const result = mode === "interrupt"
        ? interruptTmuxPrompt(session, body, send)
        : send(session, body);
      if (!result.ok) throw new Error(result.error ?? "tmux paste failed");
      if (opts.json) output({ cardId: target.id, mode, sent: true }, { json: true });
      else console.log(`Sent to ${target.id}`);
    } catch (error) {
      console.error(String(error instanceof Error ? error.message : error));
      process.exitCode = 1;
    }
  });

/**
 * Answer the assistant's "switch model?" dialog by taking its default option.
 * Returns false when a dialog is still on screen afterwards, so the caller can
 * say so rather than reporting a switch that never happened.
 */
async function acceptModelSwitchConfirmation(session: string): Promise<boolean> {
  for (let attempt = 0; attempt < 12; attempt++) {
    await new Promise((resolve) => setTimeout(resolve, 500));
    const pane = captureTmuxPane(session);
    if (!needsModelSwitchConfirmation(pane)) {
      // No dialog on the first look means the assistant applied it directly.
      if (attempt > 0) return true;
      continue;
    }
    sendTmuxEnter(session);
    await new Promise((resolve) => setTimeout(resolve, 800));
    return !needsModelSwitchConfirmation(captureTmuxPane(session));
  }
  return true;
}

subagentCmd
  .command("model")
  .description("Switch an owned subagent to another model")
  .argument("<card>", "Owned subagent card")
  .argument("<model>", "Model alias, e.g. opus, sonnet, or gpt-5")
  .option("-j, --json", "Output as JSON")
  .action(async (query: string, model: string, opts) => {
    try {
      const links = readLinks();
      const caller = currentCardOrThrow(links);
      const target = requireSubagentTarget(caller, query, links);
      const session = target.tmuxLink?.sessionName;
      if (!session) throw new Error(`Subagent ${target.id} has no tmux session.`);

      const assistant = target.assistant ?? "claude";
      const direct = appliesModelSwitchDirectly(assistant);
      const command = modelSwitchCommand(model, assistant);
      const result = pasteTmuxPrompt(session, command);
      if (!result.ok) throw new Error(result.error ?? "tmux paste failed");

      // Switching mid-conversation costs the prompt cache, so the assistant asks
      // first and leaves the card parked on a dialog until someone answers.
      const applied = direct && (await acceptModelSwitchConfirmation(session));

      // The slash command only changes the running turn, so record the switch
      // too or a later resume relaunches the card on the old model.
      if (applied && kanbanCodeIsRunning()) {
        const response = await submitSubagentRequest(
          makeSubagentRequest("setModel", caller.id, { cardId: target.id, model: model.trim() })
        );
        if (!response.ok) throw new Error(response.error ?? "unknown error");
      }

      // Assistants disagree on how `/model` behaves, so hand back the pane
      // instead of claiming it worked.
      const pane = peekTmuxPane(session, 12);
      if (opts.json) output({ cardId: target.id, command, applied, pane }, { json: true });
      else {
        console.log(`Sent ${command} to ${target.id}`);
        if (!direct) {
          console.log(
            `${assistant} takes no model name on /model, so its picker is now open. ` +
            `Choose ${model.trim()} there, for example with \`kanban subagent send ${target.id} --keys 2\`.`
          );
        } else if (!applied) {
          console.log("The assistant is still showing a prompt; check the pane below.");
        }
        console.log(pane);
      }
    } catch (error) {
      console.error(String(error instanceof Error ? error.message : error));
      process.exitCode = 1;
    }
  });

subagentCmd
  .command("context-threshold")
  .alias("compact-at")
  .description("Retune an owned subagent's self-compact threshold as its task grows or shrinks")
  .argument("<card>", "Owned subagent card")
  .argument("<tokens>", "Nudge threshold, e.g. 300k or 300000, or `global` to follow the app settings")
  .option("-j, --json", "Output as JSON")
  .action(async (query: string, tokens: string, opts) => {
    try {
      const links = readLinks();
      const caller = currentCardOrThrow(links);
      const target = requireSubagentTarget(caller, query, links);
      const followGlobal = /^(global|default|none)$/i.test(tokens.trim());
      const contextThresholdTokens = followGlobal ? undefined : parseContextThreshold(tokens);

      const response = await submitSubagentRequest(
        makeSubagentRequest("setContextThreshold", caller.id, {
          cardId: target.id,
          contextThresholdTokens,
        })
      );
      if (!response.ok) throw new Error(response.error ?? "unknown error");

      const rules = contextThresholdTokens ? cardSelfCompactRules(contextThresholdTokens) : [];
      if (opts.json) {
        output({ cardId: target.id, contextThresholdTokens: contextThresholdTokens ?? null, rules }, { json: true });
      } else if (followGlobal) {
        console.log(`${target.id} now follows the global self-compact settings`);
      } else {
        const [nudge, steer, force] = rules;
        console.log(
          `${target.id} nudges at ${tokenLabel(nudge.thresholdTokens)}, ` +
          `steers at ${tokenLabel(steer.thresholdTokens)}, ` +
          `and is interrupted at ${tokenLabel(force.thresholdTokens)}`
        );
      }
    } catch (error) {
      console.error(String(error instanceof Error ? error.message : error));
      process.exitCode = 1;
    }
  });

subagentCmd
  .command("dm")
  .description("Send a private message to an owned subagent")
  .argument("<card>", "Owned subagent card")
  .argument("<message...>", "Message body")
  .action(async (query: string, message: string[]) => {
    try {
      const links = readLinks();
      const caller = currentCardOrThrow(links);
      const target = requireSubagentTarget(caller, query, links);
      const result = sendDirectMessage(
        cardParticipant(caller),
        cardParticipant(target),
        await readMessageFromArgsOrStdin(message),
        links,
        undefined,
        { liveSessionProbe: (session) => liveTmuxSet().has(session) }
      );
      if (!result.delivered) throw new Error(result.error ?? "message was not delivered");
      console.log(`DM delivered to ${target.id}`);
    } catch (error) {
      console.error(String(error instanceof Error ? error.message : error));
      process.exitCode = 1;
    }
  });

async function sendToParent(messageArgs: string[]): Promise<{ child: Link; parent: Link; body: string }> {
  const links = readLinks();
  const child = currentCardOrThrow(links);
  if (!child.parentCardId) throw new Error(`Card ${child.id} is not a subagent.`);
  const parent = links.find((link) => link.id === child.parentCardId);
  if (!parent) throw new Error(`Parent card ${child.parentCardId} no longer exists.`);
  const body = await readMessageFromArgsOrStdin(messageArgs);
  if (!body.trim()) throw new Error("A parent message is required.");
  const result = sendDirectMessage(
    cardParticipant(child),
    cardParticipant(parent),
    body,
    links,
    undefined,
    { liveSessionProbe: (session) => liveTmuxSet().has(session) }
  );
  if (!result.delivered) throw new Error(result.error ?? "message was not delivered");
  return { child, parent, body };
}

const parentCmd = program
  .command("parent")
  .description("Report from a subagent to its owning parent card");

parentCmd
  .command("dm")
  .description("Send a private progress or result message to the parent")
  .argument("<message...>", "Message body, or - with stdin")
  .action(async (message: string[]) => {
    try {
      const { parent } = await sendToParent(message);
      console.log(`DM delivered to parent ${parent.id}`);
    } catch (error) {
      console.error(String(error instanceof Error ? error.message : error));
      process.exitCode = 1;
    }
  });

parentCmd
  .command("dm-and-self-archive")
  .description("Report a completed goal to the parent, then archive this subagent")
  .argument("<message...>", "Completion message, or - with stdin")
  .action(async (message: string[]) => {
    try {
      const { child, parent } = await sendToParent(message);
      console.log(`DM delivered to parent ${parent.id}; archiving ${child.id}`);
      const response = await submitSubagentRequest(
        makeSubagentRequest("archive", parent.id, { cardId: child.id })
      );
      if (!response.ok) throw new Error(response.error ?? "Kanban Code could not archive this subagent.");
    } catch (error) {
      console.error(String(error instanceof Error ? error.message : error));
      process.exitCode = 1;
    }
  });

const channelCmd = program.command("channel").description(
  "Shared channel chat for room-visible agent updates; use `kanban channel --help`"
);

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
  .description("Send a room-visible message to a channel (broadcasts to all members)")
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
  .description("Delete a channel and its history log")
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

const dmCmd = program.command("dm").description("Send/read direct messages between agents (private, not channel chat)");

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

sortTopLevelCommands([
  "open",
  "list",
  "show",
  "sessions",
  "capture",
  "channel",
  "dm",
  "subagent",
  "parent",
  "send",
]);

await program.parseAsync();
