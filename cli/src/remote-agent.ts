/**
 * The machine side of the boxd bridge. One long-lived process per machine,
 * started by the Mac with `boxd machine exec <vm> -- kanban remote-agent`.
 *
 * Stdin carries one JSON object per line from the Mac, stdout carries one JSON
 * object per line back. Stdout is the wire, so nothing else may be written
 * there; every log line goes to stderr.
 *
 * The protocol is described in docs/remote-boxd.md.
 */

import { watch, type FSWatcher } from "chokidar";
import {
  chmodSync,
  closeSync,
  existsSync,
  mkdirSync,
  openSync,
  readFileSync,
  readSync,
  realpathSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { createHash } from "node:crypto";
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { homedir, hostname } from "node:os";
import { dirname, join, relative, matchesGlob } from "node:path";
import {
  claudeProjectsDir,
  codexSessionsDir,
  hookEventsPath,
  kanbanHome,
  proxyRequestsDir,
  proxyResponsesDir,
} from "./paths.js";

// ── Wire messages ────────────────────────────────────────────────────

export interface WatchRoot {
  path: string;
  globs?: string[];
}

export interface RemoteAgentIO {
  /** JSON lines from the Mac. */
  input: NodeJS.ReadableStream;
  /** One JSON object per line back to the Mac. */
  send: (message: Record<string, unknown>) => void;
  /** Diagnostics. Never the wire. */
  log?: (text: string) => void;
  /** Injectable clock so activity throttling is testable. */
  now?: () => number;
  /**
   * Resolves when the wire can take another file chunk. File bytes are only
   * read from disk once the previous chunk left the process, so a slow reader
   * on the Mac side never makes the agent buffer transcripts in memory.
   */
  ready?: () => Promise<void>;
}

const ACTIVITY_THROTTLE_MS = 1_000;
const CWD_SCAN_BYTES = 64 * 1024;

// ── Transcript working directory ─────────────────────────────────────

/**
 * Read the transcript's own working directory from its head. Claude puts a
 * `cwd` on most lines, Codex puts it in `session_meta.payload.cwd`. Codex's
 * first line embeds its full base instructions and can be megabytes long, so
 * we scan a bounded head and fall back to a regex when no line parses.
 */
export function readCwdFromTranscript(path: string): string | undefined {
  let head: string;
  try {
    const fd = openSync(path, "r");
    const buffer = Buffer.alloc(CWD_SCAN_BYTES);
    const read = readSync(fd, buffer, 0, buffer.length, 0);
    closeSync(fd);
    head = buffer.toString("utf-8", 0, read);
  } catch {
    return undefined;
  }
  const lines = head.split("\n");
  const complete = head.endsWith("\n") ? lines : lines.slice(0, -1);
  for (const line of complete) {
    if (!line.trim()) continue;
    try {
      const parsed = JSON.parse(line) as { cwd?: unknown; payload?: { cwd?: unknown } };
      if (typeof parsed.cwd === "string" && parsed.cwd) return parsed.cwd;
      if (typeof parsed.payload?.cwd === "string" && parsed.payload.cwd) return parsed.payload.cwd;
    } catch {
      // A truncated or oversized line: the regex below still finds the cwd.
    }
  }
  const match = head.match(/"cwd"\s*:\s*"((?:[^"\\]|\\.)*)"/);
  if (!match) return undefined;
  try {
    const value = JSON.parse(`"${match[1]}"`) as string;
    return value || undefined;
  } catch {
    return undefined;
  }
}

/**
 * Claude names a project directory after its working directory with every
 * separator turned into a dash, so `-home-boxd-my-app` can mean
 * `/home/boxd/my/app` or `/home/boxd/my-app`. Rebuild the path by trying both
 * readings of every dash and keeping the one that exists on disk.
 */
