import { existsSync, statSync, openSync, readSync, closeSync } from "node:fs";
import { randomUUID } from "node:crypto";
import { hookEventsPath } from "../paths.js";
import { readLinks, readSessionContext, pasteTmuxPrompt } from "../data.js";
import { upsertCard, isoNow } from "../cards.js";
import { installHooks } from "../hooks.js";
import { announceSuppressPath, ANNOUNCE_SUPPRESS_TTL_MS } from "../slack/announce-suppress.js";
import { Link, QueuedPrompt, SessionContext } from "../types.js";

export type SelfCompactAction = "queuePrompt" | "compactNow";
export interface SelfCompactRule {
  thresholdTokens: number;
  action: SelfCompactAction;
  message: string;
}

/// Thresholds + messages mirror the Swift SelfCompactRule.defaults so queued
/// warnings match (drop-stale compares prompt body against rule.message).
export const DEFAULT_SELF_COMPACT_RULES: SelfCompactRule[] = [
  { thresholdTokens: 500_000, action: "queuePrompt", message: "You are above the 500k context limit. Whenever it is convenient, use the kanban CLI to send yourself a self-compact." },
  { thresholdTokens: 600_000, action: "queuePrompt", message: "You are above the 600k context limit. Please compact yourself soon using the kanban CLI self-compact command." },
  { thresholdTokens: 700_000, action: "queuePrompt", message: "You are above the 700k context limit. Compact yourself IMMEDIATELY using the kanban CLI self-compact command." },
  { thresholdTokens: 750_000, action: "compactNow", message: "/compact" },
];

export interface HookEvent {
  sessionId: string;
  event: string;
  timestampMs: number;
  transcriptPath?: string;
  /// The submitted prompt text, present on UserPromptSubmit events (decoded
  /// from the hook's base64 payload). Used to mirror the exact received text.
  prompt?: string;
}

export interface DaemonOptions {
  /// Auto-compact poll interval. Default 30s (matches the Swift monitor).
  pollIntervalMs?: number;
  /// Delay after a Stop before auto-sending a queued prompt. Default 1s.
  autoSendDelayMs?: number;
  selfCompact?: { enabled: boolean; rules?: SelfCompactRule[] };
  /// Side effect for sending text to a tmux session. Injectable for tests.
  paste?: (sessionName: string, text: string) => void;
  /// Optional: mirror a confirmed-received prompt to the agent's Slack channel.
  /// Called on UserPromptSubmit (real receipt), never on mere paste, and never
  /// for relayed Slack-human messages. Fire-and-forget; not used in tests.
  announce?: (slug: string, text: string) => void;
}

function currentContextTokens(ctx: SessionContext): number {
  if (ctx.contextWindowSize > 0 && ctx.usedPercentage > 0) {
    return Math.round((ctx.contextWindowSize * ctx.usedPercentage) / 100);
  }
  return ctx.totalInputTokens + ctx.totalOutputTokens;
}

/// The headless replacement for the macOS app's background loops: tails
/// hook-events.jsonl to auto-send queued prompts after a Stop, and polls context
/// usage to queue self-compact warnings / send "/compact". Single-threaded; all
/// state mutation goes through the same links.json writer the rest of the CLI uses.
export class Daemon {
  private readonly pollIntervalMs: number;
  private readonly autoSendDelayMs: number;
  private readonly selfCompactEnabled: boolean;
  private readonly rules: SelfCompactRule[];
  private readonly paste: (sessionName: string, text: string) => void;
  private readonly announce: (slug: string, text: string) => void;

  /// Last time we saw a user/relay prompt per session (ms). Pauses auto-send.
  private lastPromptAt = new Map<string, number>();
  /// Highest self-compact threshold already actioned per session.
  private lastTriggered = new Map<string, number>();
  /// Byte offset into hook-events.jsonl already consumed.
  private offset = 0;
  /// Byte offset into announce-suppress.jsonl already consumed.
  private suppressOffset = 0;
  /// Per-session queue of unconsumed skip-announce marker timestamps (ms).
  private suppressMarkers = new Map<string, number[]>();

  private pollTimer?: NodeJS.Timeout;
  private eventTimer?: NodeJS.Timeout;

  constructor(opts: DaemonOptions = {}) {
    this.pollIntervalMs = opts.pollIntervalMs ?? 30_000;
    this.autoSendDelayMs = opts.autoSendDelayMs ?? 1_000;
    this.selfCompactEnabled = opts.selfCompact?.enabled ?? true;
    this.rules = (opts.selfCompact?.rules ?? DEFAULT_SELF_COMPACT_RULES)
      .slice()
      .sort((a, b) => a.thresholdTokens - b.thresholdTokens);
    this.paste = opts.paste ?? ((s, t) => pasteTmuxPrompt(s, t));
    this.announce = opts.announce ?? (() => {});
  }

