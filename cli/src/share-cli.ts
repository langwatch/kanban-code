/**
 * Orchestrator for `kanban channel share`:
 *   1. Picks a free localhost port.
 *   2. Starts the share-server Express app on it.
 *   3. Spawns `cloudflared tunnel --url http://localhost:<port>`.
 *   4. Prints url/token/port/expiresAt (one per line) on its own stdout so
 *      the parent process (Swift app) can parse them.
 *   5. Keeps running until the duration elapses OR the parent sends SIGTERM /
 *      SIGINT / closes our stdin, then cleanly tears everything down.
 *
 * Split out of kanban.ts so it's unit-testable without a real Commander
 * action + without actually running cloudflared.
 */

import { createServer, type Server } from "node:http";
import { randomBytes } from "node:crypto";
import { AddressInfo } from "node:net";

import { buildShareApp, type ShareServerDeps } from "./share-server.js";
import { startCloudflaredTunnel, type TunnelHandle } from "./tunnel.js";

export interface RunShareOptions {
  channelName: string;
  /** Duration in milliseconds. */
  durationMs: number;
  /** Loader for the current links list (read once per POST /send). */
  loadLinks: ShareServerDeps["loadLinks"];
  /** Broadcast sender. Defaults to real tmux paste. */
  sender: ShareServerDeps["sender"];
  liveSessionProbe?: ShareServerDeps["liveSessionProbe"];
  /** Override data root (testing). */
  baseDir: string;
  /** Optional dir with the built web client to serve at `/`. */
  webDistDir?: string;
  /** Override the cloudflared starter — tests inject a fake. */
  startTunnel?: typeof startCloudflaredTunnel;
  /** Called for each output line — defaults to process.stdout.write. */
  writeLine?: (line: string) => void;
  /** Called for diagnostics — defaults to process.stderr.write. */
  writeError?: (line: string) => void;
}

export interface ShareRunHandle {
  url: string;
  token: string;
  port: number;
  expiresAt: number;
  /** Resolves once the share has fully torn down. */
  done: Promise<void>;
  /** Trigger teardown manually (parent requested stop). */
  stop: () => Promise<void>;
}

/** Start the share. Resolves once the tunnel is up and the first 4 lines
 *  have been written. The `done` promise on the handle resolves once the
 *  share has fully expired or been stopped. */
export async function runShare(opts: RunShareOptions): Promise<ShareRunHandle> {
  const {
    channelName,
    durationMs,
    loadLinks,
    sender,
    liveSessionProbe,
    baseDir,
    webDistDir,
    startTunnel = startCloudflaredTunnel,
    writeLine = (l) => process.stdout.write(l + "\n"),
    writeError = (l) => process.stderr.write(l + "\n"),
  } = opts;

  const token = "tk_" + randomBytes(16).toString("hex");
  const expiresAt = Date.now() + durationMs;

  const app = buildShareApp({
    channelName,
    token,
    baseDir,
    loadLinks,
    sender,
    liveSessionProbe,
    expiresAt,
    webDistDir,
  });

  // Listen on an OS-assigned free port.
  const httpServer: Server = createServer(app);
  await new Promise<void>((resolve, reject) => {
    httpServer.once("error", reject);
    httpServer.listen(0, "127.0.0.1", () => resolve());
  });
  const port = (httpServer.address() as AddressInfo).port;

  // Start cloudflared. If it fails, tear down the HTTP server before rethrowing.
  let tunnel: TunnelHandle;
  try {
    tunnel = await startTunnel({ port });
  } catch (err) {
    await new Promise<void>((r) => httpServer.close(() => r()));
    throw err;
  }

  // Publish the URL, token, and metadata for the parent to parse.
  const publicUrl = `${tunnel.url}/?token=${encodeURIComponent(token)}`;
  writeLine(`url: ${publicUrl}`);
  writeLine(`token: ${token}`);
  writeLine(`port: ${port}`);
  writeLine(`expiresAt: ${new Date(expiresAt).toISOString()}`);

  // Coordinated teardown. Idempotent.
  let torndown = false;
  const doneGate: { resolve: () => void } = { resolve: () => {} };
  const done = new Promise<void>((r) => { doneGate.resolve = r; });

  const stop = async (): Promise<void> => {
    if (torndown) return;
    torndown = true;
    try { await tunnel.stop(2000); } catch (err) { writeError(`tunnel stop: ${err instanceof Error ? err.message : err}`); }
    await new Promise<void>((r) => httpServer.close(() => r()));
    doneGate.resolve();
  };

  // Auto-expire after duration.
  const timer = setTimeout(() => {
    writeError(`share expired after ${Math.round(durationMs / 1000)}s — shutting down`);
    void stop();
  }, durationMs);
  // Don't keep the process alive just for this timer — stop() will clear it.
  const stopOnce = stop;
  const wrappedStop = async (): Promise<void> => {
    clearTimeout(timer);
    await stopOnce();
  };

  return { url: publicUrl, token, port, expiresAt, done, stop: wrappedStop };
}

/** Parse "5m", "45m", "1h", "6h", "30s" into ms. Rejects invalid input. */
export function parseDuration(s: string): number {
  const m = /^(\d+)\s*(s|m|h)?$/i.exec(s.trim());
  if (!m) throw new Error(`invalid duration: ${s} (use e.g. 5m, 1h)`);
  const n = parseInt(m[1], 10);
  if (!Number.isFinite(n) || n <= 0) throw new Error(`invalid duration: ${s}`);
  const unit = (m[2] ?? "m").toLowerCase();
  const unitMs: Record<string, number> = { s: 1000, m: 60_000, h: 3_600_000 };
  return n * unitMs[unit];
}

/** Whitelist of UI-accepted durations. The CLI itself accepts anything
 *  parseable; the Swift UI restricts to this set. */
export const SHARE_DURATION_CHOICES = [
  { label: "5 min", ms: 5 * 60_000 },
  { label: "10 min", ms: 10 * 60_000 },
  { label: "15 min", ms: 15 * 60_000 },
  { label: "30 min", ms: 30 * 60_000 },
  { label: "45 min", ms: 45 * 60_000 },
  { label: "1 hr", ms: 60 * 60_000 },
  { label: "6 hr", ms: 6 * 60 * 60_000 },
] as const;
