import { readFileSync, existsSync, statSync, openSync, readSync, closeSync, readdirSync } from "node:fs";
import { execSync, spawn } from "node:child_process";
import { homedir } from "node:os";
import { join, basename, matchesGlob } from "node:path";
import {
  Link,
  Settings,
  SessionContext,
  TmuxSession,
  CardSummary,
  CardDetail,
  TranscriptTurn,
  KanbanColumn,
} from "./types.js";
import { linksPath, settingsPath, contextDir, claudeProjectsDir } from "./paths.js";

// ── Reading state files ──────────────────────────────────────────────

export function readLinks(): Link[] {
  const path = linksPath();
  if (!existsSync(path)) return [];
  const raw = JSON.parse(readFileSync(path, "utf-8"));
  // Container format: { links: [...] }
  if (raw && Array.isArray(raw.links)) return raw.links;
  if (Array.isArray(raw)) return raw;
  return [];
}

export function readSettings(): Settings {
  const path = settingsPath();
  if (!existsSync(path))
    return { projects: [] };
  return JSON.parse(readFileSync(path, "utf-8"));
}

// ── Session context (tokens/cost) ────────────────────────────────────

export function readSessionContext(sessionId: string): SessionContext | undefined {
  const path = join(contextDir(), `${sessionId}.json`);
  if (!existsSync(path)) return undefined;
  try {
    return JSON.parse(readFileSync(path, "utf-8"));
  } catch {
    return undefined;
  }
}

// ── Tmux ─────────────────────────────────────────────────────────────

function findTmux(): string {
  try {
    return execSync("which tmux", { encoding: "utf-8" }).trim() || "tmux";
  } catch {
    return "tmux";
  }
}

export function listTmuxSessions(): TmuxSession[] {
  const tmux = findTmux();
  try {
    const out = execSync(
      `${tmux} list-sessions -F '#{session_name}\t#{session_path}\t#{session_attached}' 2>/dev/null`,
      { encoding: "utf-8" }
    );
    return out
      .trim()
      .split("\n")
      .filter(Boolean)
      .map((line) => {
        const [name, path, attached] = line.split("\t");
        return { name, path: path || "", attached: attached === "1" };
      });
  } catch {
    return [];
  }
}

/// Capture tmux pane output.
/// scrollback: 0 = visible pane only, N > 0 = include N lines of scrollback history,
/// "all" = entire scrollback buffer.
export function captureTmuxPane(
  sessionName: string,
  scrollback: number | "all" = 0
): string {
  const tmux = findTmux();
  const startFlag =
    scrollback === "all"
      ? "-S -"
      : scrollback > 0
        ? `-S -${scrollback}`
        : "";
  try {
    return execSync(
      `${tmux} capture-pane -t ${shellEscape(sessionName)} -p ${startFlag} 2>/dev/null`,
      { encoding: "utf-8" }
    );
  } catch {
    return "";
  }
}

/// Capture a short, content-rich peek at a card's session.
/// Skips Claude Code's UI chrome (input box, spinner, status line) and returns
/// the last N lines of actual content above it. Returns empty string if not a
/// Claude Code session or no useful content found.
export function peekTmuxPane(
  sessionName: string,
  contentLines: number = 15
): string {
  const tmux = findTmux();
  try {
    // Capture enough to skip chrome and have content left
    const raw = execSync(
      `${tmux} capture-pane -t ${shellEscape(sessionName)} -p -S -${contentLines + 20} 2>/dev/null`,
      { encoding: "utf-8" }
    );
    const lines = raw.split("\n");

    // Find the Claude Code input box (line of ─ characters containing the branch
    // pill) — that's where content ends and chrome begins. If not present,
    // assume this is a shell and return the last N non-empty lines.
    let inputBoxIdx = -1;
    for (let i = lines.length - 1; i >= 0; i--) {
      const line = lines[i];
      // The input box borders are made of ─ (U+2500)
      if (line.includes("─") && line.length > 40) {
        inputBoxIdx = i;
        break;
      }
    }

    let content: string[];
    if (inputBoxIdx > 0) {
      // Claude Code: take lines above the input box
      content = lines.slice(0, inputBoxIdx);
    } else {
      // Shell or unknown: take everything
      content = lines;
    }

    // Trim trailing blanks
    while (content.length && content[content.length - 1].trim() === "") {
      content.pop();
    }

    // Keep only the last N content lines
    return content.slice(-contentLines).join("\n");
  } catch {
    return "";
  }
}

