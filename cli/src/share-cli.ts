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
import { promises as dns } from "node:dns";
import { URL } from "node:url";

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
  /** Override the DNS warm-up — tests skip it (fake hostnames won't resolve).
   *  Default: real warmDns with a 15-second deadline. */
  warmDnsImpl?: (host: string) => Promise<void>;
  /** Override the tunnel readiness probe — tests skip it.
   *  Default: polls the tunnel's /api/channels endpoint until our Express
   *  server responds (confirms edge→connector routing is live). */
  warmTunnelImpl?: (baseUrl: string) => Promise<void>;
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
    warmDnsImpl = (h) => warmDns(h),
    warmTunnelImpl = (u) => warmTunnel(u),
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

  // Warm the OS's DNS cache for this hostname BEFORE announcing the URL.
  // macOS's mDNSResponder caches NXDOMAIN for ~60 s — if the user's browser
  // loads the URL before Cloudflare has propagated the record, every
  // subsequent lookup (including after the record exists) returns NXDOMAIN
  // for the lifetime of the negative cache. Polling `dns.lookup` (which
  // goes through getaddrinfo, the same path curl/browsers use) until it
  // succeeds primes the cache with a positive entry.
  const publicUrl = `${tunnel.url}/?token=${encodeURIComponent(token)}`;
  try {
    const host = new URL(tunnel.url).hostname;
    await warmDnsImpl(host);
  } catch (err) {
    writeError(`dns warmup: ${err instanceof Error ? err.message : err}`);
  }
  // Then: wait for the edge → connector path to actually route to our
  // Express server. DNS resolving alone leaves a 5-30s window where
  // Cloudflare returns Error 1033.
  try {
    await warmTunnelImpl(tunnel.url);
  } catch (err) {
    writeError(`tunnel warmup: ${err instanceof Error ? err.message : err}`);
  }
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

/**
 * Poll the tunnel's public URL until our Express server responds. DNS
 * resolving is necessary but not sufficient — Cloudflare's edge has a
 * separate control-plane step mapping hostname → registered connector, and
 * during that ~5-30s window `GET /` returns `Error 1033` from the edge
 * (HTTP 530). ANY response from our Express server — 200, 401, 410 — means
 * the tunnel is fully routable end-to-end.
 *
 * `Error 1033` comes back as either a 5xx or an HTML body with no `x-powered-by`
 * header, so we explicitly accept known Express responses and reject everything
 * else as "not ready yet".
 */
export async function warmTunnel(
  baseUrl: string,
  opts: {
    intervalMs?: number;
    timeoutMs?: number;
    fetchImpl?: (url: string) => Promise<{ status: number; headers: { get(name: string): string | null } }>;
  } = {},
): Promise<void> {
  const intervalMs = opts.intervalMs ?? 500;
  const timeoutMs = opts.timeoutMs ?? 45_000;
  const fetchImpl = opts.fetchImpl ?? ((u) => fetch(u));
  const deadline = Date.now() + timeoutMs;
  // Unauthenticated probe against a known API route. Express returns 401
  // (from our token middleware) the instant the tunnel is reachable; the
  // Cloudflare edge returns 530 / Error 1033 while it's still wiring up.
  const probeUrl = new URL(baseUrl);
  probeUrl.pathname = "/api/channels";
  probeUrl.search = "";

  while (Date.now() < deadline) {
    try {
      const res = await fetchImpl(probeUrl.toString());
      const poweredBy = res.headers.get("x-powered-by");
      // "x-powered-by: Express" is the unambiguous signal that OUR server
      // answered. Checking on that (rather than status codes alone) avoids
      // confusing Cloudflare's 404-from-edge for a real server 404.
      if (poweredBy && poweredBy.toLowerCase().includes("express")) return;
    } catch { /* tunnel not reachable yet */ }
    await new Promise((r) => setTimeout(r, intervalMs));
  }
  throw new Error("tunnel-warmup-timeout");
}

/**
 * Wait until `dns.lookup(host)` succeeds (i.e. getaddrinfo has a positive
 * entry in the OS cache for `host`). Also verifies via `dns.resolve4` that
 * the record exists upstream before each getaddrinfo attempt — this avoids
 * poisoning the OS cache with a failed lookup when the DNS record simply
 * hasn't propagated yet.
 *
 * Polls every `intervalMs` for up to `timeoutMs`. Returns silently on
 * success, throws `Error("dns-warmup-timeout")` otherwise. DNS calls are
 * injectable for tests.
 */
export async function warmDns(
  host: string,
  opts: {
    intervalMs?: number;
    timeoutMs?: number;
    resolveImpl?: (h: string) => Promise<string[]>;
    lookupImpl?: (h: string) => Promise<unknown>;
  } = {},
): Promise<void> {
  const intervalMs = opts.intervalMs ?? 300;
  const timeoutMs = opts.timeoutMs ?? 15_000;
  const resolveImpl = opts.resolveImpl ?? ((h) => dns.resolve4(h));
  const lookupImpl = opts.lookupImpl ?? ((h) => dns.lookup(h));
  const deadline = Date.now() + timeoutMs;

  while (Date.now() < deadline) {
    // Step 1: upstream DNS has the record?
    let hasRecord = false;
    try {
      const addrs = await resolveImpl(host);
      hasRecord = addrs.length > 0;
    } catch { /* fall through */ }
    // Step 2: if upstream is ready, populate the OS cache via getaddrinfo.
    if (hasRecord) {
      try {
        await lookupImpl(host);
        return;
      } catch { /* getaddrinfo may still be holding NX — keep polling */ }
    }
    await new Promise((r) => setTimeout(r, intervalMs));
  }
  throw new Error("dns-warmup-timeout");
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