  /// Begin from the current end of the events file so we never act on old
  /// events (e.g. a stale Stop) on startup.
  start(): void {
    installHooks();
    this.offset = existsSync(hookEventsPath()) ? statSync(hookEventsPath()).size : 0;
    this.suppressOffset = existsSync(announceSuppressPath()) ? statSync(announceSuppressPath()).size : 0;
    this.eventTimer = setInterval(() => this.processEvents(), 500);
    this.pollTimer = setInterval(() => this.evaluateAutoCompact(), this.pollIntervalMs);
  }

  stop(): void {
    if (this.eventTimer) clearInterval(this.eventTimer);
    if (this.pollTimer) clearInterval(this.pollTimer);
  }

  /// Read hook events appended since the last read. Only complete lines are
  /// consumed; a partial trailing line is left for next time.
  readNewHookEvents(): HookEvent[] {
    const path = hookEventsPath();
    if (!existsSync(path)) return [];
    const size = statSync(path).size;
    if (size <= this.offset) {
      this.offset = size; // file truncated/rotated
      return [];
    }
    const fd = openSync(path, "r");
    const buf = Buffer.alloc(size - this.offset);
    readSync(fd, buf, 0, buf.length, this.offset);
    closeSync(fd);

    const text = buf.toString("utf-8");
    const lastNl = text.lastIndexOf("\n");
    if (lastNl < 0) return [];
    this.offset += Buffer.byteLength(text.slice(0, lastNl + 1), "utf-8");

    const events: HookEvent[] = [];
    for (const line of text.slice(0, lastNl).split("\n")) {
      if (!line.trim()) continue;
      try {
        const o = JSON.parse(line);
        if (o.sessionId && o.event) {
          let prompt: string | undefined;
          if (o.payloadB64) {
            try {
              const payload = JSON.parse(Buffer.from(o.payloadB64, "base64").toString("utf-8"));
              if (typeof payload?.prompt === "string") prompt = payload.prompt;
            } catch {
              /* malformed payload: fall back to no prompt */
            }
          }
          events.push({
            sessionId: o.sessionId,
            event: o.event,
            timestampMs: o.timestamp ? Date.parse(o.timestamp) : Date.now(),
            transcriptPath: o.transcriptPath,
            prompt,
          });
        }
      } catch {
        /* skip malformed */
      }
    }
    return events;
  }

  /// Consume new events: record user prompts, and schedule an auto-send after
  /// each Stop. Returns the Stop events (handy for tests).
  processEvents(): HookEvent[] {
    const events = this.readNewHookEvents();
    const stops: HookEvent[] = [];
    for (const e of events) {
      if (e.event === "UserPromptSubmit") {
        this.lastPromptAt.set(e.sessionId, Math.max(this.lastPromptAt.get(e.sessionId) ?? 0, e.timestampMs));
        this.announceReceived(e);
      } else if (e.event === "Stop") {
        stops.push(e);
        const stopMs = e.timestampMs;
        setTimeout(() => this.maybeAutoSend(e.sessionId, stopMs), this.autoSendDelayMs);
      }
    }
    return stops;
  }

  /// Mirror a confirmed-received prompt to the agent's Slack channel. Fires on
  /// UserPromptSubmit (real receipt), so a paste that never becomes a submitted
  /// prompt is never announced. A relayed Slack-human message is skipped by
  /// consuming the bridge's skip-announce marker so it is not echoed back.
  announceReceived(e: HookEvent): void {
    if (!e.prompt) return;
    if (this.consumeSuppress(e.sessionId)) return; // bridge relay: already in Slack
    const card = readLinks().find((c) => c.sessionLink?.sessionId === e.sessionId);
    const slug = card?.name;
    if (slug) this.announce(slug, e.prompt);
  }

  /// Tail the bridge's skip-announce markers appended since the last read into
  /// the per-session queue, then drop any older than the TTL.
  private ingestSuppressMarkers(now = Date.now()): void {
    const path = announceSuppressPath();
    if (existsSync(path)) {
      const size = statSync(path).size;
      if (size < this.suppressOffset) this.suppressOffset = 0; // truncated/rotated
      if (size > this.suppressOffset) {
        const fd = openSync(path, "r");
        const buf = Buffer.alloc(size - this.suppressOffset);
        readSync(fd, buf, 0, buf.length, this.suppressOffset);
        closeSync(fd);
        const text = buf.toString("utf-8");
        const lastNl = text.lastIndexOf("\n");
        if (lastNl >= 0) {
          this.suppressOffset += Buffer.byteLength(text.slice(0, lastNl + 1), "utf-8");
          for (const line of text.slice(0, lastNl).split("\n")) {
            if (!line.trim()) continue;
            try {
              const o = JSON.parse(line);
              if (o.sessionId && typeof o.ts === "number") {
                const list = this.suppressMarkers.get(o.sessionId) ?? [];
                list.push(o.ts);
                this.suppressMarkers.set(o.sessionId, list);
              }
            } catch {
              /* skip malformed */
            }
          }
        }
      }
    }
    for (const [sid, list] of this.suppressMarkers) {
      const fresh = list.filter((ts) => now - ts <= ANNOUNCE_SUPPRESS_TTL_MS);
      if (fresh.length) this.suppressMarkers.set(sid, fresh);
      else this.suppressMarkers.delete(sid);
    }
  }