export function deriveCwdFromProjectDirName(
  dirName: string,
  exists: (candidate: string) => boolean = pathExists
): string | undefined {
  if (!dirName.startsWith("-")) return undefined;
  const tokens = dirName.slice(1).split("-");
  if (tokens.length === 0) return undefined;

  const walk = (prefix: string, index: number): string | undefined => {
    if (index >= tokens.length) return exists(prefix) ? prefix : undefined;
    for (let take = 1; index + take <= tokens.length; take += 1) {
      const segment = tokens.slice(index, index + take).join("-");
      const candidate = `${prefix}/${segment}`;
      if (!exists(candidate)) continue;
      const resolved = walk(candidate, index + take);
      if (resolved) return resolved;
    }
    return undefined;
  };

  const found = walk("", 0);
  if (found) return found;
  // Nothing on this machine matches, so fall back to the plain reading.
  return `/${tokens.join("/")}`;
}

function pathExists(candidate: string): boolean {
  try {
    realpathSync(candidate);
    return true;
  } catch {
    return existsSync(candidate);
  }
}

// ── The agent ────────────────────────────────────────────────────────

export class RemoteAgent {
  private readonly send: (message: Record<string, unknown>) => void;
  private readonly log: (text: string) => void;
  private readonly now: () => number;
  private readonly input: NodeJS.ReadableStream;
  private readonly offsets = new Map<string, number>();
  /** Content of the files sent whole, to send each one only when it changes. */
  private readonly digests = new Map<string, string>();
  /** Files the Mac is writing itself right now: their bytes are not sent back. */
  private readonly held = new Set<string>();
  /**
   * Upper bound of one `file` message, cut at a newline. Small enough that a
   * pong queued behind one chunk still reaches the Mac before its ping times
   * out on a slow link.
   */
  chunkBytes = 512 * 1024;
  private readonly ready: () => Promise<void>;
  /** Files with bytes to send, served round robin one chunk at a time. */
  private readonly dirty = new Set<string>();
  private pumping = false;
  private readonly watchers: FSWatcher[] = [];
  private readonly lastActivity = new Map<string, number>();
  private stopped = false;

  constructor(io: RemoteAgentIO) {
    this.input = io.input;
    this.send = io.send;
    this.log = io.log ?? (() => undefined);
    this.now = io.now ?? (() => Date.now());
    this.ready = io.ready ?? (() => Promise.resolve());
  }

  /** Runs until stdin ends. Resolves after the watchers are closed. */
  async run(): Promise<void> {
    this.send({
      type: "hello",
      agentVersion: agentVersion(),
      home: homedir(),
      kanbanHome: kanbanHome(),
      vm: process.env.BOXD_MACHINE_NAME ?? hostname(),
    });
    this.watchProxyRequests();

    const lines = createInterface({ input: this.input, crlfDelay: Infinity });
    for await (const line of lines) {
      if (!line.trim()) continue;
      let message: Record<string, unknown>;
      try {
        message = JSON.parse(line) as Record<string, unknown>;
      } catch (error) {
        this.log(`ignored malformed line: ${String(error)}`);
        continue;
      }
      // Not awaited: an `exec` can run for minutes and the bridge still has to
      // answer pings and stream files while it does.
      this.handle(message).catch((error) => {
        this.log(`handler failed for ${String(message.type)}: ${String(error)}`);
      });
    }
    await this.stop();
  }

  async stop(): Promise<void> {
    if (this.stopped) return;
    this.stopped = true;
    await Promise.all(this.watchers.map((w) => w.close().catch(() => undefined)));
    this.watchers.length = 0;
  }

  async handle(message: Record<string, unknown>): Promise<void> {
    switch (message.type) {
      case "ping":
        this.send({ type: "pong" });
        return;
      case "watch":
        this.startWatching(
          (message.roots as WatchRoot[] | undefined) ?? [],
          (message.offsets as Record<string, number> | undefined) ?? {}
        );
        return;
      case "put":
        this.put(message as { path: string; data: string; mode?: number });
        return;
      case "hold":
        if (typeof message.path === "string") this.held.add(message.path);
        return;
      case "release":
        this.release(message as { path: string; offset?: number });
        return;
      case "exec":
        await this.exec(
          message as { id: string; argv: string[]; stdin?: string; cwd?: string }
        );
        return;
      case "proxy-result":
        this.writeProxyResult(
          message as { id: string; stdout?: string; stderr?: string; code?: number }
        );
        return;
      default:
        this.log(`unknown message type: ${String(message.type)}`);
    }
  }

