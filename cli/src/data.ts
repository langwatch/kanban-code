import { readFileSync, existsSync, statSync, openSync, readSync, closeSync, readdirSync } from "node:fs";
import { execSync, spawn } from "node:child_process";
import { homedir } from "node:os";
import { join, basename, matchesGlob } from "node:path";

/// tmux's anonymous paste buffer is a server-wide singleton, so concurrent
/// `set-buffer` + `paste-buffer` pairs from different processes race: the
/// second `set-buffer` clobbers the first's contents before the first gets
/// to paste. That bit us when the daily nudges for two agents fired at the
/// same wall-clock minute and the prompts swapped between sessions. Routing
/// every paste through a uniquely-named buffer (and deleting it via
/// `paste-buffer -d`) eliminates the shared-state collision. The pid+counter
/// scheme keeps the names stable within a process so tests can assert the
/// command stream, and unique across processes so the race is fixed.
let tmuxBufferSeq = 0;
function nextTmuxBufferName(): string {
  tmuxBufferSeq += 1;
  return `kc-${process.pid}-${tmuxBufferSeq}`;
}
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

// ── Remote tmux routing ──────────────────────────────────────────────

/// The boxd machine that owns a tmux session, when the session belongs to a
/// remote card. Extra terminals of the card live on the same machine.
export function remoteMachineForSession(sessionName: string): string | undefined {
  let links: Link[];
  try {
    links = readLinks();
  } catch {
    return undefined;
  }
  for (const link of links) {
    // A card can own a machine while its session runs on the Mac (boxd was
    // deselected on resume): only isRemote says where the tmux really is.
    if (link.remote?.mode !== "boxd" || !link.isRemote) continue;
    if (!link.remote.machineName) continue;
    if (
      link.tmuxLink?.sessionName === sessionName ||
      link.tmuxLink?.extraSessions?.includes(sessionName)
    ) {
      return link.remote.machineName;
    }
  }
  return undefined;
}

/// Every tmux session name that lives on a boxd machine. Those sessions never
/// show up in a local `tmux list-sessions`, so callers that decide whether a
/// card's terminal is alive have to add them separately.
export function remoteTmuxSessionNames(): string[] {
  let links: Link[];
  try {
    links = readLinks();
  } catch {
    return [];
  }
  const names: string[] = [];
  for (const link of links) {
    if (link.remote?.mode !== "boxd" || !link.isRemote) continue;
    if (link.tmuxLink?.sessionName) names.push(link.tmuxLink.sessionName);
    for (const extra of link.tmuxLink?.extraSessions ?? []) names.push(extra);
  }
  return names;
}

/// One step of a tmux command chain: the arguments of a single tmux call, a
/// pause between two of them, or a raw shell fragment (with `%TMUX%` standing
/// in for the tmux binary) for the checks a plain call cannot express.
export type TmuxStep = string[] | { sleep: number | string } | { raw: string };

export interface TmuxRunOptions {
  /// Run detached and return immediately, for chains that sleep first.
  detached?: boolean;
  /// Drop stderr, for probes whose failure is the answer.
  quiet?: boolean;
}

export type TmuxCommandRunner = (
  command: string,
  options: { detached: boolean }
) => string;

let tmuxCommandRunner: TmuxCommandRunner | undefined;

/// Test seam: replace the shell so a test can capture the tmux command stream.
/// Pass undefined to restore the real one.
export function setTmuxCommandRunner(runner?: TmuxCommandRunner): void {
  tmuxCommandRunner = runner;
}

/// Build the shell command for a chain of tmux calls. A local session runs
/// tmux directly; a boxd session hands the whole chain to one
/// `boxd machine exec`, which runs it in a shell on the machine, so a paste
/// costs one round trip and needs no temporary file on the Mac.
export function buildTmuxCommand(
  sessionName: string,
  steps: TmuxStep[],
  options: TmuxRunOptions = {}
): string {
  const machine = remoteMachineForSession(sessionName);
  const tmux = machine ? "tmux" : findTmux();
  const script = steps
    .map((step) => {
      if (Array.isArray(step)) return `${tmux} ${step.map(shellToken).join(" ")}`;
      if ("raw" in step) return step.raw.replaceAll("%TMUX%", tmux);
      return `sleep ${shellToken(String(step.sleep))}`;
    })
    .join(" && ");
  const command = machine
    ? `boxd machine exec ${shellToken(machine)} -- ${shellEscape(script)}`
    : script;
  return options.quiet ? `${command} 2>/dev/null` : command;
}

