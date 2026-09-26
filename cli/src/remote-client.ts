/**
 * `kanban remote`: drive the Kanban Code app on a Mac over its HTTP API
 * (docs/remote-control.md) from any machine on the same tailnet, such as an
 * agent on a Linux VM. The client side imports nothing that needs macOS, so
 * the same build runs on plain node elsewhere.
 *
 * `pair`, `devices` and `revoke` run on the Mac itself and edit
 * `~/.kanban-code/remote/devices.json` (see remote-devices.ts).
 */

import type { Command } from "commander";
import { InvalidArgumentError, Option } from "commander";
import { chmodSync, existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { kanbanHome } from "./paths.js";
import {
  REMOTE_DEFAULT_PORT,
  REMOTE_SCOPES,
  addDevice,
  defaultServerUrl,
  listDevices,
  pairingLink,
  remoteDevicesPath,
  revokeDevice,
  type RemoteScope,
} from "./remote-devices.js";

// ── Wire types (Sources/KanbanCodeRemoteKit/RemoteModels.swift) ──────

export type RemoteColumn = "backlog" | "in_progress" | "requires_attention" | "in_review" | "done" | "all_sessions";

export const COLUMN_NAMES: Record<RemoteColumn, string> = {
  backlog: "Backlog",
  in_progress: "In Progress",
  requires_attention: "Waiting",
  in_review: "In Review",
  done: "Done",
  all_sessions: "All Sessions",
};

export interface RemoteHealth {
  app: string;
  version: string;
  apiVersion: number;
  hostName: string;
}

export interface RemoteDevice {
  id: string;
  name: string;
  scope: RemoteScope;
  createdAt: string;
  lastSeenAt?: string | null;
}

export interface RemotePR {
  number: number;
  url?: string | null;
  title?: string | null;
  status?: string | null;
}

export interface RemoteTerminal {
  sessionName: string;
  label: string;
  isPrimary: boolean;
}

export interface RemoteCard {
  id: string;
  title: string;
  column: RemoteColumn;
  projectPath?: string | null;
  projectName?: string | null;
  branch?: string | null;
  worktreePath?: string | null;
  assistant: string;
  runtime: "tmux" | "agtop" | "machine" | "none";
  isLive: boolean;
  isBusy: boolean;
  sessionId?: string | null;
  terminals: RemoteTerminal[];
  prs: RemotePR[];
  queuedPromptCount: number;
  parentCardId?: string | null;
  archived: boolean;
  lastActivity?: string | null;
  updatedAt: string;
}

export interface RemoteProject {
  path: string;
  name: string;
}

export interface RemoteBoard {
  cards: RemoteCard[];
  projects: RemoteProject[];
  generatedAt: string;
}

export interface RemoteMessage {
  id: string;
  role: "user" | "assistant" | "tool" | "system";
  text: string;
  at?: string | null;
}

export interface RemoteTranscript {
  cardId: string;
  messages: RemoteMessage[];
  olderCursor?: string | null;
}

export interface RemoteTaskRequest {
  project: string;
  prompt: string;
  name?: string;
  worktree?: string;
  assistant?: string;
  model?: string;
  launch?: boolean;
}

export interface RemotePromptRequest {
  text: string;
  mode?: "queue" | "now";
}

// ── Errors ───────────────────────────────────────────────────────────

/** A failure the CLI reports as one line on stderr, with an exit code. */
export class RemoteCliError extends Error {
  constructor(message: string, readonly exitCode = 1) {
    super(message);
  }
}

export class RemoteHttpError extends RemoteCliError {
  constructor(readonly status: number, readonly serverMessage: string, message: string) {
    super(message, 1);
  }
}

// ── Client configuration ─────────────────────────────────────────────

export interface RemoteClientConfig {
  url: string;
  token: string;
  deviceId?: string;
  deviceName?: string;
  scope?: RemoteScope;
  hostName?: string;
  savedAt?: string;
}

export function remoteClientConfigPath(): string {
  return join(kanbanHome(), "remote-client.json");
}

export function readClientConfig(path = remoteClientConfigPath()): RemoteClientConfig | undefined {
  if (!existsSync(path)) return undefined;
  try {
    const parsed = JSON.parse(readFileSync(path, "utf8")) as RemoteClientConfig;
    return parsed && typeof parsed.url === "string" && typeof parsed.token === "string" ? parsed : undefined;
  } catch {
    return undefined;
  }
}

export function writeClientConfig(config: RemoteClientConfig, path = remoteClientConfigPath()): void {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  const tmp = `${path}.${process.pid}.tmp`;
  writeFileSync(tmp, JSON.stringify(config, null, 2) + "\n", { mode: 0o600 });
  chmodSync(tmp, 0o600);
  renameSync(tmp, path);
}

/** `KANBAN_REMOTE_URL` and `KANBAN_REMOTE_TOKEN` override the saved login, each on its own. */
export function resolveClientConfig(
  env: NodeJS.ProcessEnv = process.env,
  path = remoteClientConfigPath()
): { config: RemoteClientConfig; source: string } {
  const saved = readClientConfig(path);
  const url = env.KANBAN_REMOTE_URL || saved?.url;
  const token = env.KANBAN_REMOTE_TOKEN || saved?.token;
  if (!url || !token) {
    throw new RemoteCliError(
      "Not logged in to a Kanban Code Mac. Run: kanban remote login <url> --token <token>\n" +
        "(or set KANBAN_REMOTE_URL and KANBAN_REMOTE_TOKEN)."
    );
  }
  const fromEnv = [env.KANBAN_REMOTE_URL && "KANBAN_REMOTE_URL", env.KANBAN_REMOTE_TOKEN && "KANBAN_REMOTE_TOKEN"]
    .filter(Boolean)
    .join(", ");
  const source = fromEnv ? (saved ? `${fromEnv} over ${path}` : fromEnv) : path;
  return { config: { ...(saved ?? {}), url: normalizeUrl(url), token }, source };
}

/** Adds `http://` when no scheme is given and drops trailing slashes. */
export function normalizeUrl(raw: string): string {
  let url = raw.trim();
  if (!/^[a-z][a-z0-9+.-]*:\/\//i.test(url)) url = `http://${url}`;
  return url.replace(/\/+$/, "");
}

// ── HTTP client ──────────────────────────────────────────────────────

export type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;

export class RemoteClient {
  constructor(
    readonly baseUrl: string,
    private readonly token: string | undefined,
    private readonly fetchImpl: FetchLike = fetch,
    private readonly timeoutMs = 20_000
  ) {}

  health(): Promise<RemoteHealth> {
    return this.request("GET", "/v1/health", undefined, { auth: false });
  }

  me(): Promise<RemoteDevice> {
    return this.request("GET", "/v1/me");
  }

  /** The working set (no archived, no All Sessions, recent Done), or every card with `all`. */
  board(opts: { all?: boolean } = {}): Promise<RemoteBoard> {
    return this.request("GET", opts.all ? "/v1/board?all=1" : "/v1/board");
  }

  card(id: string): Promise<RemoteCard> {
    return this.request("GET", `/v1/cards/${encodeURIComponent(id)}`);
  }

  transcript(id: string, opts: { limit?: number; before?: string } = {}): Promise<RemoteTranscript> {
    const q = new URLSearchParams();
    if (opts.limit !== undefined) q.set("limit", String(opts.limit));
    if (opts.before) q.set("before", opts.before);
    const suffix = q.size ? `?${q.toString()}` : "";
    return this.request("GET", `/v1/cards/${encodeURIComponent(id)}/transcript${suffix}`);
  }

  createTask(body: RemoteTaskRequest): Promise<RemoteCard> {
    return this.request("POST", "/v1/tasks", body);
  }

  async prompt(id: string, body: RemotePromptRequest): Promise<void> {
    await this.request("POST", `/v1/cards/${encodeURIComponent(id)}/prompt`, body);
  }

  async interrupt(id: string): Promise<void> {
    await this.request("POST", `/v1/cards/${encodeURIComponent(id)}/interrupt`, {});
  }

  resume(id: string): Promise<RemoteCard> {
    return this.request("POST", `/v1/cards/${encodeURIComponent(id)}/resume`, {});
  }

  private async request<T>(
    method: string,
    path: string,
    body?: unknown,
    opts: { auth?: boolean } = {}
  ): Promise<T> {
    const headers: Record<string, string> = { accept: "application/json" };
    if (opts.auth !== false && this.token) headers.authorization = `Bearer ${this.token}`;
    if (body !== undefined) headers["content-type"] = "application/json";
    let res: Response;
    try {
      res = await this.fetchImpl(this.baseUrl + path, {
        method,
        headers,
        body: body === undefined ? undefined : JSON.stringify(body),
        signal: AbortSignal.timeout(this.timeoutMs),
      });
    } catch (error) {
      throw new RemoteCliError(unreachableMessage(this.baseUrl, error));
    }
    const text = await res.text();
    if (!res.ok) {
      let serverMessage = text.trim();
      try {
        const parsed = JSON.parse(text) as { error?: string };
        if (parsed && typeof parsed.error === "string") serverMessage = parsed.error;
      } catch {
        // Not JSON: keep the raw body.
      }
      throw new RemoteHttpError(res.status, serverMessage, httpErrorMessage(res.status, serverMessage, method, path));
    }
    if (!text) return undefined as T;
    try {
      return JSON.parse(text) as T;
    } catch {
      throw new RemoteCliError(`${method} ${path}: the server answered ${res.status} with a body that is not JSON.`);
    }
  }
}

function unreachableMessage(baseUrl: string, error: unknown): string {
  const err = error as { name?: string; message?: string; cause?: { code?: string; message?: string } };
  const reason =
    err?.name === "TimeoutError" || err?.name === "AbortError"
      ? "timed out"
      : err?.cause?.code ?? err?.cause?.message ?? err?.message ?? String(error);
  return (
    `Cannot reach the Kanban Code Mac at ${baseUrl} (${reason}).\n` +
    "Check that the Mac is awake, Kanban Code runs with Settings > Remote Control on, and this machine is on the " +
    "same Tailscale tailnet (`tailscale status` should list the Mac)."
  );
}

function httpErrorMessage(status: number, serverMessage: string, method: string, path: string): string {
  const detail = serverMessage ? `: ${serverMessage}` : "";
  switch (status) {
    case 401:
      return (
        `The Mac refused the token (401${detail}). ` +
        "Pair again on the Mac with `kanban remote pair --name <device>` and run `kanban remote login`."
      );
    case 403:
      return `This device's scope does not allow ${method} ${path} (403${detail}).`;
    case 404:
      return `Not found (404${detail}).`;
    case 409:
      return `Conflict (409${detail}).`;
    default:
      return `${method} ${path} failed with ${status}${detail}.`;
  }
}

// ── Card lookup ──────────────────────────────────────────────────────

/** Exact id, then a unique id prefix, then an exact title (case-sensitive, then not). */
export function resolveCardRef(cards: RemoteCard[], ref: string): RemoteCard {
  const wanted = ref.trim();
  if (!wanted) throw new RemoteCliError("Give a card id, id prefix or title.");
  const exact = cards.find((c) => c.id === wanted);
  if (exact) return exact;

  const byPrefix = cards.filter((c) => c.id.startsWith(wanted));
  if (byPrefix.length === 1) return byPrefix[0];
  if (byPrefix.length > 1) throw ambiguous(ref, byPrefix);

  for (const match of [
    (c: RemoteCard) => c.title === wanted,
    (c: RemoteCard) => c.title.toLowerCase() === wanted.toLowerCase(),
  ]) {
    const byTitle = cards.filter(match);
    if (byTitle.length === 1) return byTitle[0];
    if (byTitle.length > 1) throw ambiguous(ref, byTitle);
  }
  throw new RemoteCliError(`No card matches '${ref}'. See kanban remote cards.`);
}

function ambiguous(ref: string, cards: RemoteCard[]): RemoteCliError {
  const lines = cards.slice(0, 10).map((c) => `  ${c.id}  ${c.title}`);
  return new RemoteCliError(`'${ref}' matches ${cards.length} cards, use a longer id:\n${lines.join("\n")}`);
}

/** Accepts the wire value (`requires_attention`) or the display name (`Waiting`, `in progress`). */
export function parseColumn(raw: string): RemoteColumn {
  const key = raw.trim().toLowerCase().replace(/[\s-]+/g, "_");
  for (const [wire, display] of Object.entries(COLUMN_NAMES)) {
    if (wire === key || display.toLowerCase().replace(/\s+/g, "_") === key) return wire as RemoteColumn;
  }
  const known = Object.entries(COLUMN_NAMES)
    .map(([wire, display]) => `${wire} (${display})`)
    .join(", ");
  throw new RemoteCliError(`Unknown column '${raw}'. Known: ${known}.`);
}

export function filterCards(
  cards: RemoteCard[],
  opts: { column?: string; project?: string; all?: boolean }
): RemoteCard[] {
  let out = opts.all ? cards : cards.filter((c) => !c.archived);
  if (opts.column) {
    const column = parseColumn(opts.column);
    out = out.filter((c) => c.column === column);
  }
  if (opts.project) {
    const p = opts.project.trim().toLowerCase();
    out = out.filter(
      (c) => c.projectName?.toLowerCase() === p || c.projectPath?.toLowerCase() === p || c.projectPath?.toLowerCase() === p.replace(/\/+$/, "")
    );
  }
  return out;
}

// ── Formatting ───────────────────────────────────────────────────────

export function cardState(card: RemoteCard): string {
  if (card.isBusy) return "busy";
  if (card.isLive) return "idle";
  return "stopped";
}

export function formatCardLine(card: RemoteCard, idWidth = card.id.length): string {
  const project = card.projectName ?? "-";
  const queued = card.queuedPromptCount > 0 ? ` +${card.queuedPromptCount}q` : "";
  return `${pad(card.id, idWidth)}  ${pad(COLUMN_NAMES[card.column] ?? card.column, 12)} ${pad(cardState(card) + queued, 11)} ${pad(project, 16)} ${card.title}`;
}

export function formatCardsTable(cards: RemoteCard[]): string {
  if (cards.length === 0) return "No cards.";
  const order = Object.keys(COLUMN_NAMES) as RemoteColumn[];
  const sorted = [...cards].sort(
    (a, b) =>
      order.indexOf(a.column) - order.indexOf(b.column) ||
      (b.lastActivity ?? b.updatedAt).localeCompare(a.lastActivity ?? a.updatedAt)
  );
  const idWidth = Math.max(...sorted.map((c) => c.id.length));
  return sorted.map((c) => formatCardLine(c, idWidth)).join("\n");
}

export function formatCardDetail(card: RemoteCard): string {
  const lines = [
    `${card.title}`,
    `  id:         ${card.id}`,
    `  column:     ${COLUMN_NAMES[card.column] ?? card.column}`,
    `  state:      ${cardState(card)}${card.queuedPromptCount ? ` (${card.queuedPromptCount} queued prompts)` : ""}`,
    `  project:    ${card.projectName ?? "-"}${card.projectPath ? ` (${card.projectPath})` : ""}`,
    `  assistant:  ${card.assistant} on ${card.runtime}`,
  ];
  if (card.branch) lines.push(`  branch:     ${card.branch}`);
  if (card.worktreePath) lines.push(`  worktree:   ${card.worktreePath}`);
  if (card.sessionId) lines.push(`  session:    ${card.sessionId}`);
  for (const pr of card.prs ?? []) {
    lines.push(`  pr:         #${pr.number}${pr.status ? ` ${pr.status}` : ""}${pr.title ? ` ${pr.title}` : ""}${pr.url ? ` ${pr.url}` : ""}`);
  }
  if (card.parentCardId) lines.push(`  parent:     ${card.parentCardId}`);
  if (card.archived) lines.push(`  archived:   yes`);
  if (card.lastActivity) lines.push(`  activity:   ${card.lastActivity}`);
  return lines.join("\n");
}

export function formatMessage(message: RemoteMessage): string {
  const time = message.at ? message.at.slice(11, 19) + " " : "";
  if (message.role === "tool") return `${time}[tool] ${message.text}`;
  return `${time}${message.role}:\n${indent(message.text)}\n`;
}

function indent(text: string): string {
  return text
    .split("\n")
    .map((line) => (line ? `  ${line}` : line))
    .join("\n");
}

function pad(text: string, width: number): string {
  return text.length >= width ? text : text + " ".repeat(width - text.length);
}

// ── Waiting on a card ────────────────────────────────────────────────

export interface WaitOptions {
  intervalMs: number;
  timeoutMs?: number;
  /**
   * A card that has not been seen busy yet counts as finished only after this
   * long, so a task that is still launching is not reported done at once.
   */
  startGraceMs: number;
}

/** A card is settled when it is not in a turn and has no queued prompts. */
export function cardSettled(card: RemoteCard): boolean {
  return !card.isBusy && (card.queuedPromptCount ?? 0) === 0;
}

// ── Command wiring ───────────────────────────────────────────────────

export interface RemoteIO {
  out(text: string): void;
  err(text: string): void;
  readStdin(): Promise<string>;
  env: NodeJS.ProcessEnv;
  sleep(ms: number): Promise<void>;
  now(): number;
  fetch?: FetchLike;
  /** Ends the command with this exit code. */
  exit(code: number): void;
}

export function defaultRemoteIO(): RemoteIO {
  return {
    out: (text) => process.stdout.write(text),
    err: (text) => process.stderr.write(text),
    readStdin: async () => {
      const chunks: Buffer[] = [];
      for await (const chunk of process.stdin) chunks.push(Buffer.from(chunk));
      return Buffer.concat(chunks).toString("utf8");
    },
    env: process.env,
    sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
    now: () => Date.now(),
    exit: (code) => process.exit(code),
  };
}

function parsePositiveInt(name: string) {
  return (raw: string): number => {
    const n = Number(raw);
    if (!Number.isInteger(n) || n <= 0) throw new InvalidArgumentError(`${name} must be a positive integer.`);
    return n;
  };
}

/** `90`, `90s`, `15m`, `2h` to milliseconds. A bare number is seconds. */
export function parseTimeout(raw: string): number {
  const m = /^(\d+(?:\.\d+)?)\s*(ms|s|m|h)?$/.exec(raw.trim());
  if (!m || Number(m[1]) <= 0) throw new InvalidArgumentError(`Use a duration like 90, 90s, 15m or 2h.`);
  const n = Number(m[1]);
  const unit = m[2] ?? "s";
  return Math.round(n * { ms: 1, s: 1000, m: 60_000, h: 3_600_000 }[unit]!);
}

export function registerRemoteCommands(program: Command, io: RemoteIO = defaultRemoteIO()): Command {
  const remote = program
    .command("remote")
    .description("Drive Kanban Code on a Mac over its remote API (from a phone's tailnet, another machine or an agent)");

  const println = (text: string) => io.out(text.endsWith("\n") ? text : text + "\n");
  const printJson = (data: unknown) => io.out(JSON.stringify(data, null, 2) + "\n");

  /** Runs an action, turning a RemoteCliError into a message on stderr and an exit code. */
  const run =
    <A extends unknown[]>(fn: (...args: A) => Promise<void>) =>
    async (...args: A): Promise<void> => {
      try {
        await fn(...args);
      } catch (error) {
        if (error instanceof RemoteCliError) {
          io.err(`Error: ${error.message}\n`);
          io.exit(error.exitCode);
          return;
        }
        if (error instanceof SyntaxError || (error as NodeJS.ErrnoException)?.code) {
          io.err(`Error: ${(error as Error).message}\n`);
          io.exit(1);
          return;
        }
        throw error;
      }
    };

  const client = (): RemoteClient => {
    const { config } = resolveClientConfig(io.env);
    return new RemoteClient(config.url, config.token, io.fetch);
  };

  const readText = async (parts: string[], what: string): Promise<string> => {
    const text = parts.length === 1 && parts[0] === "-" ? await io.readStdin() : parts.join(" ");
    if (!text.trim()) throw new RemoteCliError(`Give the ${what} as arguments, or '-' to read it from stdin.`);
    return text.replace(/\n+$/, "");
  };

  const findCard = async (c: RemoteClient, ref: string): Promise<RemoteCard> => {
    try {
      return await c.card(ref);
    } catch (error) {
      if (!(error instanceof RemoteHttpError) || (error.status !== 404 && error.status !== 400)) throw error;
    }
    const board = await c.board({ all: true });
    return resolveCardRef(board.cards, ref);
  };

  const withConflictHint = async <T>(ref: string, fn: () => Promise<T>): Promise<T> => {
    try {
      return await fn();
    } catch (error) {
      if (error instanceof RemoteHttpError && error.status === 409) {
        throw new RemoteCliError(
          `${error.serverMessage || "The card has no live session"} (409). Run: kanban remote resume ${ref}`
        );
      }
      throw error;
    }
  };

  // ── login / logout / whoami ──

  remote
    .command("login <url>")
    .description("Check a Mac's remote API and save it with a token in ~/.kanban-code/remote-client.json")
    .requiredOption("--token <token>", "device token printed by `kanban remote pair` or Settings > Remote Control")
    .option("--json", "output as JSON")
    .action(
      run(async (rawUrl: string, opts: { token: string; json?: boolean }) => {
        const url = normalizeUrl(rawUrl);
        const c = new RemoteClient(url, opts.token, io.fetch);
        const health = await c.health();
        if (health.app !== "kanban-code") {
          throw new RemoteCliError(`${url} answered /v1/health but is not Kanban Code (app: ${health.app}).`);
        }
        const me = await c.me();
        const config: RemoteClientConfig = {
          url,
          token: opts.token,
          deviceId: me.id,
          deviceName: me.name,
          scope: me.scope,
          hostName: health.hostName,
          savedAt: new Date(io.now()).toISOString(),
        };
        const path = remoteClientConfigPath();
        writeClientConfig(config, path);
        if (opts.json) return printJson({ url, health, device: me, path });
        println(
          `Logged in to ${health.hostName} (Kanban Code ${health.version}) at ${url} as '${me.name}', scope ${me.scope}.\n` +
            `Saved to ${path}.`
        );
      })
    );

  remote
    .command("logout")
    .description("Forget the saved Mac and token")
    .action(
      run(async () => {
        const path = remoteClientConfigPath();
        if (!existsSync(path)) return println("Not logged in.");
        rmSync(path, { force: true });
        println(`Removed ${path}.`);
      })
    );

  remote
    .command("whoami")
    .description("Show which Mac and device this CLI talks to")
    .option("--json", "output as JSON")
    .action(
      run(async (opts: { json?: boolean }) => {
        const { config, source } = resolveClientConfig(io.env);
        const c = new RemoteClient(config.url, config.token, io.fetch);
        const [health, me] = await Promise.all([c.health(), c.me()]);
        if (opts.json) return printJson({ url: config.url, source, health, device: me });
        println(
          `${me.name} (${me.id}), scope ${me.scope}\n` +
            `Mac: ${health.hostName} at ${config.url}, Kanban Code ${health.version}, API v${health.apiVersion}\n` +
            `From: ${source}`
        );
      })
    );

  // ── board ──

  remote
    .command("cards")
    .description("List the Mac's working cards (archived, All Sessions and older Done cards only with --all)")
    .option("--column <column>", "backlog, in_progress, waiting (requires_attention), in_review, done")
    .option("--project <project>", "project name or path")
    .option("--all", "include archived, All Sessions and older Done cards")
    .option("--json", "output as JSON")
    .action(
      run(async (opts: { column?: string; project?: string; all?: boolean; json?: boolean }) => {
        const board = await client().board({ all: opts.all });
        const cards = filterCards(board.cards, opts);
        if (opts.json) return printJson(cards);
        println(formatCardsTable(cards));
      })
    );

  remote
    .command("projects")
    .description("List the Mac's projects, the names `task --project` accepts")
    .option("--json", "output as JSON")
    .action(
      run(async (opts: { json?: boolean }) => {
        const board = await client().board();
        if (opts.json) return printJson(board.projects);
        if (board.projects.length === 0) return println("No projects.");
        println(board.projects.map((p) => `${pad(p.name, 24)} ${p.path}`).join("\n"));
      })
    );

  remote
    .command("show <card>")
    .description("Show one card (id, unique id prefix or exact title)")
    .option("--json", "output as JSON")
    .action(
      run(async (ref: string, opts: { json?: boolean }) => {
        const card = await findCard(client(), ref);
        if (opts.json) return printJson(card);
        println(formatCardDetail(card));
      })
    );

  // ── tasks and prompts ──

  remote
    .command("task <prompt...>")
    .description("Create a card in a project on the Mac and launch it with the prompt ('-' reads the prompt from stdin)")
    .requiredOption("--project <project>", "project name or path on the Mac (see kanban remote projects)")
    .option("--worktree [name]", "run in a new git worktree, with this name or a random one")
    .option("--name <name>", "card title")
    .option("--assistant <assistant>", "claude, codex or gemini (default: the project's)")
    .option("--model <model>", "model for the assistant")
    .option("--no-launch", "only create the card in the backlog")
    .option("--json", "output as JSON")
    .action(
      run(
        async (
          parts: string[],
          opts: {
            project: string;
            worktree?: string | boolean;
            name?: string;
            assistant?: string;
            model?: string;
            launch: boolean;
            json?: boolean;
          }
        ) => {
          const prompt = await readText(parts, "prompt");
          const body: RemoteTaskRequest = { project: opts.project, prompt };
          if (opts.name) body.name = opts.name;
          if (opts.worktree !== undefined) body.worktree = opts.worktree === true ? "" : String(opts.worktree);
          if (opts.assistant) body.assistant = opts.assistant;
          if (opts.model) body.model = opts.model;
          if (opts.launch === false) body.launch = false;
          const card = await client().createTask(body);
          if (opts.json) return printJson(card);
          println(
            `Created ${card.id} "${card.title}" in ${card.projectName ?? opts.project} (${COLUMN_NAMES[card.column] ?? card.column}).\n` +
              (opts.launch === false
                ? `Launch it later with: kanban remote resume ${card.id}`
                : `Follow it with: kanban remote transcript ${card.id} --follow`)
          );
        }
      )
    );

  remote
    .command("send <card> <text...>")
    .description("Send a prompt to a card, delivered when its turn ends ('-' reads the text from stdin)")
    .option("--now", "interrupt the current turn and send at once")
    .option("--json", "output as JSON")
    .action(
      run(async (ref: string, parts: string[], opts: { now?: boolean; json?: boolean }) => {
        const text = await readText(parts, "text");
        const c = client();
        const card = await findCard(c, ref);
        const mode = opts.now ? "now" : "queue";
        await withConflictHint(card.id, () => c.prompt(card.id, { text, mode }));
        if (opts.json) return printJson({ ok: true, cardId: card.id, mode });
        println(
          opts.now
            ? `Sent to ${card.id} "${card.title}".`
            : `Queued for ${card.id} "${card.title}"${card.isBusy ? ", delivered when the turn ends" : ""}.`
        );
      })
    );

  remote
    .command("interrupt <card>")
    .description("Interrupt a card's current turn")
    .option("--json", "output as JSON")
    .action(
      run(async (ref: string, opts: { json?: boolean }) => {
        const c = client();
        const card = await findCard(c, ref);
        await withConflictHint(card.id, () => c.interrupt(card.id));
        if (opts.json) return printJson({ ok: true, cardId: card.id });
        println(`Interrupted ${card.id} "${card.title}".`);
      })
    );

  remote
    .command("resume <card>")
    .description("Start or resume a card's session on the Mac")
    .option("--json", "output as JSON")
    .action(
      run(async (ref: string, opts: { json?: boolean }) => {
        const c = client();
        const card = await findCard(c, ref);
        const resumed = await c.resume(card.id);
        if (opts.json) return printJson(resumed);
        println(`Resumed ${resumed.id} "${resumed.title}" (${cardState(resumed)}).`);
      })
    );

  // ── transcript / wait ──

  remote
    .command("transcript <card>")
    .description("Print a card's conversation, oldest first")
    .option("--limit <n>", "number of latest messages", parsePositiveInt("--limit"), 20)
    .option("--follow", "keep printing new messages until the card is idle again")
    .addOption(new Option("--interval <seconds>", "poll interval with --follow").argParser(parsePositiveInt("--interval")).default(3))
    .option("--timeout <duration>", "stop following after this long (90s, 15m, 2h)", parseTimeout)
    .option("--json", "output as JSON (one message per line with --follow)")
    .action(
      run(
        async (
          ref: string,
          opts: { limit: number; follow?: boolean; interval: number; timeout?: number; json?: boolean }
        ) => {
          const c = client();
          const card = await findCard(c, ref);
          const first = await c.transcript(card.id, { limit: opts.limit });
          if (!opts.follow) {
            if (opts.json) return printJson(first);
            if (first.messages.length === 0) return println("No messages yet.");
            return println(first.messages.map(formatMessage).join("\n"));
          }
          const seen = new Set<string>();
          const emit = (messages: RemoteMessage[]) => {
            for (const m of messages) {
              if (seen.has(m.id)) continue;
              seen.add(m.id);
              if (opts.json) io.out(JSON.stringify(m) + "\n");
              else println(formatMessage(m));
            }
          };
          emit(first.messages);
          const outcome = await waitForCard(c, card.id, io, {
            intervalMs: opts.interval * 1000,
            timeoutMs: opts.timeout,
            startGraceMs: 15_000,
            onPoll: async () => emit((await c.transcript(card.id, { limit: 200 })).messages),
          });
          if (outcome.timedOut) throw new RemoteCliError(`Still busy after the timeout.`, 124);
          if (!opts.json) io.err(`${card.id} is ${cardState(outcome.card)}.\n`);
        }
      )
    );

  remote
    .command("wait <card>")
    .description("Block until the card is idle (not in a turn, nothing queued); exit 124 on timeout")
    .option("--timeout <duration>", "give up after this long (90s, 15m, 2h)", parseTimeout)
    .addOption(new Option("--interval <seconds>", "poll interval").argParser(parsePositiveInt("--interval")).default(3))
    .option("--json", "print the final card as JSON")
    .action(
      run(async (ref: string, opts: { timeout?: number; interval: number; json?: boolean }) => {
        const c = client();
        const card = await findCard(c, ref);
        const outcome = await waitForCard(c, card.id, io, {
          intervalMs: opts.interval * 1000,
          timeoutMs: opts.timeout,
          startGraceMs: 15_000,
        });
        if (opts.json) printJson(outcome.card);
        if (outcome.timedOut) throw new RemoteCliError(`${card.id} is still busy after the timeout.`, 124);
        if (!opts.json) println(`${outcome.card.id} "${outcome.card.title}" is ${cardState(outcome.card)}.`);
      })
    );

  // ── pairing, on the Mac ──

  remote
    .command("pair")
    .description("On the Mac: add a device and print its token and pairing link")
    .requiredOption("--name <name>", "device name, e.g. iPhone or openclaw")
    .addOption(new Option("--scope <scope>", "full (phone) or agent").choices([...REMOTE_SCOPES]).default("full"))
    .option("--url <url>", `server URL in the link (default: the Mac's Tailscale name, port ${REMOTE_DEFAULT_PORT})`)
    .option("--json", "output as JSON")
    .action(
      run(async (opts: { name: string; scope: RemoteScope; url?: string; json?: boolean }) => {
        const path = remoteDevicesPath();
        const { device, token } = addDevice(opts.name, opts.scope, path);
        const url = opts.url ? normalizeUrl(opts.url) : defaultServerUrl();
        const link = pairingLink(url, token);
        if (opts.json) return printJson({ device, token, url, link, path });
        println(
          `Paired '${device.name}' (${device.id}), scope ${device.scope}.\n\n` +
            `Token (shown once): ${token}\n` +
            `Link: ${link}\n\n` +
            `On the other machine: kanban remote login ${url} --token ${token}\n` +
            `The Mac app answers only with Settings > Remote Control on.`
        );
      })
    );

  remote
    .command("devices")
    .description("On the Mac: list paired devices")
    .option("--json", "output as JSON")
    .action(
      run(async (opts: { json?: boolean }) => {
        const devices = listDevices(remoteDevicesPath()).map(({ tokenHash: _hash, ...rest }) => rest);
        if (opts.json) return printJson(devices);
        if (devices.length === 0) return println("No paired devices.");
        println(
          devices
            .map((d) => `${d.id}  ${pad(String(d.name), 20)} ${pad(String(d.scope), 6)} created ${d.createdAt}  last seen ${d.lastSeenAt ?? "never"}`)
            .join("\n")
        );
      })
    );

  remote
    .command("revoke <device>")
    .description("On the Mac: remove a paired device by id or name; its next request is refused")
    .option("--json", "output as JSON")
    .action(
      run(async (idOrName: string, opts: { json?: boolean }) => {
        let removed;
        try {
          removed = revokeDevice(idOrName, remoteDevicesPath());
        } catch (error) {
          throw new RemoteCliError((error as Error).message);
        }
        const { tokenHash: _hash, ...rest } = removed;
        if (opts.json) return printJson(rest);
        println(`Revoked '${removed.name}' (${removed.id}).`);
      })
    );

  return remote;
}

/**
 * Polls a card until it settles. A settled card that was never seen busy and
 * changed within the last `startGraceMs` may be a task still launching, so it
 * counts as finished only once that grace has passed.
 */
export async function waitForCard(
  c: RemoteClient,
  cardId: string,
  io: Pick<RemoteIO, "sleep" | "now">,
  opts: WaitOptions & { onPoll?: () => Promise<void> }
): Promise<{ card: RemoteCard; timedOut: boolean }> {
  const start = io.now();
  let seenBusy = false;
  for (;;) {
    if (opts.onPoll) await opts.onPoll();
    const card = await c.card(cardId);
    const now = io.now();
    if (!cardSettled(card)) {
      seenBusy = true;
    } else {
      const changedAt = Date.parse(card.lastActivity ?? card.updatedAt);
      const quietSince = Number.isFinite(changedAt) && now - changedAt >= opts.startGraceMs;
      if (seenBusy || quietSince || now - start >= opts.startGraceMs) return { card, timedOut: false };
    }
    if (opts.timeoutMs !== undefined && now - start >= opts.timeoutMs) return { card, timedOut: true };
    await io.sleep(opts.intervalMs);
  }
}