  // ── watch ──────────────────────────────────────────────────────────

  private startWatching(roots: WatchRoot[], offsets: Record<string, number>): void {
    for (const [path, offset] of Object.entries(offsets)) {
      if (Number.isFinite(offset)) this.offsets.set(path, Math.max(0, offset));
    }
    for (const root of roots) {
      if (!root?.path) continue;
      this.watchRoot(root);
    }
  }

  private watchRoot(root: WatchRoot): void {
    const watcher = watch(root.path, {
      persistent: true,
      ignoreInitial: false,
      awaitWriteFinish: { stabilityThreshold: 30, pollInterval: 20 },
    });
    watcher.on("add", (path) => this.onFileEvent(root, path));
    watcher.on("change", (path) => this.onFileEvent(root, path));
    watcher.on("unlink", (path) => {
      if (!this.matchesRoot(root, path)) return;
      this.offsets.delete(path);
      this.digests.delete(path);
      this.send({ type: "removed", path });
    });
    watcher.on("error", (error) => this.log(`watch error on ${root.path}: ${String(error)}`));
    this.watchers.push(watcher);
  }

  private matchesRoot(root: WatchRoot, path: string): boolean {
    // Proxy requests have their own watcher, which answers them instead of
    // streaming their bytes.
    if (dirname(path) === proxyRequestsDir()) return false;
    // Upload staging files (`boxd machine cp` writes `*.boxd-upload.tmp`,
    // the app stages `*.incoming-<id>` and `*.delta-<id>`) are half-written
    // copies of files the Mac already has. Mirroring one back sends
    // megabytes for nothing and a crashed upload leaves it behind forever.
    const base = path.slice(path.lastIndexOf("/") + 1);
    if (base.endsWith(".tmp") || /\.(incoming|delta)-[A-Za-z0-9-]+$/.test(base)) return false;
    const globs = root.globs ?? [];
    if (globs.length === 0) return true;
    if (path === root.path) return true;
    const rel = relative(root.path, path);
    if (!rel || rel.startsWith("..")) return false;
    return globs.some((glob) => {
      try {
        return matchesGlob(rel, glob);
      } catch {
        return false;
      }
    });
  }

  private onFileEvent(root: WatchRoot, path: string): void {
    if (!this.matchesRoot(root, path)) return;
    this.pump(path);
  }

  /**
   * The Mac wrote `path` itself and holds `offset` bytes of it. Only what the
   * machine appends after that crosses the bridge.
   */
  private release(message: { path: string; offset?: number }): void {
    const { path, offset } = message;
    if (typeof path !== "string") return;
    this.held.delete(path);
    if (typeof offset === "number" && Number.isFinite(offset)) {
      this.offsets.set(path, Math.max(0, offset));
      if (!path.endsWith(".jsonl")) {
        try {
          this.digests.set(path, createHash("sha1").update(readFileSync(path)).digest("base64"));
        } catch {
          this.digests.delete(path);
        }
      }
    }
    this.pump(path);
  }

  /**
   * Queue `path` to send everything appended since the offset the Mac already
   * has. One loop drains the queue, one chunk per file per turn, and waits for
   * the wire before reading the next chunk, so memory stays at about one chunk
   * however many files changed and however slow the Mac reads.
   */
  pump(path: string): void {
    if (this.held.has(path) || this.stopped) return;
    this.dirty.add(path);
    if (this.pumping) return;
    this.pumping = true;
    void this.drainQueue()
      .catch((error) => this.log(`pump failed: ${String(error)}`))
      .finally(() => {
        this.pumping = false;
      });
  }