/// Run a chain of tmux calls against a session, local or remote.
export function runTmux(
  sessionName: string,
  steps: TmuxStep[],
  options: TmuxRunOptions = {}
): string {
  const command = buildTmuxCommand(sessionName, steps, options);
  const detached = options.detached === true;
  if (tmuxCommandRunner) return tmuxCommandRunner(command, { detached });
  if (detached) {
    const child = spawn("sh", ["-c", command], {
      detached: true,
      stdio: "ignore",
      env: process.env,
    });
    child.unref();
    return "";
  }
  return execSync(command, { encoding: "utf-8" });
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
  const start =
    scrollback === "all"
      ? ["-S", "-"]
      : scrollback > 0
        ? ["-S", `-${scrollback}`]
        : [];
  try {
    return runTmux(
      sessionName,
      [["capture-pane", "-t", sessionName, "-p", ...start]],
      { quiet: true }
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
  try {
    // Capture enough to skip chrome and have content left
    const raw = runTmux(
      sessionName,
      [["capture-pane", "-t", sessionName, "-p", "-S", `-${contentLines + 20}`]],
      { quiet: true }
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
  try {
    runTmux(sessionName, [["send-keys", "-t", sessionName, keys, "Enter"]]);
    return { ok: true };
  } catch (e) {
    return { ok: false, error: String(e) };
  }
}

export function sendTmuxEnter(
  sessionName: string
): { ok: boolean; error?: string } {
  try {
    runTmux(sessionName, [["send-keys", "-t", sessionName, "Enter"]]);
    return { ok: true };
  } catch (e) {
    return { ok: false, error: String(e) };
  }
}

export function pasteTmuxPrompt(
  sessionName: string,
  text: string
): { ok: boolean; error?: string } {
  try {
    // Use tmux paste-buffer with bracketed paste for reliable multi-line input.
    // A named buffer (-b <buf>) plus `paste-buffer -d` keeps each call
    // self-contained so concurrent pastes from sibling processes can't clobber
    // each other's text on the shared anonymous buffer. The 0.1s pause before
    // Enter matches the Swift implementation.
    runTmux(sessionName, [
      ...pasteSteps(sessionName, text),
      { sleep: 0.1 },
      ["send-keys", "-t", sessionName, "Enter"],
    ]);
    return { ok: true };
  } catch (e) {
    return { ok: false, error: String(e) };
  }
}

/// `set-buffer` + `paste-buffer` for one prompt. `--` keeps text that starts
/// with a dash out of tmux's own option parsing.
function pasteSteps(sessionName: string, text: string): TmuxStep[] {
  const buf = nextTmuxBufferName();
  return [
    ["set-buffer", "-b", buf, "--", text],
    ["paste-buffer", "-p", "-d", "-b", buf, "-t", sessionName],
  ];
}

/// Send a single keystroke (e.g. the digit "1") to a tmux session WITHOUT a
/// trailing Enter. Claude Code's numbered picker accepts a bare digit and
/// commits the choice immediately, so the Slack bridge uses this for picker
/// button clicks. The bare-digit-no-Enter behavior is why we cannot reuse
/// sendTmuxKeys (which always appends Enter).
export function sendTmuxKey(sessionName: string, key: string): { ok: boolean; error?: string } {
  try {
    runTmux(sessionName, [["send-keys", "-t", sessionName, key]]);
    return { ok: true };
  } catch (e) {
    return { ok: false, error: String(e) };
  }
}

/// Paste text into the composer, submit it, and make sure the submit landed.
///
/// Under load the TUI can drop an Enter that arrives while it is still
/// processing the paste before it, and the text left sitting in the composer
/// concatenates with whatever is pasted next — a scheduled "/compact" plus its
/// follow-up became one "/compactYou are..." line this way. The check re-sends
/// Enter while the pasted text still shows at the bottom of the pane. After a
/// real submit the transcript echo can match too, but those retries land
/// within seconds of the submit, on an empty composer, where Enter is a no-op.
function submitSteps(sessionName: string, text: string): TmuxStep[] {
  const steps: TmuxStep[] = [
    ...pasteSteps(sessionName, text),
    { sleep: 1 },
    ["send-keys", "-t", sessionName, "Enter"],
  ];
  const probe = text.split("\n")[0].trim().slice(0, 40);
  if (probe.length >= 4) {
    const session = shellToken(sessionName);
    steps.push({
      raw:
        `{ i=0; while [ "$i" -lt 2 ]; do sleep 1.5; ` +
        `%TMUX% capture-pane -t ${session} -p | tail -8 | grep -qF -- ${shellToken(probe)} || break; ` +
        `%TMUX% send-keys -t ${session} Enter; i=$((i+1)); done; }`,
    });
  }
  return steps;
}

export function scheduleTmuxPrompt(
  sessionName: string,
  text: string,
  delaySeconds: number
): { ok: boolean; error?: string } {
  const delay = Math.max(0, Number.isFinite(delaySeconds) ? delaySeconds : 1);
  try {
    runTmux(
      sessionName,
      [{ sleep: delay }, ...submitSteps(sessionName, text)],
      { detached: true }
    );
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
  const delay = Math.max(0, Number.isFinite(followUpDelaySeconds) ? followUpDelaySeconds : 1);
  const compactSteps: TmuxStep[] = [
    // Give the CLI time to finish printing its output and return control to
    // Claude Code before we start sending keys to the same pane. The shell
    // is detached so it survives Claude interrupting the Bash tool that
    // launched `kanban self-compact` — but if we send Escape too soon, the
    // interrupt races with Claude still processing the tool result and
    // sometimes leaves the session in a state where `/compact` is not
    // recognised as a slash command. 2s gives a comfortable buffer.
    { sleep: 2 },
    ["send-keys", "-t", sessionName, "Escape"],
    // The interrupt redraws the composer; pasting into the middle of that is
    // how an Enter gets dropped, so let it settle first.
    { sleep: 0.5 },
    ...submitSteps(sessionName, "/compact"),
  ];

  const followUpSteps: TmuxStep[] = followUp.trim().length === 0
    ? []
    : [{ sleep: delay }, ...submitSteps(sessionName, followUp)];

  try {
    runTmux(sessionName, [...compactSteps, ...followUpSteps], { detached: true });
    return { ok: true };
  } catch (e) {
    return { ok: false, error: String(e) };
  }
}

export function pasteTmuxText(
  sessionName: string,
  text: string
): { ok: boolean; error?: string } {
  try {
    runTmux(sessionName, pasteSteps(sessionName, text));
    return { ok: true };
  } catch (e) {
    return { ok: false, error: String(e) };
  }
}

/**
 * Stop the assistant's current turn, then submit `text`. Steering waits for the
 * turn to end; this cuts it short. The pause after Escape gives the composer a
 * beat to become usable again before the paste lands.
 */
export function interruptTmuxPrompt(
  sessionName: string,
  text: string,
  send: (session: string, body: string) => { ok: boolean; error?: string } = pasteTmuxPrompt
): { ok: boolean; error?: string } {
  const stopped = sendTmuxEscape(sessionName);
  if (!stopped.ok) return stopped;
  try {
    execSync("sleep 0.4");
  } catch {
    // A failed sleep only costs the settle time, not the send itself.
  }
  return send(sessionName, text);
}

export function sendTmuxEscape(
  sessionName: string
): { ok: boolean; error?: string } {
  try {
    runTmux(sessionName, [["send-keys", "-t", sessionName, "Escape"]]);
    return { ok: true };
  } catch (e) {
    return { ok: false, error: String(e) };
  }
}

// ── Tmux session lifecycle (headless agent launch/resume) ────────────

export function hasTmuxSession(name: string): boolean {
  try {
    runTmux(name, [["has-session", "-t", name]], { quiet: true });
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
  try {
    runTmux(name, [["kill-session", "-t", name]], { quiet: true });
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
        } else if (
          obj.type === "event_msg" &&
          (obj.payload?.type === "user_message" || obj.payload?.type === "agent_message") &&
          typeof obj.payload?.message === "string" &&
          obj.payload.message.trim()
        ) {
          turns.push({
            role: obj.payload.type === "user_message" ? "user" : "assistant",
            text: obj.payload.message.slice(0, 500),
            timestamp: obj.timestamp,
          });
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
    modelOverride: link.modelOverride,
    selfCompactContextThresholdTokens: link.selfCompactContextThresholdTokens,
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

/// Quotes only what the shell would otherwise reinterpret. Flags and session
/// names stay readable, which matters because a remote command is quoted twice.
function shellToken(s: string): string {
  return /^[A-Za-z0-9_.,:/=+-]+$/.test(s) ? s : shellEscape(s);
}