export function sendTmuxKeys(
  sessionName: string,
  keys: string
): { ok: boolean; error?: string } {
  const tmux = findTmux();
  try {
    execSync(
      `${tmux} send-keys -t ${shellEscape(sessionName)} ${shellEscape(keys)} Enter`,
      { encoding: "utf-8" }
    );
    return { ok: true };
  } catch (e) {
    return { ok: false, error: String(e) };
  }
}

export function sendTmuxEnter(
  sessionName: string
): { ok: boolean; error?: string } {
  const tmux = findTmux();
  try {
    execSync(
      `${tmux} send-keys -t ${shellEscape(sessionName)} Enter`,
      { encoding: "utf-8" }
    );
    return { ok: true };
  } catch (e) {
    return { ok: false, error: String(e) };
  }
}

export function pasteTmuxPrompt(
  sessionName: string,
  text: string
): { ok: boolean; error?: string } {
  const tmux = findTmux();
  try {
    // Use tmux paste-buffer with bracketed paste for reliable multi-line input
    execSync(
      `${tmux} set-buffer ${shellEscape(text)} && ${tmux} paste-buffer -p -t ${shellEscape(sessionName)}`,
      { encoding: "utf-8" }
    );
    // Small delay before sending Enter, matching Swift implementation
    execSync("sleep 0.1");
    execSync(
      `${tmux} send-keys -t ${shellEscape(sessionName)} Enter`,
      { encoding: "utf-8" }
    );
    return { ok: true };
  } catch (e) {
    return { ok: false, error: String(e) };
  }
}

export function scheduleTmuxPrompt(
  sessionName: string,
  text: string,
  delaySeconds: number
): { ok: boolean; error?: string } {
  const tmux = findTmux();
  const delay = Math.max(0, Number.isFinite(delaySeconds) ? delaySeconds : 1);
  const cmd = [
    `sleep ${shellEscape(String(delay))}`,
    `${tmux} set-buffer ${shellEscape(text)}`,
    `${tmux} paste-buffer -p -t ${shellEscape(sessionName)}`,
    "sleep 0.1",
    `${tmux} send-keys -t ${shellEscape(sessionName)} Enter`,
  ].join(" && ");

  try {
    const child = spawn("sh", ["-c", cmd], {
      detached: true,
      stdio: "ignore",
      env: process.env,
    });
    child.unref();
    return { ok: true };
  } catch (e) {
    return { ok: false, error: String(e) };
  }
}

export function scheduleTmuxSelfCompact(
  sessionName: string,
  followUp: string,
  followUpDelaySeconds: number
): { ok: boolean; error?: string } {
  const tmux = findTmux();
  const delay = Math.max(0, Number.isFinite(followUpDelaySeconds) ? followUpDelaySeconds : 1);
  const compactSteps = [
    // Let the CLI return control to Claude Code before we start sending keys
    // to the same pane. Once this shell is detached, it survives Claude
    // interrupting the Bash tool that launched `kanban self-compact`.
    "sleep 0.1",
    `${tmux} send-keys -t ${shellEscape(sessionName)} Escape`,
    `${tmux} set-buffer ${shellEscape("/compact")}`,
    `${tmux} paste-buffer -p -t ${shellEscape(sessionName)}`,
    "sleep 0.15",
    `${tmux} send-keys -t ${shellEscape(sessionName)} Enter`,
  ];

  const followUpSteps = followUp.trim().length === 0
    ? []
    : [
        `sleep ${shellEscape(String(delay))}`,
        `${tmux} set-buffer ${shellEscape(followUp)}`,
        `${tmux} paste-buffer -p -t ${shellEscape(sessionName)}`,
        "sleep 0.1",
        `${tmux} send-keys -t ${shellEscape(sessionName)} Enter`,
      ];

  try {
    const child = spawn("sh", ["-c", [...compactSteps, ...followUpSteps].join(" && ")], {
      detached: true,
      stdio: "ignore",
      env: process.env,
    });
    child.unref();
    return { ok: true };
  } catch (e) {
    return { ok: false, error: String(e) };
  }
}

