/**
 * `kv`: secrets from the Kanban Code vault of the local master (docs/vault.md).
 *
 * The master (the Mac app or kanban-code-server) holds the secrets; kv asks
 * it over loopback for the ones a command needs. The master looks up the
 * calling process to find the card session it runs in, then decides: open
 * secrets come back at once, judged ones go past Jev, the rest wait for
 * Rogerio's approval on his phone or Mac. Values only ever reach the child
 * process environment (or stdout for `kv get`).
 */

import { spawn, spawnSync } from "node:child_process";
import { runScrub } from "./scrub.js";
import { existsSync, readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join, relative, resolve } from "node:path";
import { kanbanHome } from "./paths.js";
import { auditLines, auditProblems, ownerLines, type AuditReport, type OwnerStatus } from "./vault-owner.js";

export const EXIT_DENIED = 77;

export interface VaultResponse {
  status: "granted" | "pending" | "denied";
  message: string;
  id?: string;
  values?: Record<string, string>;
  skipped?: string[];
  credentials?: AwsProcessCredentials;
  card?: string;
  /** Values by environment variable: the manifest's KEY lines and the project's group. */
  env?: Record<string, string>;
  /** What was asked for -> the secret it resolved to (a dry-run rename: old name -> outcome). */
  resolved?: Record<string, string>;
}

export interface AwsProcessCredentials {
  Version: number;
  AccessKeyId: string;
  SecretAccessKey: string;
  SessionToken: string;
  Expiration: string;
}

export interface VaultSecretInfo {
  name: string;
  tier: "open" | "judged" | "ask" | "never";
  rules: string;
  leasePolicy: { leaseSeconds: number; everyUseAsks: boolean };
  tags: string[];
  sources: string[];
  updatedAt: string;
  aws?: { sourceSecret: string; roleArn?: string; policyArns: string[] } | null;
  label?: string | null;
  key?: string | null;
  project?: string | null;
  environment?: string | null;
  aliases?: string[] | null;
  displayLabel?: string | null;
  fingerprint?: string | null;
  /** The value opens only on the owner's Mac or phone. */
  sealed?: boolean | null;
}

export const DEFAULT_ENVIRONMENT = "dev";

/**
 * A secret name taken apart: `KEY` is shared, `project/environment/KEY`
 * belongs to a project (which may hold slashes for a subfolder).
 */
export function parseSecretName(name: string): { key: string; project?: string; environment?: string } {
  const parts = name.split("/");
  if (parts.length < 3 || parts.some((p) => !p)) return { key: name };
  return { key: parts[parts.length - 1], environment: parts[parts.length - 2], project: parts.slice(0, -2).join("/") };
}

/** "KEY · project · environment", or the name itself for a shared secret. */
export function secretDisplay(name: string): string {
  const { key, project, environment } = parseSecretName(name);
  return project ? `${key} · ${project} · ${environment}` : name;
}

export interface VaultAuditEntry {
  at: string;
  machine: string;
  cardId?: string;
  secret: string;
  tier?: string;
  outcome: string;
  decider: string;
  action: string;
  command?: string;
  reason?: string;
  detail?: string;
}

export class VaultCliError extends Error {
  constructor(message: string, readonly code = 1) {
    super(message);
  }
}

export interface VaultIO {
  env: NodeJS.ProcessEnv;
  fetch: typeof fetch;
  stderr: (text: string) => void;
  sleep: (ms: number) => Promise<void>;
  /** The value piped in, when it is not the process's own stdin. */
  stdin?: () => Promise<string>;
  /** Where results go, when it is not the process's own stdout. */
  stdout?: (text: string) => void;
}

export function defaultIO(): VaultIO {
  return {
    env: process.env,
    fetch: globalThis.fetch,
    stderr: (text) => process.stderr.write(text),
    sleep: (ms) => new Promise((r) => setTimeout(r, ms)),
  };
}

// ── Talking to the master ────────────────────────────────────────────

export function vaultBaseUrl(env: NodeJS.ProcessEnv = process.env): string {
  if (env.KANBAN_VAULT_URL) return env.KANBAN_VAULT_URL.replace(/\/+$/, "");
  let port = 7780;
  try {
    const settings = JSON.parse(readFileSync(join(kanbanHome(), "settings.json"), "utf8"));
    if (typeof settings?.remoteControl?.port === "number") port = settings.remoteControl.port;
  } catch {
    // default port
  }
  return `http://127.0.0.1:${port}`;
}

/** True when the request never reached the master (nothing listened). */
function neverArrived(error: unknown): boolean {
  const code = (error as { cause?: { code?: string } })?.cause?.code;
  return code === "ECONNREFUSED" || code === "ENOENT";
}

export class VaultClient {
  /**
   * How long a call waits out a master that does not answer (a deploy
   * restarts it), with backoff. 0 fails at once.
   */
  retryForMs = 120_000;

  constructor(
    readonly baseUrl: string,
    readonly io: VaultIO
  ) {}

