/**
 * Spawn a cloudflared quick-tunnel for a local port, parse the public URL
 * from its stdout/stderr, and expose a kill handle. Kept thin + injectable
 * so tests can substitute a fake binary that prints the URL and exits.
 */

import { spawn, type ChildProcess } from "node:child_process";

export interface TunnelHandle {
  /** The public URL cloudflared allocated (e.g. "https://xxx.trycloudflare.com"). */
  url: string;
  /** The underlying child — kill to tear the tunnel down. */
  child: ChildProcess;
  /** Graceful teardown: SIGTERM, then SIGKILL after `timeoutMs` if still alive. */
  stop: (timeoutMs?: number) => Promise<void>;
}

export interface StartTunnelOptions {
  /** Localhost port that cloudflared should forward to. */
  port: number;
  /** Override the cloudflared binary (default: "npx cloudflared"). */
  command?: string;
  args?: string[];
  /** How long to wait for the URL line before giving up. */
  timeoutMs?: number;
  /** Spawner — pluggable for tests. */
  spawnImpl?: typeof spawn;
}

// Quick tunnels always allocate something under trycloudflare.com. Match
// both `https://<sub>.trycloudflare.com` and `https://<sub>.cfargotunnel.com`
// just in case the CDN changes the surface.
const URL_REGEX = /https:\/\/[a-z0-9][a-z0-9-]*\.(?:trycloudflare\.com|cfargotunnel\.com)/i;

/** Start cloudflared and resolve once the public URL is seen on stdout/stderr.
 *
 *  Resolution order for the cloudflared binary:
 *    1. Caller-provided `command` / `args` (used by tests).
 *    2. `KANBAN_CLOUDFLARED` env var — absolute path to a bundled binary.
 *       The Swift app sets this when it spawns the CLI, pointing at the
 *       cloudflared shipped inside the .app bundle.
 *    3. Fallback to `npx -y cloudflared` so standalone CLI use still works.
 */
export function startCloudflaredTunnel(opts: StartTunnelOptions): Promise<TunnelHandle> {
  const bundled = process.env.KANBAN_CLOUDFLARED;
  const defaultCommand = bundled || "npx";
  const defaultArgs = bundled
    ? ["tunnel", "--url", `http://localhost:${opts.port}`]
    : ["-y", "cloudflared", "tunnel", "--url", `http://localhost:${opts.port}`];
  const {
    port,
    command = defaultCommand,
    args = defaultArgs,
    timeoutMs = 30_000,
    spawnImpl = spawn,
  } = opts;
  void port;

  return new Promise<TunnelHandle>((resolve, reject) => {
    const child = spawnImpl(command, args, {
      stdio: ["ignore", "pipe", "pipe"],
      env: process.env,
    });

    let resolved = false;
    const timer = setTimeout(() => {
      if (resolved) return;
      resolved = true;
      try { child.kill("SIGTERM"); } catch { /* */ }
      reject(new Error(`cloudflared did not publish a URL within ${timeoutMs}ms`));
    }, timeoutMs);

    const stop = async (killTimeoutMs = 2000): Promise<void> => {
      if (child.exitCode !== null || child.signalCode !== null) return;
      return new Promise<void>((res) => {
        const done = (): void => { clearTimeout(hard); res(); };
        child.once("exit", done);
        try { child.kill("SIGTERM"); } catch { done(); return; }
        const hard = setTimeout(() => {
          try { child.kill("SIGKILL"); } catch { /* */ }
        }, killTimeoutMs);
      });
    };

    const scan = (data: Buffer | string): void => {
      if (resolved) return;
      const chunk = typeof data === "string" ? data : data.toString("utf-8");
      const m = chunk.match(URL_REGEX);
      if (m) {
        resolved = true;
        clearTimeout(timer);
        resolve({ url: m[0], child, stop });
      }
    };

    child.stdout?.on("data", scan);
    child.stderr?.on("data", scan);

    child.once("exit", (code, signal) => {
      if (resolved) return;
      resolved = true;
      clearTimeout(timer);
      reject(new Error(`cloudflared exited before publishing a URL (code=${code}, signal=${signal})`));
    });

    child.once("error", (err) => {
      if (resolved) return;
      resolved = true;
      clearTimeout(timer);
      reject(err);
    });
  });
}
