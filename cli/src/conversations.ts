/**
 * Conversations inside one card: topic threads over the card's single session.
 *
 * The master that owns the card keeps an append-only log per card,
 * `<kanbanHome>/conversations/<cardId>.jsonl`, one event per line. Another
 * master reads its copy under `<kanbanHome>/peers/<machine>/conversations/`.
 * See docs/conversations.md for the format.
 */
import { closeSync, copyFileSync, existsSync, mkdirSync, openSync, readdirSync, readFileSync, readSync, statSync, writeSync } from "node:fs";
import { dirname, join } from "node:path";
import { CONVERSATION_ADJECTIVES, CONVERSATION_ANIMALS } from "./conversation-words.js";
import { generateKsuid } from "./ksuid.js";
import { isForeignCard, machineLabel } from "./machines.js";
import { kanbanHome } from "./paths.js";
import type { Link } from "./types.js";

// ── Events ───────────────────────────────────────────────────────────

export type ConversationRole = "human" | "agent";

export type ConversationEvent =
  | {
      type: "created";
      conv: string;
      at: string;
      by: ConversationRole;
      quote?: string;
      quoteRole?: ConversationRole;
      quoteReply?: string;
      title?: string;
    }
  | { type: "message"; conv: string; id: string; role: ConversationRole; text: string; at: string }
  | { type: "title"; conv: string; title: string; at: string; by: ConversationRole }
  | { type: "read"; conv: string; at: string }
  | { type: "retracted"; conv: string; id: string; at: string }
  | { type: "archived"; conv: string; at: string; archived: boolean };

export interface ConversationMessage {
  id: string;
  role: ConversationRole;
  text: string;
  at: string;
}

export interface Conversation {
  id: string;
  title?: string;
  createdAt: string;
  createdBy?: ConversationRole;
  quote?: string;
  /** Who wrote `quote`; absent is the agent. */
  quoteRole?: ConversationRole;
  /** With a quote of the human's: the agent's answer to it. */
  quoteReply?: string;
  archived: boolean;
  lastReadAt?: string;
  messages: ConversationMessage[];
}

export interface ConversationSummary {
  id: string;
  title?: string;
  createdAt: string;
  updatedAt: string;
  messageCount: number;
  lastRole?: ConversationRole;
  preview?: string;
  unread: boolean;
  waiting: boolean;
  archived: boolean;
  quote?: string;
  quoteRole?: ConversationRole;
  quoteReply?: string;
  /** The agent wrote in it at least once. */
  replied: boolean;
}

export const PREVIEW_LENGTH = 120;

// ── Fold ─────────────────────────────────────────────────────────────

function isRole(value: unknown): value is ConversationRole {
  return value === "human" || value === "agent";
}

function str(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}

/**
 * Builds the conversations from the log text, in the order they were created.
 * A line that does not parse, or lacks the fields its type needs, is skipped.
 */
export function foldConversations(logText: string): Conversation[] {
  const byId = new Map<string, Conversation>();
  const ensure = (conv: string, at: string): Conversation => {
    let found = byId.get(conv);
    if (!found) {
      found = { id: conv, createdAt: at, archived: false, messages: [] };
      byId.set(conv, found);
    }
    return found;
  };

  for (const line of logText.split("\n")) {
    if (!line.trim()) continue;
    let raw: Record<string, unknown>;
    try {
      const parsed = JSON.parse(line);
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) continue;
      raw = parsed as Record<string, unknown>;
    } catch {
      continue;
    }
    const conv = str(raw.conv);
    const at = str(raw.at);
    if (!conv || !at) continue;

    switch (raw.type) {
      case "created": {
        const target = ensure(conv, at);
        target.createdAt = at;
        if (isRole(raw.by)) target.createdBy = raw.by;
        const quote = str(raw.quote);
        if (quote) {
          target.quote = quote;
          if (isRole(raw.quoteRole)) target.quoteRole = raw.quoteRole;
          const reply = str(raw.quoteReply);
          if (reply) target.quoteReply = reply;
        }
        const title = str(raw.title)?.trim();
        if (title) target.title = title;
        break;
      }
      case "message": {
        const id = str(raw.id);
        const text = str(raw.text) ?? "";
        if (!id || !isRole(raw.role)) break;
        const target = ensure(conv, at);
        const existing = target.messages.find((message) => message.id === id);
        if (existing) existing.text = text;
        else target.messages.push({ id, role: raw.role, text, at });
        break;
      }
      case "title": {
        const title = str(raw.title);
        if (title === undefined) break;
        const target = ensure(conv, at);
        target.title = title.trim() || undefined;
        break;
      }
      case "read": {
        const target = ensure(conv, at);
        if (!target.lastReadAt || at > target.lastReadAt) target.lastReadAt = at;
        break;
      }
      case "retracted": {
        const id = str(raw.id);
        if (!id) break;
        const target = ensure(conv, at);
        target.messages = target.messages.filter((message) => message.id !== id);
        break;
      }
      case "archived": {
        ensure(conv, at).archived = typeof raw.archived === "boolean" ? raw.archived : true;
        break;
      }
      default:
        break;
    }
  }
  return [...byId.values()];
}

