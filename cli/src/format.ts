import { CardSummary, CardDetail, KanbanColumn, TmuxSession } from "./types.js";

// ── Column display ───────────────────────────────────────────────────

const COLUMN_LABELS: Record<KanbanColumn, string> = {
  in_progress: "In Progress",
  requires_attention: "Waiting / Needs Attention",
  in_review: "In Review",
  backlog: "Backlog",
  done: "Done",
  all_sessions: "All Sessions",
};

const COLUMN_ORDER: KanbanColumn[] = [
  "in_progress",
  "requires_attention",
  "in_review",
  "done",
  "backlog",
];

function fmtTokens(n: number): string {
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`;
  if (n >= 1_000) return `${(n / 1_000).toFixed(0)}k`;
  return `${n}`;
}

// ── Pretty formatting ────────────────────────────────────────────────

export function formatCardList(cards: CardSummary[]): string {
  if (!cards.length) return "No cards found.";

  // Group by column
  const grouped = new Map<KanbanColumn, CardSummary[]>();
  for (const card of cards) {
    const list = grouped.get(card.column) || [];
    list.push(card);
    grouped.set(card.column, list);
  }

  const lines: string[] = [];
  for (const col of COLUMN_ORDER) {
    const colCards = grouped.get(col);
    if (!colCards?.length) continue;

    lines.push("");
    lines.push(`=== ${COLUMN_LABELS[col]} (${colCards.length}) ===`);
    lines.push("");

    for (const card of colCards) {
      lines.push(formatCardSummary(card));
    }
  }

  return lines.join("\n");
}

export function formatCardSummary(card: CardSummary): string {
  const parts: string[] = [];

  // Status indicator
  const indicator = card.tmuxAlive ? "\u25cf" : "\u25cb"; // filled/empty circle
  parts.push(`  ${indicator} ${card.name}`);

  // Metadata line
  const meta: string[] = [];
  if (card.subagentDepth !== undefined) meta.push(`depth:${card.subagentDepth}`);
  if (card.assistant) meta.push(card.assistant);
  if (card.modelOverride) meta.push(`model:${card.modelOverride}`);
  if (card.selfCompactContextThresholdTokens) {
    meta.push(`compact:${formatCompactThreshold(card.selfCompactContextThresholdTokens)}`);
  }
  if (card.project) meta.push(card.project);
  if (card.tmuxSession) {
    meta.push(`tmux:${card.tmuxSession}${card.tmuxAlive ? "" : " (dead)"}`);
  }
  if (card.branch) meta.push(`branch:${card.branch}`);
  for (const pr of card.prs) {
    meta.push(`PR#${pr.number}${pr.status ? `(${pr.status})` : ""}`);
  }
  if (card.queuedPrompts > 0) meta.push(`${card.queuedPrompts} queued`);
  if (card.tokens) {
    const t = card.tokens;
    meta.push(`${fmtTokens(t.input + t.output)} tok $${t.cost.toFixed(2)}`);
    if (t.context.used > 0) meta.push(`${fmtTokens(t.context.used)}/${fmtTokens(t.context.max)} ctx (${t.context.percentage})`);
  }
  if (card.isRemote) meta.push("remote");

  if (meta.length) {
    parts.push(`    ${meta.join(" | ")}`);
  }

  // Card ID
  parts.push(`    ${card.id}`);

  // Block content (last message, peek) — rendered below the card, indented,
  // with blank line separators to make cards easy to scan.
  const hasBlock = card.lastMessage || card.peek;
  if (card.lastMessage) {
    parts.push("");
    parts.push(`    Last message:`);
    for (const line of card.lastMessage.split("\n").slice(0, 10)) {
      parts.push(`      ${line}`);
    }
  }
  if (card.peek) {
    parts.push("");
    parts.push(`    Pane peek:`);
    for (const line of card.peek.split("\n")) {
      parts.push(`      ${line}`);
    }
  }
  if (hasBlock) parts.push("");

  return parts.join("\n");
}

function formatCompactThreshold(tokens: number): string {
  return tokens % 1_000 === 0 ? `${tokens / 1_000}k` : String(tokens);
}

