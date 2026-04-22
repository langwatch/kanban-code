/**
 * Chat channel data layer.
 *
 * Storage layout under the kanban dir (default ~/.kanban-code/):
 *   channels/
 *     channels.json           — metadata { channels: [{id, name, createdAt, createdBy, members: [...]}] }
 *     <name>.jsonl            — append-only message log
 *     dm/<cardA>_<cardB>.jsonl — DM log between two cards (ids sorted)
 *
 * All functions are parametric on `baseDir` so tests can sandbox into tmp dirs.
 */

import {
  existsSync,
  mkdirSync,
  readFileSync,
  writeFileSync,
  appendFileSync,
  readdirSync,
  statSync,
  renameSync,
  unlinkSync,
} from "node:fs";
import { join, dirname } from "node:path";
import { homedir } from "node:os";
import { randomBytes } from "node:crypto";

// ── Types ─────────────────────────────────────────────────────────────

export interface Member {
  cardId: string | null; // null = the human user
  handle: string;        // no leading "@"
  joinedAt: string;      // ISO timestamp
}

export interface Channel {
  id: string;
  name: string;
  createdAt: string;
  createdBy: { cardId: string | null; handle: string };
  members: Member[];
}

export interface ChannelMessage {
  id: string;
  ts: string; // ISO
  from: { cardId: string | null; handle: string };
  body: string;
  type?: "message" | "join" | "leave" | "system";
  /** Absolute paths to images attached to this message, persisted under
   *  `channels/images/<id>/N.<ext>`. Absent for text-only messages. */
  imagePaths?: string[];
  /** "external" = posted via a public share link by someone outside the team.
   *  Omitted for internal messages. Drives the warning prefix in tmux fanout. */
  source?: "external";
}

interface ChannelsFile {
  channels: Channel[];
}

export interface ChannelDirs {
  base: string;         // <baseDir>/channels
  channelsFile: string; // <baseDir>/channels/channels.json
  dm: string;           // <baseDir>/channels/dm
  images: string;       // <baseDir>/channels/images
}

// ── Paths ─────────────────────────────────────────────────────────────

export function defaultBaseDir(): string {
  return join(homedir(), ".kanban-code");
}

export function channelDirs(baseDir: string = defaultBaseDir()): ChannelDirs {
  const base = join(baseDir, "channels");
  return {
    base,
    channelsFile: join(base, "channels.json"),
    dm: join(base, "dm"),
    images: join(base, "images"),
  };
}

/**
 * Copy each source image into a persistent location under
 * `channels/images/<msgId>/N.<ext>`. Returns the new absolute paths. Source
 * files that don't exist are silently skipped, so callers can pass
 * user-provided paths without pre-validating.
 */
export function persistMessageImages(
  msgId: string,
  sourcePaths: string[],
  baseDir: string = defaultBaseDir()
): string[] {
  if (sourcePaths.length === 0) return [];
  const dirs = ensureDirs(baseDir);
  const msgDir = join(dirs.images, msgId);
  mkdirSync(msgDir, { recursive: true });
  const out: string[] = [];
  sourcePaths.forEach((src, idx) => {
    if (!existsSync(src)) return;
    const ext = src.split(".").pop()?.toLowerCase() || "png";
    const dest = join(msgDir, `${idx}.${ext}`);
    try {
      const data = readFileSync(src);
      writeFileSync(dest, data);
      out.push(dest);
    } catch {
      // Skip unreadable source files
    }
  });
  return out;
}

export function channelLogPath(name: string, baseDir: string = defaultBaseDir()): string {
  validateChannelName(name);
  return join(channelDirs(baseDir).base, `${name}.jsonl`);
}

export function dmLogPath(a: string, b: string, baseDir: string = defaultBaseDir()): string {
  const [lo, hi] = [a, b].sort();
  return join(channelDirs(baseDir).dm, `${lo}__${hi}.jsonl`);
}

// ── Validation ────────────────────────────────────────────────────────

const CHANNEL_NAME_RE = /^[a-z0-9][a-z0-9_-]{0,63}$/;

export function validateChannelName(name: string): void {
  if (!CHANNEL_NAME_RE.test(name)) {
    throw new Error(
      `Invalid channel name "${name}" — must match /^[a-z0-9][a-z0-9_-]{0,63}$/`
    );
  }
}