/** The start of a message on one line: lines trimmed and joined with spaces, cut with an ellipsis. */
export function previewText(text: string, limit = PREVIEW_LENGTH): string {
  const flat = text
    .split(/\r\n|\r|\n/)
    .map((line) => line.trim())
    .filter((line) => line.length > 0)
    .join(" ");
  const chars = Array.from(flat);
  return chars.length > limit ? chars.slice(0, limit - 1).join("") + "\u2026" : flat;
}

export function summarizeConversation(conversation: Conversation): ConversationSummary {
  const last = conversation.messages[conversation.messages.length - 1];
  const unread = conversation.messages.some(
    (message) => message.role === "agent" && (!conversation.lastReadAt || message.at > conversation.lastReadAt)
  );
  const summary: ConversationSummary = {
    id: conversation.id,
    createdAt: conversation.createdAt,
    updatedAt: last?.at ?? conversation.createdAt,
    messageCount: conversation.messages.length,
    unread,
    waiting: last?.role === "agent",
    archived: conversation.archived,
    replied: conversation.messages.some((message) => message.role === "agent"),
  };
  if (conversation.title) summary.title = conversation.title;
  if (last) {
    summary.lastRole = last.role;
    summary.preview = previewText(last.text);
  }
  if (conversation.quote) summary.quote = conversation.quote;
  if (conversation.quoteRole) summary.quoteRole = conversation.quoteRole;
  if (conversation.quoteReply) summary.quoteReply = conversation.quoteReply;
  return summary;
}

/** Summaries, most recent first. Archived ones only with `includeArchived`. */
export function listSummaries(conversations: Conversation[], includeArchived = false): ConversationSummary[] {
  return conversations
    .map(summarizeConversation)
    .filter((summary) => includeArchived || !summary.archived)
    .sort((a, b) => b.updatedAt.localeCompare(a.updatedAt));
}

// ── Ids ──────────────────────────────────────────────────────────────

/** Lowercase ASCII letters, digits and dashes, with at least one dash, at most 64 characters. */
export function isValidConversationId(id: string): boolean {
  return id.length > 0 && id.length <= 64 && id.includes("-") && /^[a-z0-9-]+$/.test(id);
}

/** A two-word id (`adjective-animal`) that no conversation of the card uses yet. */
export function generateConversationId(existing: Iterable<string>, random: () => number = Math.random): string {
  const taken = new Set(existing);
  const pick = (words: readonly string[]) => words[Math.floor(random() * words.length) % words.length];
  for (let attempt = 0; attempt < 200; attempt++) {
    const candidate = `${pick(CONVERSATION_ADJECTIVES)}-${pick(CONVERSATION_ANIMALS)}`;
    if (!taken.has(candidate)) return candidate;
  }
  for (const adjective of CONVERSATION_ADJECTIVES) {
    for (const animal of CONVERSATION_ANIMALS) {
      const candidate = `${adjective}-${animal}`;
      if (!taken.has(candidate)) return candidate;
    }
  }
  const base = `${pick(CONVERSATION_ADJECTIVES)}-${pick(CONVERSATION_ANIMALS)}`;
  let suffix = 2;
  while (taken.has(`${base}-${suffix}`)) suffix++;
  return `${base}-${suffix}`;
}

// ── Storage ──────────────────────────────────────────────────────────

export function conversationLogPath(cardId: string): string {
  return join(kanbanHome(), "conversations", `${cardId}.jsonl`);
}

export function peerConversationLogPath(machineId: string, cardId: string): string {
  return join(kanbanHome(), "peers", machineId, "conversations", `${cardId}.jsonl`);
}

/**
 * The newest peer copy of a card's log. A master that adopted a card from
 * another one continues from the copy it kept of that master's log.
 */
function adoptedMirrorPath(cardId: string): string | undefined {
  const peersDir = join(kanbanHome(), "peers");
  let machines: string[];
  try {
    machines = readdirSync(peersDir);
  } catch {
    return undefined;
  }
  let best: { path: string; mtime: number } | undefined;
  for (const machine of machines) {
    const path = peerConversationLogPath(machine, cardId);
    try {
      const mtime = statSync(path).mtimeMs;
      if (!best || mtime > best.mtime) best = { path, mtime };
    } catch {
      // No copy from this machine.
    }
  }
  return best?.path;
}