export function pasteTmuxText(
  sessionName: string,
  text: string
): { ok: boolean; error?: string } {
  const tmux = findTmux();
  try {
    execSync(
      `${tmux} set-buffer ${shellEscape(text)} && ${tmux} paste-buffer -p -t ${shellEscape(sessionName)}`,
      { encoding: "utf-8" }
    );
    return { ok: true };
  } catch (e) {
    return { ok: false, error: String(e) };
  }
}

export function sendTmuxEscape(
  sessionName: string
): { ok: boolean; error?: string } {
  const tmux = findTmux();
  try {
    execSync(
      `${tmux} send-keys -t ${shellEscape(sessionName)} Escape`,
      { encoding: "utf-8" }
    );
    return { ok: true };
  } catch (e) {
    return { ok: false, error: String(e) };
  }
}

// ── Tmux session lifecycle (headless agent launch/resume) ────────────

export function hasTmuxSession(name: string): boolean {
  const tmux = findTmux();
  try {
    execSync(`${tmux} has-session -t ${shellEscape(name)} 2>/dev/null`, {
      encoding: "utf-8",
    });
    return true;
  } catch {
    return false;
  }
}

/// Create a detached tmux session named `name` rooted at `cwd` and run
/// `command` in it. `env` entries are set on the session (and inherited by the
/// pane's shell) via tmux `-e`, avoiding fragile inline-shell quoting.
export function createTmuxSession(
  name: string,
  cwd: string,
  command: string,
  env: Record<string, string> = {}
): { ok: boolean; error?: string } {
  const tmux = findTmux();
  try {
    const envFlags = Object.entries(env)
      .map(([k, v]) => `-e ${shellEscape(`${k}=${v}`)}`)
      .join(" ");
    execSync(
      `${tmux} new-session -d -s ${shellEscape(name)} -c ${shellEscape(cwd)} ${envFlags}`,
      { encoding: "utf-8" }
    );
    // Let the pane's shell come up before sending the command.
    execSync("sleep 0.2");
    execSync(
      `${tmux} send-keys -t ${shellEscape(name)} ${shellEscape(command)} Enter`,
      { encoding: "utf-8" }
    );
    return { ok: true };
  } catch (e) {
    return { ok: false, error: String(e) };
  }
}

export function killTmuxSession(name: string): { ok: boolean; error?: string } {
  const tmux = findTmux();
  try {
    execSync(`${tmux} kill-session -t ${shellEscape(name)} 2>/dev/null`, {
      encoding: "utf-8",
    });
    return { ok: true };
  } catch (e) {
    return { ok: false, error: String(e) };
  }
}

/// Locate the newest Codex rollout (.jsonl) for a session by working directory.
/// Codex mints its own session id, so we can't address the file by our session
/// id like Claude; instead each rollout's first line (session_meta) carries the
/// cwd, and a per-agent workspace is unique, so we match on that and take the
/// most recently modified. Only the first line is read, so this stays cheap even
/// as rollouts grow.
export function findCodexRollout(cwd: string): string | undefined {
  const base = join(process.env.CODEX_HOME ?? join(homedir(), ".codex"), "sessions");
  if (!existsSync(base)) return undefined;
  let best: { path: string; mtime: number } | undefined;
  const walk = (dir: string): void => {
    let entries: import("node:fs").Dirent[];
    try {
      entries = readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const e of entries) {
      const full = join(dir, e.name);
      if (e.isDirectory()) {
        walk(full);
      } else if (e.name.startsWith("rollout-") && e.name.endsWith(".jsonl")) {
        try {
          // The session_meta first line can be very large (Codex embeds its full
          // base_instructions), so we don't JSON.parse it; cwd appears early, so
          // a bounded read + regex is robust regardless of the line length.
          const fd = openSync(full, "r");
          const buf = Buffer.alloc(65536);
          const n = readSync(fd, buf, 0, buf.length, 0);
          closeSync(fd);
          const head = buf.toString("utf-8", 0, n);
          const m = head.match(/"cwd"\s*:\s*"((?:[^"\\]|\\.)*)"/);
          const foundCwd = m ? JSON.parse(`"${m[1]}"`) : undefined;
          if (foundCwd === cwd) {
            const mtime = statSync(full).mtimeMs;
            if (!best || mtime > best.mtime) best = { path: full, mtime };
          }
        } catch {
          /* skip unreadable/partial */
        }
      }
    }
  };
  walk(base);
  return best?.path;
}