  private async drainQueue(): Promise<void> {
    while (this.dirty.size > 0 && !this.stopped) {
      await this.ready();
      const path = this.dirty.values().next().value as string;
      this.dirty.delete(path);
      if (this.held.has(path)) continue;
      // Back of the queue: a live session is not starved behind the backlog
      // of a transcript of hundreds of megabytes.
      if (this.pumpOnce(path)) this.dirty.add(path);
      // Let stdin (pings, execs) in between chunks.
      await new Promise((resolve) => setImmediate(resolve));
    }
  }

  /** Sends one chunk of `path`. True when more of it is left to send. */
  private pumpOnce(path: string): boolean {
    // Only `.jsonl` files grow by appending. The others, such as the
    // statusline context, are rewritten in place, so their new content has
    // nothing to do with the bytes the Mac already holds.
    if (!path.endsWith(".jsonl")) {
      this.pumpWholeFile(path);
      return false;
    }
    let size: number;
    try {
      size = statSync(path).size;
    } catch {
      return false;
    }
    let offset = this.offsets.get(path) ?? 0;
    // A rewritten file is shorter than what we already sent: start over.
    if (offset > size) offset = 0;
    if (size === offset) return false;

    // One message carries at most `chunkBytes`, so an exec answer never
    // waits behind a transcript of a hundred megabytes.
    let chunk: Buffer;
    try {
      const fd = openSync(path, "r");
      const buffer = Buffer.alloc(Math.min(size - offset, this.chunkBytes));
      const read = readSync(fd, buffer, 0, buffer.length, offset);
      closeSync(fd);
      chunk = buffer.subarray(0, read);
    } catch (error) {
      this.log(`could not read ${path}: ${String(error)}`);
      return false;
    }
    if (chunk.length === 0) return false;

    const lastNewline = chunk.lastIndexOf(0x0a);
    if (lastNewline < 0) {
      // A partial last line stays on the machine until its newline arrives.
      // A single line longer than a chunk is sent whole.
      if (offset + chunk.length >= size) return false;
      const line = this.readLine(path, offset, size);
      if (!line) return false;
      chunk = line;
    } else {
      chunk = chunk.subarray(0, lastNewline + 1);
    }

    const next = offset + chunk.length;
    this.offsets.set(path, next);
    const message: Record<string, unknown> = {
      type: "file",
      path,
      offset,
      data: chunk.toString("base64"),
      eof: next >= size,
    };
    const cwd = this.transcriptCwd(path);
    if (cwd) message.cwd = cwd;
    this.send(message);
    this.reportActivity(path);
    return next < size;
  }

  /**
   * The bytes of the one line starting at `offset`, up to `size`. Reads until
   * the first newline only, never the rest of the file.
   */
  private readLine(path: string, offset: number, size: number): Buffer | undefined {
    let fd: number | undefined;
    try {
      fd = openSync(path, "r");
      const parts: Buffer[] = [];
      let position = offset;
      while (position < size) {
        const buffer = Buffer.alloc(Math.min(size - position, this.chunkBytes));
        const read = readSync(fd, buffer, 0, buffer.length, position);
        if (read === 0) break;
        const part = buffer.subarray(0, read);
        const newline = part.indexOf(0x0a);
        if (newline >= 0) {
          parts.push(part.subarray(0, newline + 1));
          return Buffer.concat(parts);
        }
        parts.push(part);
        position += read;
      }
      return undefined;
    } catch (error) {
      this.log(`could not read ${path}: ${String(error)}`);
      return undefined;
    } finally {
      if (fd !== undefined) closeSync(fd);
    }
  }