export class ConversationError extends Error {}

/** The log a reader should use for this card: the owner's, or this master's copy of it. */
export function readableLogPath(card: Link, localMachineId: string | undefined): string | undefined {
  if (isForeignCard(card, localMachineId)) {
    const path = peerConversationLogPath(card.ownerMachine!, card.id);
    return existsSync(path) ? path : undefined;
  }
  const local = conversationLogPath(card.id);
  if (existsSync(local)) return local;
  return adoptedMirrorPath(card.id);
}

export function readCardConversations(card: Link, localMachineId: string | undefined): Conversation[] {
  const path = readableLogPath(card, localMachineId);
  if (!path) return [];
  try {
    return foldConversations(readFileSync(path, "utf-8"));
  } catch {
    return [];
  }
}

function assertOwned(card: Link, localMachineId: string | undefined): void {
  if (isForeignCard(card, localMachineId)) {
    throw new ConversationError(`card runs on ${machineLabel(card.ownerMachine!)}; run this there`);
  }
}

/**
 * Appends events to the card's log with one `O_APPEND` write, so the app and
 * other CLI runs never interleave a line. A card this master adopted starts
 * from its copy of the previous owner's log.
 */
export function appendConversationEvents(card: Link, localMachineId: string | undefined, events: ConversationEvent[]): void {
  assertOwned(card, localMachineId);
  if (events.length === 0) return;
  const path = conversationLogPath(card.id);
  mkdirSync(dirname(path), { recursive: true });
  if (!existsSync(path)) {
    const mirror = adoptedMirrorPath(card.id);
    if (mirror) {
      try {
        copyFileSync(mirror, path);
      } catch {
        // A missing copy only loses history; the new events still land.
      }
    }
  }
  let payload = "";
  if (existsSync(path) && !endsWithNewline(path)) payload = "\n";
  payload += events.map((event) => JSON.stringify(event) + "\n").join("");
  const fd = openSync(path, "a");
  try {
    writeSync(fd, payload);
  } finally {
    closeSync(fd);
  }
}

/** True for an empty file or one whose last byte is a newline. */
function endsWithNewline(path: string): boolean {
  const size = statSync(path).size;
  if (size === 0) return true;
  const fd = openSync(path, "r");
  try {
    const last = Buffer.alloc(1);
    readSync(fd, last, 0, 1, size - 1);
    return last[0] === 0x0a;
  } finally {
    closeSync(fd);
  }
}

// ── Commands ─────────────────────────────────────────────────────────

export interface ConversationContext {
  card: Link;
  localMachineId: string | undefined;
  now?: () => Date;
  newMessageId?: () => string;
}

function timestamp(ctx: ConversationContext): string {
  return (ctx.now ? ctx.now() : new Date()).toISOString();
}

function messageId(ctx: ConversationContext): string {
  return ctx.newMessageId ? ctx.newMessageId() : generateKsuid("msg");
}

function unknownConversation(conv: string, conversations: Conversation[]): ConversationError {
  const known = conversations.map((c) => `  ${c.id}  ${c.title ?? "New conversation"}${c.archived ? "  (archived)" : ""}`);
  const list = known.length > 0 ? `Conversations on this card:\n${known.join("\n")}` : "This card has no conversations yet.";
  return new ConversationError(`No conversation "${conv}" on this card.\n${list}`);
}

function requireConversation(ctx: ConversationContext, conv: string): Conversation {
  const conversations = readCardConversations(ctx.card, ctx.localMachineId);
  const found = conversations.find((c) => c.id === conv);
  if (!found) throw unknownConversation(conv, conversations);
  return found;
}

function findSummary(ctx: ConversationContext, conv: string): ConversationSummary {
  const found = readCardConversations(ctx.card, ctx.localMachineId).find((c) => c.id === conv);
  if (!found) throw new ConversationError(`Conversation "${conv}" vanished from the log.`);
  return summarizeConversation(found);
}

export interface ReplyResult {
  conversation: ConversationSummary;
  message?: ConversationMessage;
  title?: string;
}

/** `kanban reply`: the agent's message in a conversation, and its title when given. */
export function replyToConversation(
  ctx: ConversationContext,
  conv: string,
  text: string,
  title?: string
): ReplyResult {
  assertOwned(ctx.card, ctx.localMachineId);
  const trimmedTitle = title?.trim();
  if (!text.trim() && !trimmedTitle) throw new ConversationError("Nothing to send: pass the reply text, `-` for stdin, or --title.");
  requireConversation(ctx, conv);
  const at = timestamp(ctx);
  const events: ConversationEvent[] = [];
  if (trimmedTitle) events.push({ type: "title", conv, title: trimmedTitle, at, by: "agent" });
  let message: ConversationMessage | undefined;
  if (text.trim()) {
    message = { id: messageId(ctx), role: "agent", text, at };
    events.push({ type: "message", conv, ...message });
  }
  appendConversationEvents(ctx.card, ctx.localMachineId, events);
  const result: ReplyResult = { conversation: findSummary(ctx, conv), message };
  if (trimmedTitle) result.title = trimmedTitle;
  return result;
}