  async call<T>(method: string, path: string, body?: unknown): Promise<{ status: number; body: T }> {
    let res: Response | undefined;
    let waited = 0;
    let delay = 1000;
    let noted = false;
    for (;;) {
      let failure: string | undefined;
      try {
        // The card session's token places a process that left the session's
        // process tree; the master ignores it when the ancestry already does.
        const token = this.io.env.KANBAN_CARD_TOKEN;
        res = await this.io.fetch(`${this.baseUrl}/v1/vault/${path}`, {
          method,
          headers: {
            ...(body === undefined ? {} : { "Content-Type": "application/json" }),
            ...(token ? { "X-Kanban-Card-Token": token } : {}),
          },
          body: body === undefined ? undefined : JSON.stringify(body),
        });
        if (res.status === 502 || res.status === 503) failure = `HTTP ${res.status}`;
      } catch (error) {
        failure = (error as Error).message;
        // A request that may have reached the master is not sent twice:
        // only a GET, or a connection nothing accepted, is retried.
        if (method !== "GET" && !neverArrived(error)) waited = Infinity;
      }
      if (failure === undefined && res) break;
      if (waited >= this.retryForMs) {
        throw new VaultCliError(
          `kv: cannot reach the Kanban Code master at ${this.baseUrl} (${failure}).\n` +
            "On the Mac the app must run with Settings > Remote Control on; on a server, kanban-code-server."
        );
      }
      if (!noted) {
        noted = true;
        this.io.stderr(
          `kv: the master at ${this.baseUrl} is not answering (${failure}), probably restarting; waiting up to ${Math.round(this.retryForMs / 60_000)} min...\n`
        );
      }
      const step = Math.min(delay, this.retryForMs - waited);
      await this.io.sleep(step);
      waited += step;
      delay = Math.min(delay * 2, 10_000);
    }
    if (noted) this.io.stderr("kv: the master is back.\n");
    if (!res) throw new VaultCliError(`kv: no answer from ${this.baseUrl}`);
    const text = await res.text();
    let parsed: unknown;
    try {
      parsed = text ? JSON.parse(text) : {};
    } catch {
      throw new VaultCliError(`kv: the master answered HTTP ${res.status} with something unreadable`);
    }
    const err = (parsed as { error?: string }).error;
    if (err && res.status >= 400 && res.status !== 403) throw new VaultCliError(`kv: ${err}`);
    return { status: res.status, body: parsed as T };
  }

  /** Sends a vault request and waits out a pending approval. */
  async decide(path: string, body: unknown): Promise<VaultResponse> {
    let { body: r } = await this.call<VaultResponse>("POST", path, body);
    if (r.status !== "pending") return r;
    this.io.stderr(`kv: ${r.message}...\n`);
    const started = Date.now();
    let lastNote = started;
    for (let polls = 0; r.status === "pending" && r.id; polls++) {
      await this.io.sleep(pendingPollDelay(polls));
      r = (await this.call<VaultResponse>("GET", `pending/${encodeURIComponent(r.id)}`)).body;
      if (r.status === "pending" && Date.now() - lastNote > 60_000) {
        lastNote = Date.now();
        this.io.stderr(`kv: still waiting (${Math.round((Date.now() - started) / 60_000)} min)...\n`);
      }
    }
    if (r.status === "granted") this.io.stderr("kv: approved.\n");
    return r;
  }
}

/** How long to wait before poll number `polls` of a pending request: an answer within the first minute is picked up in half a second. */
export function pendingPollDelay(polls: number): number {
  return polls < 120 ? 500 : 1500;
}

export function callerContext(env: NodeJS.ProcessEnv): { cardId?: string; sessionId?: string; cwd: string } {
  return {
    cardId: env.KANBAN_CARD_ID || undefined,
    sessionId: env.KANBAN_SESSION_ID || env.CLAUDE_SESSION_ID || undefined,
    cwd: process.cwd(),
  };
}

/**
 * The vault's own refusal, as it gave it (Jev's verdict with the secret's
 * rules, a human's no, a tier rule). The reason-writing help is only for
 * reasons kv itself refuses (`checkedReason`), not for these.
 */
export function deniedError(r: VaultResponse): VaultCliError {
  const hint = r.message.includes("kv request")
    ? ""
    : `\nIf the work needs it anyway, ask Rogerio: kv request NAME --reason "<one plain sentence>"`;
  return new VaultCliError(`kv: ${r.message}${hint}`, EXIT_DENIED);
}

// ── Reasons ──────────────────────────────────────────────────────────

/**
 * Rogerio reads the reason alone on his phone, under a title naming the
 * card and the secret. Same rules as `AttentionCopy.reasonProblem` in
 * KanbanCodeRemoteKit.
 */
export const REASON_GUIDANCE =
  "Write --reason as one short plain sentence a human understands on a phone: what you want to do and why.\n" +
  '  Good: --reason "Deploy the langwatch staging app to check the fix for the login bug"\n' +
  '  Bad:  --reason "change aws:lw-dev: rules" (too terse), --reason "kubectl apply -f x.yaml" (a command)';

export type ReasonProblem = "missing" | "tooShort" | "looksLikeCommand" | "tooLong";

const COMMAND_STARTS = new Set([
  "sudo", "kv", "aws", "curl", "wget", "npm", "pnpm", "yarn", "npx", "git", "gh", "kubectl", "helm",
  "docker", "terraform", "python", "python3", "node", "bash", "sh", "zsh", "export", "cd", "make",
  "swift", "cargo", "go", "ssh", "scp", "psql", "wrangler", "uv", "pip", "echo", "cat", "env",
]);

export function reasonProblem(reason: string | undefined): ReasonProblem | undefined {
  const text = (reason ?? "").trim();
  if (!text) return "missing";
  if (text.includes("\n") || [...text].length > 200) return "tooLong";
  const words = text.split(/\s+/);
  if (COMMAND_STARTS.has(words[0].toLowerCase())) return "looksLikeCommand";
  if (/(^|\s)--?[A-Za-z]/.test(text) || /[|;&`$<>{}]/.test(text)) return "looksLikeCommand";
  if (words.length < 4) return "tooShort";
  return undefined;
}

const PROBLEM_TEXT: Record<ReasonProblem, string> = {
  missing: "this needs a reason",
  tooShort: "the reason is too short to tell a human what you are doing",
  looksLikeCommand: "the reason reads like a command; the command is shown separately",
  tooLong: "the reason must be one short sentence",
};

/** The reason to send: `--reason`, else KV_REASON; refused when a human could not read it. */
export function checkedReason(given: string | undefined, env: NodeJS.ProcessEnv, required: boolean): string | undefined {
  const reason = given ?? (env.KV_REASON || undefined);
  const problem = reasonProblem(reason);
  if (!problem || (problem === "missing" && !required)) return reason?.trim() || undefined;
  const got = reason?.trim() ? `\n  Got: ${JSON.stringify(reason.trim())}` : "";
  throw new VaultCliError(`kv: ${PROBLEM_TEXT[problem]}.${got}\n${REASON_GUIDANCE}`, 2);
}

// ── Commands and files ───────────────────────────────────────────────

/** Quotes a word for POSIX shells: safe to paste back as one argument. */
export function shellQuote(word: string): string {
  if (/^[A-Za-z0-9_\-./=:@%+,]+$/.test(word)) return word;
  return `'${word.replace(/'/g, `'\\''`)}'`;
}

