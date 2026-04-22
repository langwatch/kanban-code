/**
 * Share server — Express app that exposes a channel over a public URL via
 * cloudflared. Read path is SSE (no WebSockets — SSE tunnels cleanly through
 * any HTTP proxy). Write path is plain POST. Broadcast reuses
 * `sendAndFanOut()` so messages land in every member's tmux session the same
 * way the Swift UI and CLI already do.
 */

import express, { Request, Response, NextFunction, Express } from "express";
import { watch } from "chokidar";
import { mkdirSync, createReadStream, writeFileSync, statSync } from "node:fs";
import { join, dirname } from "node:path";
import { randomUUID } from "node:crypto";

import type { Link } from "./types.js";
import {
  channelLogPath,
  getChannel,
  readMessages,
  type ChannelMessage,
} from "./channels.js";
import { sendAndFanOut, type Sender, type LiveSessionProbe } from "./broadcast.js";

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

  // ── Info ──────────────────────────────────────────────────────────
  app.get("/api/channels/:name/info", requireToken, requireChannel, (_req, res) => {
    const ch = getChannel(deps.channelName, deps.baseDir)!;
    res.json({
      name: ch.name,
      members: ch.members.map((m) => ({ handle: m.handle })),
      remainingMs: Math.max(0, deps.expiresAt - Date.now()),
      expiresAt: new Date(deps.expiresAt).toISOString(),
    });
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

  // ── SSE stream ────────────────────────────────────────────────────
  // Emits every `ChannelMessage` appended to the channel jsonl after the
  // stream is opened. A tail-offset (byte position) is tracked per
  // connection so chokidar file events translate into exactly-once
  // delivery of each new line.
  app.get("/api/channels/:name/stream", requireToken, requireChannel, (req, res) => {
    // Disable compression buffering; SSE needs flushes.
    res.setHeader("Content-Type", "text/event-stream");
    res.setHeader("Cache-Control", "no-cache, no-transform");
    res.setHeader("Connection", "keep-alive");
    // Hint to any reverse proxy that this is a streaming response.
    res.setHeader("X-Accel-Buffering", "no");
    res.flushHeaders();

    // Prime the connection so the client's EventSource `open` fires.
    res.write(`: connected ${new Date().toISOString()}\n\n`);

    const path = channelLogPath(deps.channelName, deps.baseDir);
    // Track where we've already emitted up to — start at current EOF so we
    // don't flood the client with historical messages on connect (client
    // requests /history for that).
    let offset = 0;
    try { offset = statSync(path).size; } catch { /* file may not exist yet */ }

    const watcher = watch(path, {
      persistent: true,
      usePolling: false,
      awaitWriteFinish: { stabilityThreshold: 30, pollInterval: 20 },
      ignoreInitial: true,
    });

    // Keepalive — some proxies kill idle connections; a comment every 20s
    // prevents that without showing anything to the client.
    const keepalive = setInterval(() => {
      res.write(`: keepalive\n\n`);
    }, 20_000);

    const emitNewLines = (): void => {
      let size: number;
      try { size = statSync(path).size; } catch { return; }
      if (size <= offset) return;
      const stream = createReadStream(path, { start: offset, end: size - 1 });
      let buf = "";
      stream.on("data", (chunk) => {
        buf += chunk.toString("utf-8");
      });
      stream.on("end", () => {
        const lines = buf.split("\n").filter(Boolean);
        for (const line of lines) {
          let msg: ChannelMessage;
          try { msg = JSON.parse(line) as ChannelMessage; } catch { continue; }
          res.write(`event: message\ndata: ${JSON.stringify(msg)}\n\n`);
        }
        offset = size;
      });
    };

    watcher.on("add", emitNewLines);
    watcher.on("change", emitNewLines);

    req.on("close", () => {
      clearInterval(keepalive);
      watcher.close();
      try { res.end(); } catch { /* already closed */ }
    });
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