/// Locate a Claude session transcript by scanning ~/.claude/projects/<dir>/.
/// Encoding-independent: finds <sessionId>.jsonl wherever Claude placed it.
export function findSessionJsonl(sessionId: string): string | undefined {
  const root = claudeProjectsDir();
  if (!existsSync(root)) return undefined;
  const target = `${sessionId}.jsonl`;
  try {
    for (const dir of readdirSync(root)) {
      const candidate = join(root, dir, target);
      if (existsSync(candidate)) return candidate;
    }
  } catch {
    // ignore unreadable projects dir
  }
  return undefined;
}

// ── Transcript reading ───────────────────────────────────────────────

export function readLastTranscriptTurns(
  sessionPath: string,
  maxTurns: number = 5
): TranscriptTurn[] {
  if (!sessionPath || !existsSync(sessionPath)) return [];
  try {
    const stat = statSync(sessionPath);
    // Read tail of file (100KB per turn estimate, capped)
    const tailBytes = Math.min(maxTurns * 100 * 1024, stat.size);
    const fd = openSync(sessionPath, "r");
    const buf = Buffer.alloc(tailBytes);
    readSync(fd, buf, 0, tailBytes, stat.size - tailBytes);
    closeSync(fd);

    const text = buf.toString("utf-8");
    const lines = text.split("\n").filter(Boolean);

    const turns: TranscriptTurn[] = [];
    for (const line of lines) {
      try {
        const obj = JSON.parse(line);
        if (obj.type === "user" || obj.type === "assistant") {
          const content = extractText(obj);
          if (content) {
            turns.push({
              role: obj.type,
              text: content.slice(0, 500),
              timestamp: obj.timestamp,
            });
          }
        }
      } catch {
        // skip malformed lines
      }
    }
    return turns.slice(-maxTurns);
  } catch {
    return [];
  }
}

function extractText(obj: any): string {
  // Claude JSONL format: { type: "user"|"assistant", message: { content: [...] } }
  const content = obj.message?.content;
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content
      .filter((b: any) => b.type === "text")
      .map((b: any) => b.text || "")
      .join("\n")
      .trim();
  }
  return "";
}

// ── Card building ────────────────────────────────────────────────────

function displayTitle(link: Link): string {
  if (link.name) return link.name;
  if (link.promptBody) return link.promptBody.split("\n")[0].slice(0, 80);
  if (link.worktreeLink?.branch) return link.worktreeLink.branch;
  if (link.prLinks?.length)
    return link.prLinks[0].title || `PR #${link.prLinks[0].number}`;
  if (link.sessionLink?.sessionId)
    return link.sessionLink.sessionId.slice(0, 8);
  return link.id;
}

function projectName(link: Link): string | undefined {
  if (!link.projectPath) return undefined;
  return basename(link.projectPath);
}

export function toCardSummary(
  link: Link,
  liveTmux: Set<string>
): CardSummary {
  const tmuxName = link.tmuxLink?.sessionName;
  const ctx = link.sessionLink?.sessionId
    ? readSessionContext(link.sessionLink.sessionId)
    : undefined;
  return {
    id: link.id,
    name: displayTitle(link),
    column: link.column,
    project: projectName(link),
    assistant: link.assistant,
    sessionId: link.sessionLink?.sessionId,
    tmuxSession: tmuxName,
    tmuxAlive: tmuxName ? liveTmux.has(tmuxName) : false,
    worktree: link.worktreeLink?.path,
    branch: link.worktreeLink?.branch,
    prs: (link.prLinks || []).map((pr) => ({
      number: pr.number,
      status: pr.status,
      url: pr.url,
    })),
    lastActivity: link.lastActivity,
    lastMessage: undefined, // filled lazily
    queuedPrompts: link.queuedPrompts?.length || 0,
    isRemote: link.isRemote,
    tokens: ctx
      ? {
          input: ctx.totalInputTokens,
          output: ctx.totalOutputTokens,
          cost: ctx.totalCostUsd,
          context: {
            used: Math.round((ctx.usedPercentage / 100) * ctx.contextWindowSize),
            max: ctx.contextWindowSize,
            percentage: `${ctx.usedPercentage}%`,
          },
          model: ctx.model,
        }
      : undefined,
  };
}