export function formatCardDetail(card: CardDetail): string {
  const lines: string[] = [];

  lines.push(`Card: ${card.name}`);
  lines.push(`ID: ${card.id}`);
  lines.push(`Column: ${COLUMN_LABELS[card.column] || card.column}`);
  if (card.project) lines.push(`Project: ${card.project}`);
  if (card.assistant) lines.push(`Assistant: ${card.assistant}`);
  if (card.isRemote) lines.push(`Remote: yes`);
  if (card.tokens) {
    const t = card.tokens;
    lines.push(
      `Tokens: ${fmtTokens(t.input)} in / ${fmtTokens(t.output)} out — $${t.cost.toFixed(2)} | Context: ${fmtTokens(t.context.used)}/${fmtTokens(t.context.max)} (${t.context.percentage})${t.model ? ` [${t.model}]` : ""}`
    );
  }
  lines.push("");

  // Session
  if (card.sessionId) {
    lines.push(`--- Session ---`);
    lines.push(`  ID: ${card.sessionId}`);
    if (card.sessionPath) lines.push(`  Path: ${card.sessionPath}`);
    lines.push("");
  }

  // Tmux
  if (card.tmuxSession) {
    lines.push(`--- Terminal ---`);
    lines.push(
      `  Primary: ${card.tmuxSession} ${card.tmuxAlive ? "(alive)" : "(dead)"}`
    );
    for (const extra of card.extraTmuxSessions) {
      lines.push(`  Extra: ${extra}`);
    }
    lines.push("");
  }

  // Worktree
  if (card.worktree) {
    lines.push(`--- Worktree ---`);
    lines.push(`  Path: ${card.worktree}`);
    if (card.branch) lines.push(`  Branch: ${card.branch}`);
    lines.push("");
  }

  // PRs
  if (card.prDetails.length) {
    lines.push(`--- Pull Requests ---`);
    for (const pr of card.prDetails) {
      lines.push(
        `  #${pr.number} ${pr.title || ""} [${pr.status || "unknown"}]`
      );
      if (pr.url) lines.push(`    ${pr.url}`);
      if (pr.unresolvedThreads)
        lines.push(`    Unresolved threads: ${pr.unresolvedThreads}`);
      if (pr.mergeStateStatus)
        lines.push(`    Merge state: ${pr.mergeStateStatus}`);
    }
    lines.push("");
  }

  // Issue
  if (card.issueLink) {
    lines.push(`--- Issue ---`);
    lines.push(`  #${card.issueLink.number} ${card.issueLink.title || ""}`);
    if (card.issueLink.url) lines.push(`  ${card.issueLink.url}`);
    lines.push("");
  }

  // Queued prompts
  if (card.queuedPromptBodies.length) {
    lines.push(`--- Queued Prompts (${card.queuedPromptBodies.length}) ---`);
    for (const qp of card.queuedPromptBodies) {
      const auto = qp.sendAutomatically ? " [auto]" : "";
      lines.push(`  ${qp.body.slice(0, 80)}${auto}`);
    }
    lines.push("");
  }

  // Prompt body
  if (card.promptBody) {
    lines.push(`--- Initial Prompt ---`);
    lines.push(card.promptBody);
    lines.push("");
  }

  // Transcript
  if (card.transcript?.length) {
    lines.push(`--- Recent Transcript ---`);
    for (const turn of card.transcript) {
      const prefix = turn.role === "user" ? "YOU" : "AI";
      lines.push(`  [${prefix}] ${turn.text.slice(0, 200)}`);
    }
    lines.push("");
  }

  return lines.join("\n");
}

export function formatTmuxSessions(sessions: TmuxSession[]): string {
  if (!sessions.length) return "No tmux sessions running.";
  const lines = ["Tmux Sessions:", ""];
  for (const s of sessions) {
    const att = s.attached ? " (attached)" : "";
    lines.push(`  ${s.name}${att}`);
    if (s.path) lines.push(`    path: ${s.path}`);
  }
  return lines.join("\n");
}