export function commandLine(argv: string[]): string {
  return argv.map(shellQuote).join(" ");
}

export interface EnvVaultEntry {
  key: string;
  /** Vault secret name for `KEY={{vault:NAME}}`; undefined for a plain value. */
  secret?: string;
  value?: string;
  /** A bare `KEY` line: the project's value for the environment, else the shared one. */
  bare?: boolean;
}

/**
 * Reads a `.env.vault` manifest: a bare `KEY` line takes the project's
 * secret for the environment (else the shared one), `KEY={{vault:NAME}}`
 * names a secret, other `KEY=value` lines pass through.
 */
export function parseEnvVault(text: string): EnvVaultEntry[] {
  const out: EnvVaultEntry[] = [];
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    const bare = /^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)$/.exec(line);
    if (bare) {
      out.push({ key: bare[1], bare: true });
      continue;
    }
    const m = /^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/.exec(line);
    if (!m) continue;
    let value = m[2].trim();
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    }
    const ref = /^\{\{\s*vault:([A-Za-z0-9_\-./:]+)\s*\}\}$/.exec(value);
    out.push(ref ? { key: m[1], secret: ref[1] } : { key: m[1], value });
  }
  return out;
}

/**
 * The environment a manifest gives: the project's group and bare keys
 * (`projectEnv`), then the manifest's own lines, which win.
 */
export function envFromVault(
  entries: EnvVaultEntry[],
  values: Record<string, string>,
  projectEnv: Record<string, string> = {}
): Record<string, string> {
  const env: Record<string, string> = { ...projectEnv };
  for (const e of entries) {
    if (e.bare) continue;
    if (e.secret) {
      if (values[e.secret] !== undefined) env[e.key] = values[e.secret];
    } else if (e.value !== undefined) {
      env[e.key] = e.value;
    }
  }
  return env;
}

/**
 * The nearest `.env.vault` from `dir` up to the repository root (or home).
 * In a linked git worktree without its own, the same folder of the main
 * checkout is searched, since worktrees get `.env` copies but rarely the
 * `.env.vault` next to them.
 */
export function findEnvVault(dir: string, home = homedir(), name = ".env.vault"): string | undefined {
  const start = resolve(dir);
  let current = start;
  for (let i = 0; i < 64; i++) {
    const candidate = join(current, name);
    if (existsSync(candidate)) return candidate;
    const git = join(current, ".git");
    if (existsSync(git)) {
      const main = mainCheckoutOf(git);
      return main ? findEnvVault(join(main, relative(current, start)), home, name) : undefined;
    }
    if (current === home) return undefined;
    const parent = dirname(current);
    if (parent === current) return undefined;
    current = parent;
  }
  return undefined;
}

/** The manifest file name of an environment: `.env.vault` for dev, `.env.<environment>.vault` otherwise. */
export function manifestName(environment: string): string {
  return environment === DEFAULT_ENVIRONMENT ? ".env.vault" : `.env.${environment}.vault`;
}

/** The environment a manifest file is for: `.env.vault` is dev, `.env.prod.vault` is prod. */
export function environmentOf(file: string): string {
  const m = /^\.env\.(.+)\.vault$/.exec(basename(file));
  return m ? m[1] : DEFAULT_ENVIRONMENT;
}

/**
 * The body of a release for a manifest (or for a folder without one): its
 * named secrets, its bare keys, and the group of the folder's project.
 */
export function manifestRequest(
  file: string | undefined,
  options: { cwd: string; environment?: string; project?: string }
): { entries: EnvVaultEntry[]; body: Record<string, unknown> } {
  const entries = file ? parseEnvVault(readFileSync(file, "utf8")) : [];
  return {
    entries,
    body: {
      names: [...new Set(entries.filter((e) => e.secret).map((e) => e.secret!))],
      keys: [...new Set(entries.filter((e) => e.bare).map((e) => e.key))],
      defined: [...new Set(entries.filter((e) => !e.bare).map((e) => e.key))],
      group: true,
      // A manifest's folder is its own project; without one the group is
      // that of the nearest project up from here that has secrets.
      nearest: !file,
      dir: file ? dirname(resolve(file)) : options.cwd,
      project: options.project,
      environment: options.environment ?? (file ? environmentOf(file) : DEFAULT_ENVIRONMENT),
    },
  };
}

/** The main checkout of a linked worktree, from its `.git` file (`gitdir: <main>/.git/worktrees/<name>`). */
function mainCheckoutOf(git: string): string | undefined {
  try {
    if (!statSync(git).isFile()) return undefined;
    const m = /^gitdir:\s*(.+?)\/\.git\/worktrees\/[^/\n]+\s*$/m.exec(readFileSync(git, "utf8"));
    return m ? m[1] : undefined;
  } catch {
    return undefined;
  }
}

export function exportLines(env: Record<string, string>): string {
  return Object.entries(env)
    .map(([k, v]) => `export ${k}=${shellQuote(v)}`)
    .join("\n");
}

/**
 * The PreToolUse hook's answer for a Bash call: when the session's project
 * has a `.env.vault`, the command first loads the vault env into its own
 * shell, so `cd` and shell syntax keep working as written.
 */