export function toCardDetail(
  link: Link,
  liveTmux: Set<string>,
  transcriptTurns: number = 3
): CardDetail {
  const summary = toCardSummary(link, liveTmux);
  const transcript = link.sessionLink?.sessionPath
    ? readLastTranscriptTurns(link.sessionLink.sessionPath, transcriptTurns)
    : [];
  const lastMsg = transcript.length
    ? transcript[transcript.length - 1].text
    : undefined;

  return {
    ...summary,
    lastMessage: lastMsg,
    promptBody: link.promptBody?.slice(0, 500),
    sessionPath: link.sessionLink?.sessionPath,
    extraTmuxSessions: link.tmuxLink?.extraSessions || [],
    prDetails: link.prLinks || [],
    issueLink: link.issueLink,
    browserTabs: link.browserTabs || [],
    queuedPromptBodies: link.queuedPrompts || [],
    transcript,
  };
}

// ── Filtering helpers ────────────────────────────────────────────────

const ACTIVE_COLUMNS: KanbanColumn[] = [
  "in_progress",
  "requires_attention",
  "in_review",
  "backlog",
  "done",
];

export function filterActiveCards(links: Link[]): Link[] {
  const settings = readSettings();
  const excluded = settings.globalView?.excludedPaths ?? [];
  return links.filter(
    (l) =>
      ACTIVE_COLUMNS.includes(l.column) &&
      !l.manuallyArchived &&
      !isExcluded(l.projectPath, excluded)
  );
}

function isExcluded(
  projectPath: string | undefined,
  excludedPaths: string[]
): boolean {
  if (!excludedPaths.length || !projectPath) return false;
  const normalized = normalizePath(projectPath);
  const folderName = basename(normalized);
  for (const pattern of excludedPaths) {
    if (pattern.includes("*") || pattern.includes("?")) {
      // Glob — match against full path and folder name
      try {
        if (matchesGlob(normalized, pattern)) return true;
        if (matchesGlob(folderName, pattern)) return true;
      } catch {
        // Invalid glob pattern, skip
      }
    } else {
      const normalizedExcluded = normalizePath(pattern);
      if (
        normalized === normalizedExcluded ||
        normalized.startsWith(normalizedExcluded + "/")
      )
        return true;
    }
  }
  return false;
}

function normalizePath(p: string): string {
  // Expand ~ and resolve /private/var → /var etc.
  if (p.startsWith("~/")) {
    p = join(homedir(), p.slice(2));
  }
  return p;
}

export function filterByColumn(
  links: Link[],
  column: KanbanColumn
): Link[] {
  return links.filter((l) => l.column === column);
}

export function filterByProject(
  links: Link[],
  projectPath: string
): Link[] {
  return links.filter((l) => l.projectPath === projectPath);
}

export function findCard(links: Link[], idOrPrefix: string): Link | undefined {
  // Exact ID match
  const exact = links.find((l) => l.id === idOrPrefix);
  if (exact) return exact;
  // ID prefix match
  const prefixed = links.filter((l) => l.id.startsWith(idOrPrefix));
  if (prefixed.length === 1) return prefixed[0];
  // Exact name match (case-insensitive)
  const q = idOrPrefix.toLowerCase();
  const exactName = links.find(
    (l) => displayTitle(l).toLowerCase() === q
  );
  if (exactName) return exactName;
  // Tmux session name match
  const byTmux = links.find((l) => l.tmuxLink?.sessionName === idOrPrefix);
  if (byTmux) return byTmux;
  // Session ID match
  const bySession = links.find((l) => l.sessionLink?.sessionId === idOrPrefix);
  if (bySession) return bySession;
  // Session ID prefix match
  const bySessionPrefix = links.filter((l) =>
    l.sessionLink?.sessionId?.startsWith(idOrPrefix)
  );
  if (bySessionPrefix.length === 1) return bySessionPrefix[0];
  // Fuzzy name search — return if unique match
  const named = links.filter((l) =>
    displayTitle(l).toLowerCase().includes(q)
  );
  if (named.length === 1) return named[0];
  // Return most recently active match if multiple
  if (named.length > 1) {
    named.sort((a, b) =>
      (b.lastActivity || b.updatedAt).localeCompare(
        a.lastActivity || a.updatedAt
      )
    );
    return named[0];
  }
  return undefined;
}

// ── Utilities ────────────────────────────────────────────────────────

function shellEscape(s: string): string {
  return "'" + s.replace(/'/g, "'\\''") + "'";
}
