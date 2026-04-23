/**
 * Share server — Express app that exposes a channel over a public URL via
 * cloudflared. Read path is long-polling (Cloudflare's quick-tunnel edge
 * buffers streaming responses). Write path is plain POST. Broadcast reuses
 * `sendAndFanOut()` so messages land in every member's tmux session the same
 * way the Swift UI and CLI already do.
 */

import express, { Request, Response, NextFunction, Express } from "express";
import { watch } from "chokidar";
import { mkdirSync, writeFileSync } from "node:fs";
import { join, dirname, resolve as resolvePath } from "node:path";
import { randomUUID } from "node:crypto";

import type { Link } from "./types.js";
import {
  channelLogPath,
  getChannel,
  readMessages,
  type ChannelMessage,
} from "./channels.js";
import { sendAndFanOut, type Sender, type LiveSessionProbe } from "./broadcast.js";
import { buildOpenApiSpec } from "./openapi.js";

/** Injectable dependencies so tests don't need a real tmux or real links file. */
export interface ShareServerDeps {
  /** The single channel exposed by this share. Requests for any other
   *  channel name in the URL get a 404 — one share link, one channel. */
  channelName: string;
  /** Shared token required on every request. */
  token: string;
  /** Data root (~/.kanban-code by default). */
  baseDir: string;
  /** Loads the current links list at send-time so the fanout can target
   *  each member's live tmux session. Called on every POST /send. */
  loadLinks: () => Link[];
  /** tmux paste adapter — pluggable for tests. */
  sender: Sender;
  /** tmux session liveness probe — pluggable for tests. */
  liveSessionProbe?: LiveSessionProbe;
  /** Share expiry (epoch-ms). After this wall-clock, every route returns 410. */
  expiresAt: number;
  /** Optional: directory to serve static web client from. */
  webDistDir?: string;
}

// Handles must be safe for tmux paste + jsonl + URL use.
const HANDLE_RE = /^[a-z0-9][a-z0-9_-]{0,47}$/i;
const MAX_BODY_BYTES = 32 * 1024;
const MAX_IMAGE_BYTES = 10 * 1024 * 1024;
// Hold an idle long-poll for up to 25 s. Cloudflare quick tunnels terminate
// requests after 100 s of total time with no progress, so this stays well
// under that while still keeping the round-trip rate low.
const LONG_POLL_HOLD_MS = 25_000;

function externalHandle(raw: string): string {
  // Namespaced prefix so agents can see at a glance that this came in from a
  // share link. Also lowercased / sanitized — we already validated the shape.
  const clean = raw.trim().toLowerCase();
  return clean.startsWith("ext_") ? clean : `ext_${clean}`;
}