/**
 * The PreToolUse answer that makes a Bash command load the vault env first.
 * Codex applies `updatedInput` only next to `permissionDecision: "allow"`,
 * which there does not skip its own approval or sandbox; Claude Code takes
 * `updatedInput` alone, where "allow" would skip the permission prompt.
 */
export function hookRewrite(
  input: { tool_name?: string; tool_input?: { command?: string }; cwd?: string },
  kvPath: string,
  harness: "claude" | "codex" = "claude"
): unknown {
  if (input.tool_name !== "Bash") return undefined;
  const command = input.tool_input?.command;
  if (!command || command.includes("__kv_env=")) return undefined;
  const file = findEnvVault(input.cwd || process.cwd());
  if (!file) return undefined;
  const b64 = Buffer.from(command, "utf8").toString("base64");
  const wrapped =
    `__kv_env="$(${shellQuote(kvPath)} env ${shellQuote(file)} --export --command-b64 ${b64})" || exit $?\n` +
    `eval "$__kv_env"; unset __kv_env\n` +
    command;
  return {
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      ...(harness === "codex" ? { permissionDecision: "allow" } : {}),
      updatedInput: { ...input.tool_input, command: wrapped },
    },
  };
}

/**
 * The answer of an OpenClaw `exec` SecretRef provider (protocol 1): every
 * requested id is a vault secret name. Nothing waits on a human here: a
 * secret that needs approval comes back as an error, and the approval
 * request stays open so the next `openclaw secrets reload` can succeed.
 */
export async function execProviderAnswer(
  client: VaultClient,
  request: { protocolVersion?: number; provider?: string; ids?: unknown },
  ctx: { cardId?: string; sessionId?: string; cwd: string }
): Promise<{ protocolVersion: 1; values: Record<string, string>; errors?: Record<string, { code: string }> }> {
  const ids = Array.isArray(request.ids) ? request.ids.filter((id): id is string => typeof id === "string") : [];
  const values: Record<string, string> = {};
  const errors: Record<string, { code: string }> = {};
  for (const id of ids) {
    try {
      const { body: r } = await client.call<VaultResponse>("POST", "release", {
        mode: "get",
        names: [id],
        command: `exec SecretRef ${request.provider ?? "kv"}:${id}`,
        reason: `OpenClaw resolves its ${id} SecretRef`,
        ...ctx,
      });
      if (r.status === "granted" && typeof r.values?.[id] === "string") values[id] = r.values[id];
      else if (/^no secret named/.test(r.message ?? "")) errors[id] = { code: "NOT_FOUND" };
      else errors[id] = { code: r.status === "pending" ? "NEEDS_APPROVAL" : "DENIED" };
    } catch {
      errors[id] = { code: "UNREACHABLE" };
    }
  }
  return { protocolVersion: 1, values, ...(Object.keys(errors).length ? { errors } : {}) };
}

/** One process of the caller's ancestry. */
export interface ProcessInfo {
  ppid: number;
  args: string;
}

function readProcess(pid: number): ProcessInfo | undefined {
  const r = spawnSync("ps", ["-o", "ppid=,args=", "-p", String(pid)], { encoding: "utf8" });
  const m = r.status === 0 ? /^\s*(\d+)\s+(.*)$/s.exec(r.stdout.trim()) : null;
  return m ? { ppid: Number(m[1]), args: m[2].trim() } : undefined;
}

/** Programs that start commands rather than being one: the walk up the ancestry stops there. */
const NOT_A_COMMAND = new Set([
  "sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh", "login", "sshd", "tmux", "screen", "launchd", "init",
  "systemd", "claude", "codex", "rush", "agtop", "node", "env", "sudo", "nohup", "setsid", "timeout", "xargs",
]);

function programName(args: string): string {
  const first = args.trim().split(/\s+/)[0] ?? "";
  return basename(first).replace(/^-/, "");
}

/**
 * The command a human would recognise as what asked for the secret: the
 * outermost tool above kv, below the shell or assistant that started it.
 * `kubectl get pods` runs `aws eks get-token`, which runs `kv aws` as its
 * `credential_process`: the answer is "kubectl get pods (through aws eks
 * get-token ...)". `commands` are the ancestors' command lines, nearest first.
 */
export function describeInvoker(commands: string[]): string | undefined {
  const chain: string[] = [];
  for (const args of commands) {
    if (!args || NOT_A_COMMAND.has(programName(args))) break;
    chain.push(args);
  }
  if (chain.length === 0) return commands[0] || undefined;
  const outer = chain[chain.length - 1];
  if (chain.length === 1) return outer;
  const inner = chain[0].length > 160 ? `${chain[0].slice(0, 160)}...` : chain[0];
  return `${outer}  (through: ${inner})`;
}

/** The invoking command of this kv process, from its ancestry (at most 8 levels). */
export function invokingCommand(
  pid: number = process.ppid,
  read: (pid: number) => ProcessInfo | undefined = readProcess
): string | undefined {
  const commands: string[] = [];
  for (let current = pid, depth = 0; current > 1 && depth < 8; depth++) {
    const info = read(current);
    if (!info) break;
    commands.push(info.args);
    // Past the shell or assistant that started it there is nothing to show.
    if (NOT_A_COMMAND.has(programName(info.args))) break;
    current = info.ppid;
  }
  return describeInvoker(commands);
}

function readStdin(): Promise<string> {
  return new Promise((resolveText) => {
    let data = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (chunk) => (data += chunk));
    process.stdin.on("end", () => resolveText(data));
  });
}