/** `kanban conversation new`: a conversation the agent starts, optionally speaking first. */
export function createConversation(
  ctx: ConversationContext,
  opts: { title?: string; message?: string; random?: () => number } = {}
): ReplyResult {
  assertOwned(ctx.card, ctx.localMachineId);
  const conversations = readCardConversations(ctx.card, ctx.localMachineId);
  const conv = generateConversationId(conversations.map((c) => c.id), opts.random);
  const at = timestamp(ctx);
  const title = opts.title?.trim();
  const created: ConversationEvent = { type: "created", conv, at, by: "agent" };
  if (title) created.title = title;
  const events: ConversationEvent[] = [created];
  let message: ConversationMessage | undefined;
  if (opts.message?.trim()) {
    message = { id: messageId(ctx), role: "agent", text: opts.message, at };
    events.push({ type: "message", conv, ...message });
  }
  appendConversationEvents(ctx.card, ctx.localMachineId, events);
  const result: ReplyResult = { conversation: findSummary(ctx, conv), message };
  if (title) result.title = title;
  return result;
}

/** `kanban conversation title`: renames a conversation as the agent. */
export function setConversationTitle(ctx: ConversationContext, conv: string, title: string): ConversationSummary {
  assertOwned(ctx.card, ctx.localMachineId);
  const trimmed = title.trim();
  if (!trimmed) throw new ConversationError("The title is empty.");
  requireConversation(ctx, conv);
  appendConversationEvents(ctx.card, ctx.localMachineId, [
    { type: "title", conv, title: trimmed, at: timestamp(ctx), by: "agent" },
  ]);
  return findSummary(ctx, conv);
}

export function listCardConversations(ctx: ConversationContext, includeArchived = false): ConversationSummary[] {
  return listSummaries(readCardConversations(ctx.card, ctx.localMachineId), includeArchived);
}

export interface ConversationDetail {
  conversation: ConversationSummary;
  messages: ConversationMessage[];
}

/** `kanban conversation show`: the conversation and its messages, oldest first; `limit` keeps the newest. */
export function showConversation(ctx: ConversationContext, conv: string, limit?: number): ConversationDetail {
  const found = requireConversation(ctx, conv);
  const messages = limit && limit > 0 ? found.messages.slice(-limit) : found.messages;
  return { conversation: summarizeConversation(found), messages };
}

// ── Formatting ───────────────────────────────────────────────────────

export function displayTitle(summary: { title?: string }): string {
  return summary.title ?? "New conversation";
}

export function formatConversationList(summaries: ConversationSummary[]): string {
  if (summaries.length === 0) return "No conversations.";
  const idWidth = Math.max(...summaries.map((s) => s.id.length));
  const titleWidth = Math.min(40, Math.max(...summaries.map((s) => displayTitle(s).length)));
  return summaries
    .map((summary) => {
      const title = displayTitle(summary);
      const shownTitle = title.length > titleWidth ? title.slice(0, titleWidth - 3) + "..." : title;
      const parts = [
        summary.id.padEnd(idWidth),
        shownTitle.padEnd(titleWidth),
        `${summary.messageCount} ${summary.messageCount === 1 ? "msg" : "msgs"}`.padEnd(8),
      ];
      const states: string[] = [];
      if (summary.waiting) states.push("waiting on human");
      if (summary.unread) states.push("unread");
      if (summary.archived) states.push("archived");
      return [...parts, ...states].join("  ").trimEnd();
    })
    .join("\n");
}

function formatTime(iso: string): string {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return iso;
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

export function formatConversationDetail(detail: ConversationDetail): string {
  const { conversation, messages } = detail;
  const lines = [`${conversation.id}  ${displayTitle(conversation)}`];
  if (conversation.quote) {
    if (conversation.quoteRole === "human") {
      lines.push(`continues the human's message: ${previewText(conversation.quote)}`);
      if (conversation.quoteReply) lines.push(`and the reply: ${previewText(conversation.quoteReply)}`);
    } else {
      lines.push(`continues: ${previewText(conversation.quote)}`);
    }
  }
  if (messages.length === 0) lines.push("", "No messages yet.");
  for (const message of messages) {
    const [first, ...rest] = message.text.split("\n");
    lines.push("", `[${formatTime(message.at)}] ${message.role}: ${first}`);
    for (const line of rest) lines.push(line ? `  ${line}` : "");
  }
  return lines.join("\n");
}