  /**
   * Sends a rewritten file whole, at offset 0, so the Mac replaces its copy.
   * A file whose content did not change is not sent again: the watcher
   * reports a write even when the bytes are the same.
   */
  private pumpWholeFile(path: string): void {
    // The Mac already holds this file at its current size (it sends the sizes
    // it has on `watch`): trust that on a fresh start instead of reading and
    // resending every tool result. A later write changes the size or the
    // modification time and is then compared by content.
    const previous = this.digests.get(path);
    if (previous === undefined || previous.startsWith("stat:")) {
      const known = this.offsets.get(path);
      if (known !== undefined) {
        try {
          const stat = statSync(path);
          const mark = `stat:${stat.size}:${stat.mtimeMs}`;
          if (stat.size === known && (previous === undefined || previous === mark)) {
            this.digests.set(path, mark);
            return;
          }
        } catch {
          return;
        }
      }
    }
    let data: Buffer;
    try {
      data = readFileSync(path);
    } catch (error) {
      this.log(`could not read ${path}: ${String(error)}`);
      return;
    }
    const digest = createHash("sha1").update(data).digest("base64");
    if (this.digests.get(path) === digest) return;
    this.digests.set(path, digest);
    this.offsets.set(path, data.length);
    this.send({
      type: "file",
      path,
      offset: 0,
      data: data.toString("base64"),
      eof: true,
    });
    this.reportActivity(path);
  }

  private transcriptCwd(path: string): string | undefined {
    const claudeRoot = claudeProjectsDir();
    const codexRoot = codexSessionsDir();
    const underClaude = isUnder(claudeRoot, path);
    if (!underClaude && !isUnder(codexRoot, path)) return undefined;
    if (!path.endsWith(".jsonl")) return undefined;
    const fromFile = readCwdFromTranscript(path);
    if (fromFile) return fromFile;
    if (!underClaude) return undefined;
    const rel = relative(claudeRoot, path);
    const projectDir = rel.split("/")[0];
    return projectDir ? deriveCwdFromProjectDirName(projectDir) : undefined;
  }

  private reportActivity(path: string): void {
    const kind = path === hookEventsPath()
      ? "hook"
      : isUnder(claudeProjectsDir(), path) || isUnder(codexSessionsDir(), path)
        ? "transcript"
        : undefined;
    if (!kind) return;
    const last = this.lastActivity.get(kind) ?? 0;
    const now = this.now();
    if (now - last < ACTIVITY_THROTTLE_MS) return;
    this.lastActivity.set(kind, now);
    this.send({ type: "activity", kind });
  }

  // ── put / exec ─────────────────────────────────────────────────────

  private put(message: { path: string; data: string; mode?: number }): void {
    if (!message.path) throw new Error("put without a path");
    mkdirSync(dirname(message.path), { recursive: true });
    const bytes = Buffer.from(message.data ?? "", "base64");
    writeFileSync(message.path, bytes);
    // writeFileSync only applies a mode when it creates the file, so a rewritten
    // launch script would keep the old permissions.
    if (message.mode) chmodSync(message.path, message.mode);
  }

  private async exec(message: {
    id: string;
    argv: string[];
    stdin?: string;
    cwd?: string;
  }): Promise<void> {
    const argv = message.argv ?? [];
    if (argv.length === 0) {
      this.send({ type: "exec-result", id: message.id, stdout: "", stderr: "exec without argv", code: 127 });
      return;
    }
    const result = await runCommand(argv, message.stdin, message.cwd);
    this.send({ type: "exec-result", id: message.id, ...result });
  }

  // ── proxy ──────────────────────────────────────────────────────────

  private watchProxyRequests(): void {
    const dir = proxyRequestsDir();
    mkdirSync(dir, { recursive: true });
    const watcher = watch(dir, {
      persistent: true,
      ignoreInitial: false,
      depth: 0,
      awaitWriteFinish: { stabilityThreshold: 30, pollInterval: 20 },
    });
    const forward = (path: string): void => {
      if (!path.endsWith(".json")) return;
      this.forwardProxyRequest(path);
    };
    watcher.on("add", forward);
    watcher.on("change", forward);
    watcher.on("error", (error) => this.log(`proxy watch error: ${String(error)}`));
    this.watchers.push(watcher);
  }