async function readSecretFromStdin(name: string): Promise<string> {
  if (!process.stdin.isTTY) return (await readStdin()).replace(/\r?\n$/, "");
  process.stderr.write(`Value for ${name} (not shown): `);
  return new Promise((resolveValue) => {
    const stdin = process.stdin;
    stdin.setRawMode(true);
    stdin.resume();
    stdin.setEncoding("utf8");
    let value = "";
    const onData = (ch: string) => {
      for (const c of ch) {
        if (c === "\r" || c === "\n" || c === "\u0004") {
          stdin.setRawMode(false);
          stdin.pause();
          stdin.off("data", onData);
          process.stderr.write("\n");
          resolveValue(value);
          return;
        }
        if (c === "\u0003") process.exit(130);
        if (c === "\u007f") value = value.slice(0, -1);
        else value += c;
      }
    };
    stdin.on("data", onData);
  });
}

function runChild(argv: string[], extraEnv: Record<string, string>): Promise<number> {
  if (argv.length === 0) throw new VaultCliError("kv: give the command after --");
  return new Promise((resolveCode) => {
    const child = spawn(argv[0], argv.slice(1), { stdio: "inherit", env: { ...process.env, ...extraEnv } });
    for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"] as const) {
      process.on(sig, () => child.kill(sig));
    }
    child.on("error", (e) => {
      process.stderr.write(`kv: could not run ${argv[0]}: ${e.message}\n`);
      resolveCode(127);
    });
    child.on("exit", (code, signal) => resolveCode(code ?? (signal ? 128 + 15 : 1)));
  });
}

function splitAtDashes(args: string[]): { before: string[]; after: string[] } {
  const i = args.indexOf("--");
  return i < 0 ? { before: args, after: [] } : { before: args.slice(0, i), after: args.slice(i + 1) };
}

function takeOption(args: string[], name: string): string | undefined {
  const i = args.indexOf(name);
  if (i < 0) return undefined;
  const value = args[i + 1];
  args.splice(i, 2);
  return value;
}

function takeFlag(args: string[], name: string): boolean {
  const i = args.indexOf(name);
  if (i < 0) return false;
  args.splice(i, 1);
  return true;
}

/** `--every-use-asks` (no card lease, each use asks) or `--leases` (card leases up to 2 days again). */
export function leasePolicyFlags(args: string[]): { leaseSeconds: number; everyUseAsks: boolean } | undefined {
  const everyUse = takeFlag(args, "--every-use-asks");
  const leases = takeFlag(args, "--leases");
  if (everyUse && leases) throw new VaultCliError("kv: --every-use-asks and --leases contradict each other");
  if (!everyUse && !leases) return undefined;
  return { leaseSeconds: 2 * 24 * 3600, everyUseAsks: everyUse };
}

function takeAll(args: string[], name: string): string[] {
  const out: string[] = [];
  for (let v = takeOption(args, name); v !== undefined; v = takeOption(args, name)) out.push(v);
  return out;
}

export const USAGE = `kv: secrets from the Kanban Code vault

  kv run NAME [NAME..] [--reason "..."] -- <cmd> [args..]   run cmd with the secrets in its env
  kv env [<.env.vault>] [--env dev|prod|..] [--project P] [--reason "..."] -- <cmd> [args..]
                                                            run cmd with the project's secrets for the environment
                                                            plus the manifest's lines; --names lists them instead
  kv get NAME [--reason "..."]                              print one secret (never one that asks)
  kv request NAME[:scope] [NAME..] --reason "..."           ask once for the card's whole task (2 days)
  kv aws <profile> [--reason "..."]                         AWS credential_process JSON (short-lived STS credentials,
                                                            minted on Rogerio's Mac or phone when he approves)
  kv set KEY [--project P|.] [--env E] [--tier open|judged|ask|never] [--rules "..."] [--label "..."] [--tag t]
         [--reason "..."] [--every-use-asks]                value from stdin; with --project the secret is the
                                                            project's own (. is this folder's), else shared.
                                                            kv add is the same command
  kv same KEY [--project P|.] [--env E]                     value from stdin; prints same, different or absent for
                                                            the secret stored under that name, and changes no secret
  kv ls [--project P] [--json]                              names, tiers and rules
  kv mv OLD NEW [--reason "..."]                            rename; the old name keeps resolving (asks Rogerio)
  kv mv --plan <file.json> [--dry-run] --reason "..."       many renames ([{"from","to"}]), one approval
  kv rm NAME [NAME..] --reason "..."                         delete secrets (asks Rogerio, one approval)
  kv rm --plan <file> [--dry-run] --reason "..."            the names from a file: a JSON array or one per line
  kv log [--card ID] [--secret NAME] [--limit N] [--json]   the audit log, newest first
  kv leases [--card ID]                                     active card leases
  kv tier NAME <tier> [--every-use-asks|--leases] | kv rules NAME "..." | kv label NAME "..."  [--reason "..."]
                                                            change a secret (asks Rogerio)
  kv tiers <tier> [NAME..] [--value-prefix P].. [--every-use-asks|--leases] --reason "..."
                                                            one change to many secrets, one approval
  kv status                                                 is the vault unlocked here
  kv owner [--json]                                         the keys that open the ask and never secrets
  kv audit check [--json]                                   audit log: broken chain, lines missing on a machine
                                                            (exit 1 on a problem; run it on the Mac)
  kv scrub [--dry-run] [--status] [--all] [--json]          replace secrets in this machine's transcripts with
                                                            {{vault:NAME}} references (dry run: counts only)
  kv scrub --at HH:MM | --on | --off                        the daily run, on every master
  kv scrub --add <path> | --remove <path>                   extra files and folders it reads, on every master
  kv scrub --patterns typed|on|off                          keys the vault does not hold: typed = only ones you typed in a chat (default), on = all, off = none
  kv scrub [--dry-run] --once on|typed|off [--except V,..]  one run in another patterns mode, leaving the keys of the named vendors (LANGWATCH_API_KEY); the schedule is unchanged
  kv scrub --restore <file>... | --restore --all-files      write back what the runs of the last week replaced
  kv exec-provider                                          OpenClaw exec SecretRef provider (JSON on stdin)
  kv import [--apply] [--secrets-only] [--only <dir>]..   plan (then do) the migration of plaintext secrets

Names: KEY is a shared secret, project/environment/KEY is a project's own (the
project is the repository folder name, plus the subfolder; dev unless said).
A .env.vault manifest lists what the project's own secrets do not cover: a bare
KEY line (the project's value, else the shared one), KEY={{vault:NAME}} for
another name, KEY=value for plain config. .env.prod.vault is the prod manifest.

When Rogerio has to approve, his phone shows "<card> wants to use <secret>"
and under it only your reason. ${REASON_GUIDANCE}
KV_REASON in the environment is used when --reason is not given. Set it on
every aws, kubectl, helm or terraform command, which reach kv aws through
credential_process and cannot pass --reason:
  KV_REASON="Check the dev cluster pods after the nlpgo deploy" kubectl get pods

Exit code ${EXIT_DENIED} means the vault denied the request; 2 means kv refused the reason.`;