  /// If a non-expired skip-announce marker exists for this session, consume the
  /// oldest one and return true (so the caller skips that announce).
  consumeSuppress(sessionId: string, now = Date.now()): boolean {
    this.ingestSuppressMarkers(now);
    const list = this.suppressMarkers.get(sessionId);
    if (!list || list.length === 0) return false;
    list.shift(); // one marker suppresses exactly one received prompt
    if (list.length === 0) this.suppressMarkers.delete(sessionId);
    return true;
  }

  /// Auto-send the first auto-sendable queued prompt for a session, unless a
  /// user/relay prompted after the Stop, or the prompt is a now-stale
  /// self-compact warning.
  maybeAutoSend(sessionId: string, stopMs: number): { sent: boolean; reason?: string } {
    if ((this.lastPromptAt.get(sessionId) ?? 0) > stopMs) {
      return { sent: false, reason: "user-prompted" };
    }
    const card = readLinks().find((c) => c.sessionLink?.sessionId === sessionId);
    const sessionName = card?.tmuxLink?.sessionName;
    if (!card || !sessionName) return { sent: false, reason: "no-tmux" };

    const first = card.queuedPrompts?.[0];
    if (!first || !first.sendAutomatically) return { sent: false, reason: "no-eligible" };

    if (this.shouldDropStaleSelfCompact(first, sessionId)) {
      this.dequeue(card.id, first.id);
      return { sent: false, reason: "dropped-stale" };
    }

    this.paste(sessionName, first.body);
    this.dequeue(card.id, first.id);
    // Treat our own auto-send as a prompt so the next Stop sends the next one.
    this.lastPromptAt.set(sessionId, Date.now());
    // The mirror to Slack happens on this prompt's own UserPromptSubmit (real
    // receipt), via announceReceived, not here at paste time.
    return { sent: true };
  }

  /// Poll context usage and act on the highest newly-crossed self-compact rule.
  /// Returns a description of actions taken (handy for tests/logging).
  evaluateAutoCompact(): { sessionId: string; action: SelfCompactAction; thresholdTokens: number }[] {
    if (!this.selfCompactEnabled) return [];
    const acted: { sessionId: string; action: SelfCompactAction; thresholdTokens: number }[] = [];

    for (const card of readLinks()) {
      const sessionId = card.sessionLink?.sessionId;
      const sessionName = card.tmuxLink?.sessionName;
      if (!sessionId || !sessionName || card.manuallyArchived) continue;
      const ctx = readSessionContext(sessionId);
      if (!ctx) continue;
      const tokens = currentContextTokens(ctx);

      const rule = [...this.rules].reverse().find((r) => tokens >= r.thresholdTokens);
      if (!rule) {
        this.lastTriggered.delete(sessionId); // dropped below all thresholds; allow re-trigger
        continue;
      }
      if (rule.thresholdTokens <= (this.lastTriggered.get(sessionId) ?? 0)) continue;

      if (rule.action === "queuePrompt") {
        this.enqueueOnce(card.id, rule.message);
      } else {
        this.paste(sessionName, "/compact");
        this.announce(card.name ?? "", `🧹 context over ${Math.round(rule.thresholdTokens / 1000)}k - sending /compact`);
      }
      this.lastTriggered.set(sessionId, rule.thresholdTokens);
      acted.push({ sessionId, action: rule.action, thresholdTokens: rule.thresholdTokens });
    }
    return acted;
  }

  private shouldDropStaleSelfCompact(prompt: QueuedPrompt, sessionId: string): boolean {
    if (!this.selfCompactEnabled) return false;
    const body = prompt.body.trim();
    const rule = this.rules.find((r) => r.action === "queuePrompt" && r.message.trim() === body);
    if (!rule) return false;
    const ctx = readSessionContext(sessionId);
    if (!ctx) return true; // no usage data -> warning is stale
    return currentContextTokens(ctx) < rule.thresholdTokens;
  }

  private dequeue(cardId: string, promptId: string): void {
    const card = readLinks().find((c) => c.id === cardId);
    if (!card) return;
    const next: Link = {
      ...card,
      queuedPrompts: (card.queuedPrompts ?? []).filter((p) => p.id !== promptId),
      updatedAt: isoNow(),
    };
    upsertCard(next);
  }

  private enqueueOnce(cardId: string, body: string): void {
    const card = readLinks().find((c) => c.id === cardId);
    if (!card) return;
    const queue = card.queuedPrompts ?? [];
    if (queue.some((p) => p.body.trim() === body.trim())) return; // already queued
    const prompt: QueuedPrompt = { id: randomUUID(), body, sendAutomatically: true };
    upsertCard({ ...card, queuedPrompts: [...queue, prompt], updatedAt: isoNow() });
  }
}