export function buildShareApp(deps: ShareServerDeps): Express {
  const app = express();

  // ── Middleware ────────────────────────────────────────────────────
  app.use(express.json({ limit: "128kb" }));

  // Expiry check runs first so even a valid token can't keep the share alive
  // past its window.
  app.use((req: Request, res: Response, next: NextFunction) => {
    if (Date.now() > deps.expiresAt) {
      res.status(410).type("text/plain").send("share expired");
      return;
    }
    next();
  });

  // Token check. Accepts ?token=... or Authorization: Bearer.
  const requireToken = (req: Request, res: Response, next: NextFunction): void => {
    const fromQuery = typeof req.query.token === "string" ? req.query.token : undefined;
    const auth = req.headers.authorization;
    const fromHeader = auth?.startsWith("Bearer ") ? auth.slice(7) : undefined;
    const got = fromQuery ?? fromHeader;
    if (got !== deps.token) {
      res.status(401).type("text/plain").send("unauthorized");
      return;
    }
    next();
  };

  // Channel name lock — URL must match the configured channel.
  const requireChannel = (req: Request, res: Response, next: NextFunction): void => {
    if (req.params.name !== deps.channelName) {
      res.status(404).type("text/plain").send("channel not found");
      return;
    }
    const ch = getChannel(deps.channelName, deps.baseDir);
    if (!ch) {
      res.status(404).type("text/plain").send("channel not found");
      return;
    }
    next();
  };

  // Build the info payload for `deps.channelName`. Factored out so the
  // per-channel info route and the multi-channel discovery route share it.
  const channelInfo = (): { name: string; members: { handle: string }[]; remainingMs: number; expiresAt: string } | null => {
    const ch = getChannel(deps.channelName, deps.baseDir);
    if (!ch) return null;
    return {
      name: ch.name,
      members: ch.members.map((m) => ({ handle: m.handle })),
      remainingMs: Math.max(0, deps.expiresAt - Date.now()),
      expiresAt: new Date(deps.expiresAt).toISOString(),
    };
  };

  // ── Discovery ─────────────────────────────────────────────────────
  // Returns every channel this token has access to. Today that's always a
  // single entry (the channel this share is bound to), but the payload shape
  // is an array so the web client doesn't need to change when we broaden a
  // single share link to cover multiple channels.
  app.get("/api/channels", requireToken, (_req, res) => {
    const info = channelInfo();
    res.json({ channels: info ? [info] : [] });
  });

  // ── OpenAPI discovery for agents ──────────────────────────────────
  // Served at the conventional RFC 8615 path so agent tools (MCP clients,
  // ChatGPT plugin runtimes, custom bots) can auto-discover the API
  // surface. Token-protected: if you can reach this URL you've already
  // proven you have the share secret. Registered BEFORE express.static so
  // the dot-prefix doesn't get swallowed by the static middleware's
  // default `dotfiles: "ignore"`.
  app.get("/.well-known/openapi.json", requireToken, (req, res) => {
    // Honor X-Forwarded-* from cloudflared so the spec's `servers[0].url`
    // reflects the public trycloudflare.com hostname, not localhost.
    const host = (req.get("x-forwarded-host") ?? req.get("host") ?? "").split(",")[0].trim();
    const proto = (req.get("x-forwarded-proto") ?? (req.secure ? "https" : "http")).split(",")[0].trim();
    const publicBaseUrl = host ? `${proto}://${host}` : "";
    res.type("application/json").send(JSON.stringify(
      buildOpenApiSpec({ publicBaseUrl, channelName: deps.channelName }),
      null, 2,
    ));
  });

  // ── Info ──────────────────────────────────────────────────────────
  app.get("/api/channels/:name/info", requireToken, requireChannel, (_req, res) => {
    const info = channelInfo();
    if (!info) { res.status(404).type("text/plain").send("channel not found"); return; }
    res.json(info);
  });

  // ── History ───────────────────────────────────────────────────────
  app.get("/api/channels/:name/history", requireToken, requireChannel, (_req, res) => {
    const msgs = readMessages(deps.channelName, deps.baseDir);
    res.json({ messages: msgs });
  });

  // ── Send (POST) ───────────────────────────────────────────────────
  app.post("/api/channels/:name/send", requireToken, requireChannel, (req, res) => {
    const { handle: rawHandle, body: rawBody, imagePaths: rawImages } = req.body ?? {};
    if (typeof rawHandle !== "string" || !HANDLE_RE.test(rawHandle.replace(/^ext_/, ""))) {
      res.status(400).json({ error: "invalid handle" });
      return;
    }
    if (typeof rawBody !== "string") {
      res.status(400).json({ error: "missing body" });
      return;
    }
    const body = rawBody.trim();
    if (!body) {
      res.status(400).json({ error: "empty body" });
      return;
    }
    if (Buffer.byteLength(body, "utf-8") > MAX_BODY_BYTES) {
      res.status(413).json({ error: "body too large" });
      return;
    }
    const handle = externalHandle(rawHandle);
    const imagePaths: string[] = Array.isArray(rawImages)
      ? rawImages.filter((p): p is string => typeof p === "string")
      : [];

    try {
      const links = deps.loadLinks();
      const { msg, result } = sendAndFanOut(
        deps.channelName,
        { cardId: null, handle },
        body,
        links,
        deps.baseDir,
        { sender: deps.sender, liveSessionProbe: deps.liveSessionProbe },
        imagePaths,
        "external",
      );
      res.json({ msg, result });
    } catch (err) {
      res.status(500).json({ error: err instanceof Error ? err.message : String(err) });
    }
  });

  // ── Images (POST raw) ─────────────────────────────────────────────
  // Content-Type is enforced; we only accept a small whitelist of bitmap
  // formats that the rest of the pipeline can render. File is written under
  // ~/.kanban-code/channels/images/<uuid>/0.<ext> — same layout as CLI uploads.
  app.post("/api/channels/:name/images", requireToken, requireChannel,
    express.raw({ type: ["image/png", "image/jpeg", "image/gif", "image/webp"], limit: MAX_IMAGE_BYTES }),
    (req, res) => {
      const ctRaw = (req.headers["content-type"] ?? "").split(";")[0].trim().toLowerCase();
      const extByType: Record<string, string> = {
        "image/png": "png",
        "image/jpeg": "jpg",
        "image/gif": "gif",
        "image/webp": "webp",
      };
      const ext = extByType[ctRaw];
      if (!ext) {
        res.status(415).json({ error: "unsupported content-type" });
        return;
      }
      if (!Buffer.isBuffer(req.body) || req.body.length === 0) {
        res.status(400).json({ error: "empty upload" });
        return;
      }
      const msgId = `img_${randomUUID().replace(/-/g, "")}`;
      const dir = join(deps.baseDir, "channels", "images", msgId);
      mkdirSync(dir, { recursive: true });
      const path = join(dir, `0.${ext}`);
      writeFileSync(path, req.body);
      res.json({ path });
    });

  // ── Image fetch ────────────────────────────────────────────────────
  // Browsers can't fetch the absolute filesystem paths we record in
  // `imagePaths` (that form is for tmux consumers, where Claude can
  // Read() the file directly). Serve the same bytes over HTTP here so
  // the web client can render them via <img src>.
  //
  // Path traversal is prevented by:
  //   1. Strict regex on msgId + filename
  //   2. Resolving the final path and asserting it's under <baseDir>/channels/images/
  app.get("/api/images/:msgId/:filename", requireToken, (req, res) => {
    const msgId = typeof req.params.msgId === "string" ? req.params.msgId : "";
    const filename = typeof req.params.filename === "string" ? req.params.filename : "";
    // Hyphens allowed so the native Swift client's `msg_UUID-slice` IDs
    // (e.g. `msg_50F2861B-19A`) round-trip alongside our `img_<hex>`
    // web-upload IDs. Traversal is still blocked because `/` and `..` are
    // not in the character class.
    if (!/^(?:img|msg)_[a-zA-Z0-9_-]{1,64}$/.test(msgId) ||
        !/^[a-zA-Z0-9_-]{1,64}\.(?:png|jpg|jpeg|gif|webp)$/i.test(filename)) {
      res.status(400).type("text/plain").send("bad image path");
      return;
    }
    const baseImages = resolvePath(deps.baseDir, "channels", "images");
    const full = resolvePath(baseImages, msgId, filename);
    if (!full.startsWith(baseImages + "/") && full !== baseImages) {
      res.status(403).type("text/plain").send("forbidden");
      return;
    }
    // `dotfiles: "allow"` is load-bearing: our baseDir lives under
    // ~/.kanban-code and Express's default ("ignore") silently 404s any
    // path with a dot-prefixed segment, regardless of whether the file
    // actually exists.
    res.sendFile(full, { dotfiles: "allow" }, (err) => {
      if (err && !res.headersSent) {
        res.status(404).type("text/plain").send("not found");
      }
    });
  });

  // ── Long-polling ──────────────────────────────────────────────────
  // The obvious choice would be SSE, but Cloudflare's quick-tunnel edge
  // buffers streaming responses until the origin closes the connection
  // (see github.com/cloudflare/cloudflared#199), which makes an idle
  // SSE stream invisible to the browser. X-Accel-Buffering, content-type,
  // even forked cloudflared — none of it works on trycloudflare.com, and
  // we have no dashboard access for Transform/Cache rules.
  //
  // Long-polling sidesteps the buffer entirely: each response is short-
  // lived, so the edge has no excuse to hold bytes. The client sends
  // `?since=<lastId>`; we either return immediately (if newer messages
  // exist) or hang for up to `LONG_POLL_HOLD_MS`, resolving on the next
  // jsonl append.
  app.get("/api/channels/:name/poll", requireToken, requireChannel, (req, res) => {
    const since = typeof req.query.since === "string" ? req.query.since : "";
    const path = channelLogPath(deps.channelName, deps.baseDir);

    const flushIfNewer = (): boolean => {
      const all = readMessages(deps.channelName, deps.baseDir);
      // `since` is a message id — return everything after it. Empty `since`
      // is a cold-start poll, which should not flood the client with
      // history (the client separately calls /history on mount). Return
      // nothing so we wait on the next append.
      const idx = since ? all.findIndex((m) => m.id === since) : all.length - 1;
      // If the caller's `since` id isn't in the log any more (shouldn't
      // happen — we never rewrite history), treat as cold start and
      // return the full tail so they re-sync rather than get stuck.
      const newer = idx < 0 ? all : all.slice(idx + 1);
      if (newer.length === 0) return false;
      res.json({ messages: newer, lastId: newer[newer.length - 1].id });
      return true;
    };

    if (flushIfNewer()) return;

    // No new messages yet — watch the jsonl until one appears or we time out.
    const watcher = watch(path, {
      persistent: true,
      usePolling: false,
      awaitWriteFinish: { stabilityThreshold: 30, pollInterval: 20 },
      ignoreInitial: true,
    });
    let done = false;
    let holdTimer: NodeJS.Timeout;
    const cleanup = (timedOut: boolean): void => {
      if (done) return;
      done = true;
      clearTimeout(holdTimer);
      watcher.close().catch(() => { /* ignore */ });
      if (timedOut && !res.headersSent) {
        res.json({ messages: [], lastId: since });
      }
    };
    holdTimer = setTimeout(() => cleanup(true), LONG_POLL_HOLD_MS);
    const onChange = (): void => { if (flushIfNewer()) cleanup(false); };
    watcher.on("add", onChange);
    watcher.on("change", onChange);
    req.on("close", () => cleanup(false));
  });

  // ── Static web client ─────────────────────────────────────────────
  // Served last so API routes win. Only if webDistDir was provided.
  if (deps.webDistDir) {
    app.use(express.static(deps.webDistDir, { index: "index.html" }));
    // SPA fallback: any non-API route serves index.html.
    app.get(/^(?!\/api\/).*/, (_req, res) => {
      res.sendFile(join(deps.webDistDir!, "index.html"));
    });
  }

  return app;
}

// Utility so SPA fallback's Path import is reachable without re-importing.
const _pathUsed = dirname;
void _pathUsed;