export async function runKv(argv: string[], io: VaultIO = defaultIO()): Promise<number> {
  const [cmd, ...rest] = argv;
  const args = [...rest];
  const client = new VaultClient(vaultBaseUrl(io.env), io);
  const ctx = callerContext(io.env);
  const out = io.stdout ?? ((text: string) => process.stdout.write(text));

  switch (cmd) {
    case undefined:
    case "-h":
    case "--help":
    case "help":
      out(USAGE + "\n");
      return 0;

    case "run": {
      const { before, after } = splitAtDashes(args);
      const reason = checkedReason(takeOption(before, "--reason"), io.env, false);
      if (before.length === 0) throw new VaultCliError("kv run NAME [NAME..] -- <cmd>");
      const r = await client.decide("release", { mode: "run", names: before, command: commandLine(after), reason, ...ctx });
      if (r.status !== "granted") throw deniedError(r);
      return runChild(after, r.values ?? {});
    }

    case "env": {
      const { before, after } = splitAtDashes(args);
      const givenReason = takeOption(before, "--reason");
      const exportMode = takeFlag(before, "--export");
      const namesOnly = takeFlag(before, "--names");
      const environment = takeOption(before, "--env");
      const project = takeOption(before, "--project");
      // A hook-wrapped command never asks a human, so it carries no reason.
      const reason = exportMode ? givenReason : checkedReason(givenReason, io.env, false);
      const b64 = takeOption(before, "--command-b64");
      if (before[0] && !existsSync(before[0])) throw new VaultCliError(`kv: no file ${before[0]}`);
      // Without a file: the manifest of the environment up from here, else the project's group alone.
      const file = before[0] ?? findEnvVault(ctx.cwd, homedir(), manifestName(environment ?? DEFAULT_ENVIRONMENT));
      const { entries, body } = manifestRequest(file, { cwd: ctx.cwd, environment, project });
      if (namesOnly) {
        const { body: r } = await client.call<VaultResponse>("POST", "resolve", { mode: "env", ...body, cwd: ctx.cwd });
        if (r.status !== "granted") throw deniedError(r);
        const resolved = r.resolved ?? {};
        const lines = new Map<string, string>();
        for (const [asked, name] of Object.entries(resolved)) {
          if (!entries.some((e) => e.secret === asked && !e.bare)) lines.set(asked, name);
        }
        for (const e of entries) {
          if (e.secret) lines.set(e.key, resolved[e.secret] ?? e.secret);
          else if (!e.bare) lines.set(e.key, "(plain value)");
        }
        for (const key of [...lines.keys()].sort()) out(`${key}\t${lines.get(key)}\n`);
        return 0;
      }
      const command = b64 ? Buffer.from(b64, "base64").toString("utf8") : commandLine(after);
      let r: VaultResponse;
      try {
        r = await client.decide("release", { mode: exportMode ? "hook" : "env", ...body, command, reason, ...ctx });
      } catch (error) {
        // A wrapped command still runs when the master is down: it just gets no vault env.
        if (!exportMode) throw error;
        io.stderr(`${(error as Error).message.split("\n")[0]} (running without the vault env)\n`);
        return 0;
      }
      if (r.status !== "granted") throw deniedError(r);
      const skipped = r.skipped ?? [];
      const keyOf = (asked: string) => entries.find((e) => e.secret === asked)?.key ?? asked;
      const mentioned = skipped.filter((asked) => command.includes(keyOf(asked)));
      if (!exportMode && skipped.length) io.stderr(`kv: ${r.message}\n`);
      else if (mentioned.length) {
        const names = mentioned.map((asked) => r.resolved?.[asked] ?? asked);
        io.stderr(`kv: ${mentioned.map(keyOf).join(", ")} need approval and were left out: kv request ${names.join(" ")} --reason "..."\n`);
      }
      const env = envFromVault(entries, r.values ?? {}, r.env ?? {});
      if (exportMode) {
        out(exportLines(env) + "\n");
        return 0;
      }
      return runChild(after, env);
    }

    case "get": {
      const reason = checkedReason(takeOption(args, "--reason"), io.env, false);
      const name = args[0];
      if (!name) throw new VaultCliError("kv get NAME");
      const r = await client.decide("release", { mode: "get", names: [name], command: invokingCommand(), reason, ...ctx });
      if (r.status !== "granted") throw deniedError(r);
      out((r.values ?? {})[name] ?? "");
      if (process.stdout.isTTY) out("\n");
      return 0;
    }

    case "request": {
      const given = takeOption(args, "--reason");
      if (args.length === 0) throw new VaultCliError('kv request NAME[:scope] [NAME..] --reason "<one plain sentence>"');
      const reason = checkedReason(given, io.env, true);
      const r = await client.decide("request", { names: args, reason, ...ctx });
      if (r.status !== "granted") throw deniedError(r);
      io.stderr(`kv: ${r.message}\n`);
      return 0;
    }

    case "aws": {
      const reason = checkedReason(takeOption(args, "--reason"), io.env, false);
      const profile = args[0];
      if (!profile) throw new VaultCliError("kv aws <profile>");
      const r = await client.decide("aws", { mode: "aws", names: [profile], command: invokingCommand(), reason, ...ctx });
      if (r.status !== "granted" || !r.credentials) throw deniedError(r);
      out(JSON.stringify(r.credentials) + "\n");
      return 0;
    }

    case "add":
    case "set": {
      const project = takeOption(args, "--project");
      const environment = takeOption(args, "--env");
      if (environment && !project) throw new VaultCliError("kv: --env needs --project (a shared secret has no environment)");
      const tier = takeOption(args, "--tier");
      const rules = takeOption(args, "--rules");
      const tags = takeAll(args, "--tag");
      const label = takeOption(args, "--label");
      const leasePolicy = leasePolicyFlags(args);
      const reason = checkedReason(takeOption(args, "--reason"), io.env, false);
      const name = args[0];
      if (!name) throw new VaultCliError("kv set KEY [--project P|.] [--env E] [--tier t] [--rules '...'] [--every-use-asks]  (value on stdin)");
      const value = await readSecretFromStdin(name);
      if (!value) throw new VaultCliError("kv: empty value, nothing added");
      const { body } = await client.call<VaultResponse>("POST", `secrets${ctx.cardId ? `?card=${ctx.cardId}` : ""}`, {
        name,
        value,
        tier,
        rules,
        label,
        reason,
        leasePolicy,
        tags: tags.length ? tags : undefined,
        project,
        environment,
        dir: ctx.cwd,
      });
      const r = body.status === "pending" ? await waitPending(client, body) : body;
      if (r.status !== "granted") throw deniedError(r);
      io.stderr(`kv: ${r.message}\n`);
      return 0;
    }

    case "same": {
      const project = takeOption(args, "--project");
      const environment = takeOption(args, "--env");
      const name = args[0];
      if (!name) throw new VaultCliError("kv same KEY [--project P|.] [--env E]  (value on stdin)");
      const value = io.stdin ? (await io.stdin()).replace(/\r?\n$/, "") : await readSecretFromStdin(name);
      if (!value) throw new VaultCliError("kv: empty value, nothing to compare");
      const { body } = await client.call<{ name: string; outcome: string }>("POST", "compare", {
        name,
        value,
        project,
        environment,
        dir: ctx.cwd,
      });
      out(`${body.outcome}\n`);
      return 0;
    }

    case "tiers": {
      const reason = checkedReason(takeOption(args, "--reason"), io.env, true);
      const valuePrefixes = takeAll(args, "--value-prefix");
      const leasePolicy = leasePolicyFlags(args);
      const [tier, ...names] = args;
      if (!tier || (names.length === 0 && valuePrefixes.length === 0)) {
        throw new VaultCliError('kv tiers <tier> [NAME..] [--value-prefix P].. [--every-use-asks|--leases] --reason "..."');
      }
      const { body } = await client.call<VaultResponse>("PATCH", "secrets", {
        names,
        valuePrefixes,
        edit: { tier, leasePolicy, reason },
      });
      const r = body.status === "pending" ? await waitPending(client, body) : body;
      if (r.status !== "granted") throw deniedError(r);
      io.stderr(`kv: ${r.message}\n`);
      return 0;
    }

    case "tier":
    case "rules":
    case "label": {
      const reason = checkedReason(takeOption(args, "--reason"), io.env, false);
      const leasePolicy = cmd === "tier" ? leasePolicyFlags(args) : undefined;
      const [name, value] = args;
      if (!name || value === undefined) throw new VaultCliError(`kv ${cmd} NAME <value> [--reason "..."]`);
      const patch = { [cmd]: value, reason, leasePolicy };
      const { body } = await client.call<VaultResponse>("PATCH", `secrets/${encodeURIComponent(name)}`, patch);
      const r = body.status === "pending" ? await waitPending(client, body) : body;
      if (r.status !== "granted") throw deniedError(r);
      io.stderr(`kv: ${r.message}\n`);
      return 0;
    }

    case "mv": {
      const reason = checkedReason(takeOption(args, "--reason"), io.env, false);
      const dryRun = takeFlag(args, "--dry-run");
      const plan = takeOption(args, "--plan");
      let renames: Array<{ from: string; to: string }>;
      if (plan) {
        renames = JSON.parse(readFileSync(plan, "utf8"));
      } else {
        if (args.length !== 2) throw new VaultCliError('kv mv OLD NEW [--reason "..."]  |  kv mv --plan <file.json> [--dry-run]');
        renames = [{ from: args[0], to: args[1] }];
      }
      const { body } = await client.call<VaultResponse>("POST", `rename${ctx.cardId ? `?card=${ctx.cardId}` : ""}`, {
        renames,
        reason,
        dryRun,
      });
      const r = body.status === "pending" ? await waitPending(client, body) : body;
      if (r.status !== "granted") throw deniedError(r);
      if (dryRun || plan) out(JSON.stringify(r.resolved ?? {}, null, 2) + "\n");
      io.stderr(`kv: ${r.message}\n`);
      return 0;
    }

    case "rm": {
      const reason = checkedReason(takeOption(args, "--reason"), io.env, true);
      const dryRun = takeFlag(args, "--dry-run");
      const plan = takeOption(args, "--plan");
      const names = plan ? readNamePlan(readFileSync(plan, "utf8")) : args;
      if (names.length === 0) {
        throw new VaultCliError('kv rm NAME [NAME..] --reason "..."  |  kv rm --plan <file> [--dry-run] --reason "..."');
      }
      const { body } = await client.call<VaultResponse>("POST", `delete${ctx.cardId ? `?card=${ctx.cardId}` : ""}`, {
        names,
        reason,
        dryRun,
      });
      const r = body.status === "pending" ? await waitPending(client, body) : body;
      if (r.status !== "granted") throw deniedError(r);
      if (dryRun || plan) out(JSON.stringify(r.resolved ?? {}, null, 2) + "\n");
      io.stderr(`kv: ${r.message}\n`);
      return 0;
    }

    case "ls": {
      const json = takeFlag(args, "--json");
      const project = takeOption(args, "--project");
      const { body } = await client.call<VaultSecretInfo[]>(
        "GET",
        `secrets${project ? `?project=${encodeURIComponent(project)}` : ""}`
      );
      if (json) {
        out(JSON.stringify(body, null, 2) + "\n");
        return 0;
      }
      const width = Math.max(4, ...body.map((s) => s.name.length));
      for (const s of body) {
        const lease = s.leasePolicy.everyUseAsks ? " every use asks" : "";
        const label = s.project ? `  ${s.displayLabel ?? secretDisplay(s.name)}` : "";
        const sealed = s.sealed ? " sealed" : "";
        out(`${s.name.padEnd(width)}  ${s.tier.padEnd(6)}${sealed}${lease}${label}${s.rules ? `  ${s.rules.slice(0, 80)}` : ""}\n`);
      }
      return 0;
    }

    case "log": {
      const json = takeFlag(args, "--json");
      const q = new URLSearchParams();
      const card = takeOption(args, "--card");
      const secret = takeOption(args, "--secret");
      q.set("limit", takeOption(args, "--limit") ?? "50");
      if (card) q.set("card", card);
      if (secret) q.set("secret", secret);
      const { body } = await client.call<VaultAuditEntry[]>("GET", `log?${q}`);
      if (json) {
        out(JSON.stringify(body, null, 2) + "\n");
        return 0;
      }
      for (const e of body) {
        out(
          `${e.at.slice(0, 19)}  ${e.outcome.padEnd(7)} ${e.decider.padEnd(7)} ${e.action.padEnd(6)} ${secretDisplay(e.secret)}` +
            `${e.cardId ? `  card ${e.cardId}` : ""}${e.detail ? `  (${e.detail})` : ""}\n`
        );
      }
      return 0;
    }

    case "leases": {
      const card = takeOption(args, "--card");
      const { body } = await client.call<Array<{ cardId: string; secret: string; expiresAt: string; reason?: string }>>(
        "GET",
        `leases${card ? `?card=${card}` : ""}`
      );
      for (const l of body) out(`${secretDisplay(l.secret)}  card ${l.cardId}  until ${l.expiresAt.slice(0, 16)}${l.reason ? `  ${l.reason}` : ""}\n`);
      return 0;
    }

    case "owner": {
      const json = takeFlag(args, "--json");
      const { body } = await client.call<OwnerStatus>("GET", "owner");
      out(json ? JSON.stringify(body, null, 2) + "\n" : ownerLines(body).join("\n") + "\n");
      return 0;
    }

    case "audit": {
      const json = takeFlag(args, "--json");
      if (args[0] !== "check") throw new VaultCliError("usage: kv audit check [--json]");
      const { body } = await client.call<AuditReport>("GET", "audit/check");
      out(json ? JSON.stringify(body, null, 2) + "\n" : auditLines(body).join("\n") + "\n");
      return auditProblems(body) === 0 ? 0 : 1;
    }

    case "status": {
      const { body } = await client.call<{ unlocked: boolean; recipient?: string; secrets: number; machine: string; caller?: string }>(
        "GET",
        "status"
      );
      out(`${body.machine}: ${body.unlocked ? "unlocked" : "LOCKED (no vault key on this machine)"}, ${body.secrets} secrets\n`);
      out(`you are: ${body.caller ?? "outside every card session (open secrets are released, judged ones go past Jev)"}\n`);
      return 0;
    }

    case "scrub":
      return runScrub(args, client, out, io.sleep);

    case "exec-provider": {
      const request = JSON.parse((await readStdin()) || "{}");
      // OpenClaw waits on the provider; an unreachable master is an error
      // code at once, not a two-minute wait.
      client.retryForMs = 0;
      out(JSON.stringify(await execProviderAnswer(client, request, ctx)) + "\n");
      return 0;
    }

    case "hook": {
      const input = JSON.parse((await readStdin()) || "{}");
      const kvPath = io.env.KV_PATH || join(homedir(), ".local/bin/kv");
      const answer = hookRewrite(input, kvPath, args.includes("--codex") ? "codex" : "claude");
      if (answer) out(JSON.stringify(answer) + "\n");
      return 0;
    }

    case "import": {
      const { runImport } = await import("./vault-import.js");
      return runImport(args, client, io);
    }

    default:
      throw new VaultCliError(`kv: unknown command ${cmd}\n\n${USAGE}`);
  }
}

/** The names of a `kv rm --plan` file: a JSON array of names, or one name per line (# starts a comment). */
export function readNamePlan(text: string): string[] {
  const trimmed = text.trim();
  if (trimmed.startsWith("[")) {
    const parsed: unknown = JSON.parse(trimmed);
    if (!Array.isArray(parsed) || parsed.some((n) => typeof n !== "string")) {
      throw new VaultCliError("kv: the plan must be a JSON array of secret names, or one name per line");
    }
    return parsed as string[];
  }
  return trimmed
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line && !line.startsWith("#"));
}

async function waitPending(client: VaultClient, first: VaultResponse): Promise<VaultResponse> {
  client.io.stderr(`kv: ${first.message}...\n`);
  let r = first;
  for (let polls = 0; r.status === "pending" && r.id; polls++) {
    await client.io.sleep(pendingPollDelay(polls));
    r = (await client.call<VaultResponse>("GET", `pending/${encodeURIComponent(r.id)}`)).body;
  }
  return r;
}

export function isFile(path: string): boolean {
  try {
    return statSync(path).isFile();
  } catch {
    return false;
  }
}