  forwardProxyRequest(path: string): void {
    let request: Record<string, unknown>;
    try {
      const fd = openSync(path, "r");
      const size = statSync(path).size;
      const buffer = Buffer.alloc(size);
      readSync(fd, buffer, 0, size, 0);
      closeSync(fd);
      request = JSON.parse(buffer.toString("utf-8")) as Record<string, unknown>;
    } catch (error) {
      this.log(`could not read proxy request ${path}: ${String(error)}`);
      return;
    }
    if (typeof request.id !== "string") {
      this.log(`proxy request without an id: ${path}`);
      return;
    }
    this.send({ ...request, type: "proxy" });
  }

  private writeProxyResult(message: {
    id: string;
    stdout?: string;
    stderr?: string;
    code?: number;
  }): void {
    if (!message.id) throw new Error("proxy-result without an id");
    const dir = proxyResponsesDir();
    mkdirSync(dir, { recursive: true });
    const target = join(dir, `${message.id}.json`);
    const temp = `${target}.tmp`;
    writeFileSync(
      temp,
      JSON.stringify(
        {
          id: message.id,
          stdout: message.stdout ?? "",
          stderr: message.stderr ?? "",
          code: message.code ?? 0,
        },
        null,
        2
      )
    );
    renameSync(temp, target);
    rmSync(join(proxyRequestsDir(), `${message.id}.json`), { force: true });
  }
}

// ── Helpers ──────────────────────────────────────────────────────────

function isUnder(root: string, path: string): boolean {
  const rel = relative(root, path);
  return rel !== "" && !rel.startsWith("..");
}

function agentVersion(): string {
  try {
    const path = join(import.meta.dirname, "..", "package.json");
    const fd = openSync(path, "r");
    const size = statSync(path).size;
    const buffer = Buffer.alloc(size);
    readSync(fd, buffer, 0, size, 0);
    closeSync(fd);
    const parsed = JSON.parse(buffer.toString("utf-8")) as { version?: string };
    return parsed.version ?? "0.0.0";
  } catch {
    return "0.0.0";
  }
}

export function runCommand(
  argv: string[],
  stdin?: string,
  cwd?: string
): Promise<{ stdout: string; stderr: string; code: number }> {
  return new Promise((resolve) => {
    let child: ReturnType<typeof spawn>;
    try {
      child = spawn(argv[0], argv.slice(1), {
        cwd: cwd && existsSync(cwd) ? cwd : undefined,
        env: process.env,
      });
    } catch (error) {
      resolve({ stdout: "", stderr: String(error), code: 127 });
      return;
    }
    let stdout = "";
    let stderr = "";
    child.stdout?.on("data", (chunk: Buffer) => {
      stdout += chunk.toString("utf-8");
    });
    child.stderr?.on("data", (chunk: Buffer) => {
      stderr += chunk.toString("utf-8");
    });
    child.on("error", (error) => {
      resolve({ stdout, stderr: stderr + String(error), code: 127 });
    });
    child.on("close", (code) => {
      resolve({ stdout, stderr, code: code ?? 0 });
    });
    if (stdin !== undefined) child.stdin?.end(stdin);
    else child.stdin?.end();
  });
}

/** Resolves once `stream` has flushed what it buffered, or can no longer write. */
export function waitForDrain(stream: NodeJS.WritableStream & { writableNeedDrain?: boolean; writable?: boolean }): Promise<void> {
  if (!stream.writableNeedDrain || stream.writable === false) return Promise.resolve();
  return new Promise((resolve) => {
    const done = (): void => {
      stream.off("drain", done);
      stream.off("close", done);
      stream.off("error", done);
      resolve();
    };
    stream.on("drain", done);
    stream.on("close", done);
    stream.on("error", done);
  });
}

/** Entry point for `kanban remote-agent`. */
export async function runRemoteAgent(): Promise<void> {
  const agent = new RemoteAgent({
    input: process.stdin,
    send: (message) => process.stdout.write(`${JSON.stringify(message)}\n`),
    log: (text) => process.stderr.write(`${text}\n`),
    ready: () => waitForDrain(process.stdout),
  });
  await agent.run();
}