export function normalizeChannelName(raw: string): string {
  return raw.replace(/^#/, "").trim().toLowerCase();
}

// ── IDs / timestamps ─────────────────────────────────────────────────

function genId(prefix: string): string {
  const rand = randomBytes(8).toString("hex");
  return `${prefix}_${rand}`;
}

function nowIso(): string {
  return new Date().toISOString();
}

// ── Channels file I/O ────────────────────────────────────────────────

function ensureDirs(baseDir: string): ChannelDirs {
  const dirs = channelDirs(baseDir);
  if (!existsSync(dirs.base)) mkdirSync(dirs.base, { recursive: true });
  if (!existsSync(dirs.dm)) mkdirSync(dirs.dm, { recursive: true });
  if (!existsSync(dirs.images)) mkdirSync(dirs.images, { recursive: true });
  return dirs;
}

export function loadChannelsFile(baseDir: string = defaultBaseDir()): ChannelsFile {
  const dirs = channelDirs(baseDir);
  if (!existsSync(dirs.channelsFile)) return { channels: [] };
  try {
    const raw = readFileSync(dirs.channelsFile, "utf-8");
    const parsed = JSON.parse(raw);
    if (!parsed || !Array.isArray(parsed.channels)) return { channels: [] };
    return parsed as ChannelsFile;
  } catch {
    return { channels: [] };
  }
}

function saveChannelsFile(file: ChannelsFile, baseDir: string = defaultBaseDir()): void {
  const dirs = ensureDirs(baseDir);
  const tmp = dirs.channelsFile + ".tmp";
  writeFileSync(tmp, JSON.stringify(file, null, 2));
  renameSync(tmp, dirs.channelsFile);
}

// ── Channel CRUD ─────────────────────────────────────────────────────

export interface CreateOptions {
  createdBy?: { cardId: string | null; handle: string };
}

export function createChannel(
  name: string,
  opts: CreateOptions = {},
  baseDir: string = defaultBaseDir()
): Channel {
  const clean = normalizeChannelName(name);
  validateChannelName(clean);
  const file = loadChannelsFile(baseDir);
  if (file.channels.some((c) => c.name === clean)) {
    throw new Error(`Channel "#${clean}" already exists`);
  }
  const createdBy = opts.createdBy ?? { cardId: null, handle: "user" };
  const channel: Channel = {
    id: genId("ch"),
    name: clean,
    createdAt: nowIso(),
    createdBy,
    members: [],
  };
  file.channels.push(channel);
  saveChannelsFile(file, baseDir);
  // Touch the log file so watchers can subscribe.
  ensureDirs(baseDir);
  const logPath = channelLogPath(clean, baseDir);
  if (!existsSync(logPath)) writeFileSync(logPath, "");
  return channel;
}

export function listChannels(baseDir: string = defaultBaseDir()): Channel[] {
  return loadChannelsFile(baseDir).channels;
}

export function getChannel(name: string, baseDir: string = defaultBaseDir()): Channel | undefined {
  const clean = normalizeChannelName(name);
  return loadChannelsFile(baseDir).channels.find((c) => c.name === clean);
}

export function deleteChannel(name: string, baseDir: string = defaultBaseDir()): boolean {
  const clean = normalizeChannelName(name);
  const file = loadChannelsFile(baseDir);
  const before = file.channels.length;
  file.channels = file.channels.filter((c) => c.name !== clean);
  if (file.channels.length === before) return false;
  saveChannelsFile(file, baseDir);
  return true;
}

// ── Membership ───────────────────────────────────────────────────────

function sameMember(a: { cardId: string | null; handle: string }, b: { cardId: string | null; handle: string }): boolean {
  if (a.cardId !== null && b.cardId !== null) return a.cardId === b.cardId;
  return a.handle === b.handle;
}

/**
 * Rename a channel. Updates `channels.json` and moves the jsonl log file.
 * Throws if the new name already exists. Returns `false` if old name doesn't.
 */
export function renameChannel(
  oldName: string,
  newName: string,
  baseDir: string = defaultBaseDir()
): boolean {
  const oldClean = normalizeChannelName(oldName);
  const newClean = normalizeChannelName(newName);
  if (oldClean === newClean) return false;

  const file = loadChannelsFile(baseDir);
  const idx = file.channels.findIndex((c) => c.name === oldClean);
  if (idx < 0) return false;
  if (file.channels.some((c) => c.name === newClean)) {
    throw new Error(`Channel "#${newClean}" already exists`);
  }

  file.channels[idx].name = newClean;
  saveChannelsFile(file, baseDir);

  const oldLog = channelLogPath(oldClean, baseDir);
  const newLog = channelLogPath(newClean, baseDir);
  if (existsSync(oldLog)) {
    if (existsSync(newLog)) {
      // Shouldn't happen (we just asserted !exists in channels.json) but be defensive.
      unlinkSync(newLog);
    }
    renameSync(oldLog, newLog);
  }
  return true;
}

export function joinChannel(
  name: string,
  member: { cardId: string | null; handle: string },
  baseDir: string = defaultBaseDir()
): { channel: Channel; alreadyMember: boolean } {
  const clean = normalizeChannelName(name);
  const file = loadChannelsFile(baseDir);
  const ch = file.channels.find((c) => c.name === clean);
  if (!ch) throw new Error(`Channel "#${clean}" does not exist`);

  const existing = ch.members.find((m) => sameMember(m, member));
  if (existing) {
    return { channel: ch, alreadyMember: true };
  }

  ch.members.push({
    cardId: member.cardId,
    handle: member.handle,
    joinedAt: nowIso(),
  });
  saveChannelsFile(file, baseDir);
  // Append a synthetic join event to the log so history shows joins.
  appendMessage(
    clean,
    {
      id: genId("msg"),
      ts: nowIso(),
      from: { cardId: member.cardId, handle: member.handle },
      body: `@${member.handle} joined #${clean}`,
      type: "join",
    },
    baseDir
  );
  return { channel: ch, alreadyMember: false };
}

export function leaveChannel(
  name: string,
  who: { cardId: string | null; handle?: string },
  baseDir: string = defaultBaseDir()
): Channel | undefined {
  const clean = normalizeChannelName(name);
  const file = loadChannelsFile(baseDir);
  const ch = file.channels.find((c) => c.name === clean);
  if (!ch) return undefined;
  const match = (m: Member): boolean => {
    if (who.cardId !== null && m.cardId !== null) return m.cardId === who.cardId;
    if (who.handle) return m.handle === who.handle;
    return m.cardId === who.cardId;
  };
  const leavingMember = ch.members.find(match);
  ch.members = ch.members.filter((m) => !match(m));
  saveChannelsFile(file, baseDir);
  if (leavingMember) {
    appendMessage(
      clean,
      {
        id: genId("msg"),
        ts: nowIso(),
        from: { cardId: leavingMember.cardId, handle: leavingMember.handle },
        body: `@${leavingMember.handle} left #${clean}`,
        type: "leave",
      },
      baseDir
    );
  }
  return ch;
}

export function isMember(
  channel: Channel,
  cardId: string | null
): boolean {
  return channel.members.some((m) => m.cardId === cardId);
}

// ── Messages ─────────────────────────────────────────────────────────

export function appendMessage(
  name: string,
  msg: ChannelMessage,
  baseDir: string = defaultBaseDir()
): void {
  ensureDirs(baseDir);
  const path = channelLogPath(name, baseDir);
  appendFileSync(path, JSON.stringify(msg) + "\n");
}

export function sendMessage(
  name: string,
  from: { cardId: string | null; handle: string },
  body: string,
  baseDir: string = defaultBaseDir(),
  imagePaths: string[] = [],
  source?: "external"
): ChannelMessage {
  const clean = normalizeChannelName(name);
  const ch = getChannel(clean, baseDir);
  if (!ch) throw new Error(`Channel "#${clean}" does not exist`);
  const id = genId("msg");
  const persisted = persistMessageImages(id, imagePaths, baseDir);
  const msg: ChannelMessage = {
    id,
    ts: nowIso(),
    from,
    body,
    type: "message",
    ...(persisted.length > 0 ? { imagePaths: persisted } : {}),
    ...(source ? { source } : {}),
  };
  appendMessage(clean, msg, baseDir);
  return msg;
}

export function readMessages(
  name: string,
  baseDir: string = defaultBaseDir()
): ChannelMessage[] {
  const path = channelLogPath(name, baseDir);
  if (!existsSync(path)) return [];
  const raw = readFileSync(path, "utf-8");
  const lines = raw.split("\n").filter(Boolean);
  const msgs: ChannelMessage[] = [];
  for (const line of lines) {
    try {
      msgs.push(JSON.parse(line) as ChannelMessage);
    } catch {
      // skip corrupt lines
    }
  }
  return msgs;
}

export function readTail(
  name: string,
  n: number,
  baseDir: string = defaultBaseDir()
): ChannelMessage[] {
  const all = readMessages(name, baseDir);
  return all.slice(-n);
}

// ── Direct messages ──────────────────────────────────────────────────

export function appendDirectMessage(
  msg: ChannelMessage & { to: { cardId: string | null; handle: string } },
  baseDir: string = defaultBaseDir()
): void {
  ensureDirs(baseDir);
  const idA = msg.from.cardId ?? `@${msg.from.handle}`;
  const idB = msg.to.cardId ?? `@${msg.to.handle}`;
  const path = dmLogPath(idA, idB, baseDir);
  appendFileSync(path, JSON.stringify(msg) + "\n");
}

export function readDirectMessages(
  partyA: string,
  partyB: string,
  baseDir: string = defaultBaseDir()
): ChannelMessage[] {
  const path = dmLogPath(partyA, partyB, baseDir);
  if (!existsSync(path)) return [];
  const raw = readFileSync(path, "utf-8");
  const lines = raw.split("\n").filter(Boolean);
  const out: ChannelMessage[] = [];
  for (const line of lines) {
    try {
      out.push(JSON.parse(line));
    } catch {
      // skip
    }
  }
  return out;
}

// ── Metadata helpers ─────────────────────────────────────────────────

export interface ChannelStat {
  channel: Channel;
  messageCount: number;
  lastMessageAt?: string;
  lastMessage?: ChannelMessage;
}

export function statChannel(
  name: string,
  baseDir: string = defaultBaseDir()
): ChannelStat | undefined {
  const ch = getChannel(name, baseDir);
  if (!ch) return undefined;
  const msgs = readMessages(ch.name, baseDir);
  const last = msgs[msgs.length - 1];
  return {
    channel: ch,
    messageCount: msgs.length,
    lastMessageAt: last?.ts,
    lastMessage: last,
  };
}
