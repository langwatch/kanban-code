import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import { create } from "zustand";
import type {
  Channel,
  ChannelDrafts,
  ChannelMessage,
  ChannelParticipant,
  ChannelReadState,
} from "../types";
import { useBoardStore } from "./boardStore";

/// The local identity the Tauri app sends as — matches macOS where the GUI
/// always posts as the human user. Card-scoped sends come through the
/// `kanban` CLI from a tmux session, never from the GUI.
export const SELF: ChannelParticipant = { cardId: null, handle: "user" };

/// `party_key` (matches Rust ChannelParticipant::party_key + Swift partyKey):
/// `@<handle>` for users, the card_id for cards.
export function partyKey(p: ChannelParticipant): string {
  return p.cardId ?? `@${p.handle}`;
}

export function parsePartyKey(key: string): ChannelParticipant {
  if (key.startsWith("@")) return { cardId: null, handle: key.slice(1) };
  return { cardId: key, handle: key };
}

/// `<sortedA>__<sortedB>` — same encoding the Rust backend writes.
export function dmPairKey(a: ChannelParticipant, b: ChannelParticipant): string {
  const keys = [partyKey(a), partyKey(b)].sort();
  return `${keys[0]}__${keys[1]}`;
}

/// Given a stored pair key, return the "other" half (i.e. not SELF).
export function otherPartyOfPair(
  pairKey: string,
  self: ChannelParticipant = SELF
): ChannelParticipant {
  const [a, b] = pairKey.split("__");
  const selfKey = partyKey(self);
  const other = a === selfKey ? b : a;
  return parsePartyKey(other);
}

export function partyDisplayName(p: ChannelParticipant): string {
  if (p.cardId) return p.cardId;
  return `@${p.handle}`;
}

// ── Notification dispatch ───────────────────────────────────────────────────
//
// State below is module-scoped (not zustand) because it's pure bookkeeping:
// `lastSeenIdByThread` lets us identify *which* tail messages are new since
// the last event, and `lastNotifyAtByThread` enforces the per-thread debounce
// the issue calls for (5 messages within 2s = 1 notification).

const NOTIFY_DEBOUNCE_MS = 2000;
const lastSeenIdByThread = new Map<string, string>();
const lastNotifyAtByThread = new Map<string, number>();

function isSelf(p: ChannelParticipant): boolean {
  return p.cardId === SELF.cardId && p.handle === SELF.handle;
}

function selfIsMember(channel: Channel): boolean {
  return channel.members.some((m) => m.cardId === null && m.handle === SELF.handle);
}

/// Returns the messages in `msgs` that are newer than the last one we observed
/// for `threadKey`. Also updates the lastSeenId bookmark. On the very first
/// event for a thread, only the single newest message is treated as new — that
/// way historical messages already on disk at app start don't trigger a flood.
function takeNewMessages(threadKey: string, msgs: ChannelMessage[]): ChannelMessage[] {
  if (msgs.length === 0) return [];
  const prev = lastSeenIdByThread.get(threadKey);
  const latestId = msgs[msgs.length - 1].id;
  let fresh: ChannelMessage[];
  if (prev === undefined) {
    fresh = [msgs[msgs.length - 1]];
  } else {
    const idx = msgs.findIndex((m) => m.id === prev);
    fresh = idx < 0 ? msgs.slice() : msgs.slice(idx + 1);
  }
  lastSeenIdByThread.set(threadKey, latestId);
  return fresh;
}

async function dispatchChatNotification(
  threadKey: string,
  title: string,
  body: string
): Promise<void> {
  const now = performance.now();
  const last = lastNotifyAtByThread.get(threadKey);
  if (last !== undefined && now - last < NOTIFY_DEBOUNCE_MS) return;
  lastNotifyAtByThread.set(threadKey, now);
  try {
    await invoke("notify_chat_message", {
      title,
      body,
      threadId: threadKey,
    });
  } catch {
    // best-effort
  }
}

function chatPanelOpen(): boolean {
  try {
    return useBoardStore.getState().chatOpen;
  } catch {
    return false;
  }
}

function snippet(body: string, max = 120): string {
  const oneLine = body.replace(/\s+/g, " ").trim();
  return oneLine.length > max ? oneLine.slice(0, max - 1) + "…" : oneLine;
}

async function maybeNotifyChannel(
  name: string,
  get: () => ReturnType<typeof useChannelsStore.getState>
): Promise<void> {
  const channel = get().channels.find((c) => c.name === name);
  if (!channel) return;
  if (!selfIsMember(channel)) return;
  let msgs: ChannelMessage[];
  try {
    msgs = await invoke<ChannelMessage[]>("read_channel_messages", {
      channel: name,
      limit: 20,
    });
  } catch {
    return;
  }
  const threadKey = `ch:${name}`;
  const fresh = takeNewMessages(threadKey, msgs);
  if (fresh.length === 0) return;
  const panelOpen = chatPanelOpen();
  const focused = panelOpen && get().selectedChannel === name;
  if (focused) return;
  const candidate = fresh
    .filter((m) => (m.type ?? "message") === "message")
    .filter((m) => !isSelf(m.from))
    .pop();
  if (!candidate) return;
  await dispatchChatNotification(
    threadKey,
    `#${name} — @${candidate.from.handle}`,
    snippet(candidate.body)
  );
}

async function maybeNotifyDm(
  pairKey: string,
  get: () => ReturnType<typeof useChannelsStore.getState>
): Promise<void> {
  // SELF must be one of the two parties; pair keys that don't contain SELF
  // belong to other parties (e.g. card-to-card) and aren't ours to notify on.
  const halves = pairKey.split("__");
  const selfKey = partyKey(SELF);
  if (!halves.includes(selfKey)) return;
  const other = otherPartyOfPair(pairKey, SELF);
  let msgs: ChannelMessage[];
  try {
    msgs = await invoke<ChannelMessage[]>("read_dm_messages", {
      a: SELF,
      b: other,
      limit: 20,
    });
  } catch {
    return;
  }
  const threadKey = `dm:${pairKey}`;
  const fresh = takeNewMessages(threadKey, msgs);
  if (fresh.length === 0) return;
  const panelOpen = chatPanelOpen();
  const focused = panelOpen && get().selectedDm === pairKey;
  if (focused) return;
  const candidate = fresh
    .filter((m) => (m.type ?? "message") === "message")
    .filter((m) => !isSelf(m.from))
    .pop();
  if (!candidate) return;
  await dispatchChatNotification(
    threadKey,
    `DM from ${partyDisplayName(candidate.from)}`,
    snippet(candidate.body)
  );
}

interface ChannelsStore {
  channels: Channel[];
  selectedChannel: string | null;
  selectedDm: string | null;
  /// channel name → messages (most recent at the bottom)
  messagesByChannel: Record<string, ChannelMessage[]>;
  /// dm pair key → messages
  messagesByDm: Record<string, ChannelMessage[]>;
  /// All known DM pair keys (from `list_dm_pairs` + any ad-hoc created).
  dmPairs: string[];
  readState: ChannelReadState;
  drafts: ChannelDrafts;
  error: string | null;
  isLoadingChannels: boolean;
  /// Subscribed listeners — kept on the store so init/teardown is idempotent.
  unlisten: UnlistenFn[];

  init: () => Promise<void>;
  teardown: () => void;

  refreshChannels: () => Promise<void>;
  refreshDmPairs: () => Promise<void>;
  selectChannel: (name: string | null) => Promise<void>;
  selectDm: (pairKey: string | null) => Promise<void>;
  loadMessages: (name: string) => Promise<void>;
  loadDmMessages: (pairKey: string) => Promise<void>;
  sendMessage: (name: string, body: string, imagePaths?: string[]) => Promise<void>;
  sendDm: (pairKey: string, body: string, imagePaths?: string[]) => Promise<void>;
  editMessage: (name: string, targetId: string, newBody: string) => Promise<void>;
  deleteMessage: (name: string, targetId: string) => Promise<void>;
  reactMessage: (name: string, targetId: string, emoji: string) => Promise<void>;
  editDm: (pairKey: string, targetId: string, newBody: string) => Promise<void>;
  deleteDm: (pairKey: string, targetId: string) => Promise<void>;
  reactDm: (pairKey: string, targetId: string, emoji: string) => Promise<void>;
  createChannel: (name: string) => Promise<Channel | null>;
  deleteChannel: (name: string) => Promise<void>;
  openDmTo: (target: string) => Promise<string | null>;
  saveDraft: (name: string, body: string) => Promise<void>;
  saveDmDraft: (pairKey: string, body: string) => Promise<void>;
  markRead: (name: string) => Promise<void>;
  markDmRead: (pairKey: string) => Promise<void>;
  clearError: () => void;

  unreadCount: (name: string) => number;
  unreadDmCount: (pairKey: string) => number;
}

export const useChannelsStore = create<ChannelsStore>((set, get) => ({
  channels: [],
  selectedChannel: null,
  selectedDm: null,
  messagesByChannel: {},
  messagesByDm: {},
  dmPairs: [],
  readState: { channels: {}, dms: {} },
  drafts: { channels: {}, dms: {} },
  error: null,
  isLoadingChannels: false,
  unlisten: [],

  init: async () => {
    if (get().unlisten.length > 0) return; // already initialized
    await get().refreshChannels();
    await get().refreshDmPairs();
    try {
      const [rs, drafts] = await Promise.all([
        invoke<ChannelReadState>("get_read_state"),
        invoke<ChannelDrafts>("get_drafts"),
      ]);
      set({ readState: rs, drafts });
    } catch (e) {
      set({ error: String(e) });
    }
    const unsubChannels = await listen("channels-changed", () => {
      get().refreshChannels();
    });
    const unsubMessages = await listen<{ channelName: string }>(
      "channel-messages-changed",
      async (event) => {
        const name = event.payload?.channelName;
        if (!name) return;
        const loaded = get().messagesByChannel[name] !== undefined;
        const isSelected = name === get().selectedChannel;
        if (loaded || isSelected) {
          await get().loadMessages(name);
        }
        await maybeNotifyChannel(name, get);
      }
    );
    const unsubReadState = await listen("read-state-changed", async () => {
      try {
        const rs = await invoke<ChannelReadState>("get_read_state");
        set({ readState: rs });
      } catch {
        // best-effort
      }
    });
    const unsubDrafts = await listen("drafts-changed", async () => {
      try {
        const drafts = await invoke<ChannelDrafts>("get_drafts");
        set({ drafts });
      } catch {
        // best-effort
      }
    });
    const unsubDmLogs = await listen<{ dmKey: string }>(
      "dm-logs-changed",
      async (event) => {
        const key = event.payload?.dmKey;
        if (!key) return;
        window.dispatchEvent(
          new CustomEvent("kanban:dm-logs-changed", { detail: { dmKey: key } })
        );
        if (!get().dmPairs.includes(key)) {
          await get().refreshDmPairs();
        }
        const loaded = get().messagesByDm[key] !== undefined;
        const isSelected = key === get().selectedDm;
        if (loaded || isSelected) {
          await get().loadDmMessages(key);
        }
        await maybeNotifyDm(key, get);
      }
    );
    set({
      unlisten: [
        unsubChannels,
        unsubMessages,
        unsubReadState,
        unsubDrafts,
        unsubDmLogs,
      ],
    });
  },

  teardown: () => {
    for (const u of get().unlisten) u();
    set({ unlisten: [] });
  },

  refreshChannels: async () => {
    set({ isLoadingChannels: true });
    try {
      const channels = await invoke<Channel[]>("list_channels");
      // Stable ordering: sortOrder ascending, then createdAt ascending.
      channels.sort((a, b) => {
        const so = (a.sortOrder ?? Number.MAX_SAFE_INTEGER) - (b.sortOrder ?? Number.MAX_SAFE_INTEGER);
        if (so !== 0) return so;
        return a.createdAt.localeCompare(b.createdAt);
      });
      set({ channels, isLoadingChannels: false });
    } catch (e) {
      set({ error: String(e), isLoadingChannels: false });
    }
  },

  refreshDmPairs: async () => {
    try {
      const pairs = await invoke<string[]>("list_dm_pairs");
      // Merge with any locally-created pairs the backend doesn't know about
      // yet (a brand-new "Start DM" thread won't have a log file until the
      // first message is sent, so it would drop out of the sidebar mid-compose).
      const merged = Array.from(new Set([...pairs, ...get().dmPairs])).sort();
      set({ dmPairs: merged });
    } catch (e) {
      set({ error: String(e) });
    }
  },

  selectChannel: async (name) => {
    set({ selectedChannel: name, selectedDm: null });
    if (name) {
      await get().loadMessages(name);
      await get().markRead(name);
    }
  },

  selectDm: async (pairKey) => {
    set({ selectedDm: pairKey, selectedChannel: null });
    if (pairKey) {
      await get().loadDmMessages(pairKey);
      await get().markDmRead(pairKey);
    }
  },

  loadMessages: async (name) => {
    try {
      const msgs = await invoke<ChannelMessage[]>("read_channel_messages", {
        channel: name,
        limit: 500,
      });
      set((state) => ({
        messagesByChannel: { ...state.messagesByChannel, [name]: msgs },
      }));
      if (get().selectedChannel === name) {
        get().markRead(name);
      }
    } catch (e) {
      set({ error: String(e) });
    }
  },

  loadDmMessages: async (pairKey) => {
    try {
      const other = otherPartyOfPair(pairKey, SELF);
      const msgs = await invoke<ChannelMessage[]>("read_dm_messages", {
        a: SELF,
        b: other,
        limit: 500,
      });
      set((state) => ({
        messagesByDm: { ...state.messagesByDm, [pairKey]: msgs },
      }));
      if (get().selectedDm === pairKey) {
        get().markDmRead(pairKey);
      }
    } catch (e) {
      set({ error: String(e) });
    }
  },

  sendMessage: async (name, body, imagePaths) => {
    const trimmed = body.trim();
    const images = imagePaths?.filter((p) => p.length > 0) ?? [];
    if (!trimmed && images.length === 0) return;
    try {
      const optimistic: ChannelMessage = {
        id: `local_${crypto.randomUUID().slice(0, 12)}`,
        ts: new Date().toISOString(),
        from: SELF,
        body: trimmed,
        type: "message",
        imagePaths: images.length > 0 ? images : undefined,
      };
      set((state) => ({
        messagesByChannel: {
          ...state.messagesByChannel,
          [name]: [...(state.messagesByChannel[name] ?? []), optimistic],
        },
      }));
      await invoke<ChannelMessage>("send_channel_message", {
        channel: name,
        from: SELF,
        body: trimmed,
        imagePaths: images.length > 0 ? images : null,
      });
      const newDrafts = {
        ...get().drafts,
        channels: { ...get().drafts.channels, [name]: "" },
      };
      set({ drafts: newDrafts });
      await invoke("save_drafts", { drafts: newDrafts });
    } catch (e) {
      set({ error: String(e) });
      get().loadMessages(name);
    }
  },

  sendDm: async (pairKey, body, imagePaths) => {
    const trimmed = body.trim();
    const images = imagePaths?.filter((p) => p.length > 0) ?? [];
    if (!trimmed && images.length === 0) return;
    try {
      const other = otherPartyOfPair(pairKey, SELF);
      const optimistic: ChannelMessage = {
        id: `local_${crypto.randomUUID().slice(0, 12)}`,
        ts: new Date().toISOString(),
        from: SELF,
        body: trimmed,
        type: "message",
        imagePaths: images.length > 0 ? images : undefined,
      };
      set((state) => ({
        messagesByDm: {
          ...state.messagesByDm,
          [pairKey]: [...(state.messagesByDm[pairKey] ?? []), optimistic],
        },
      }));
      await invoke<ChannelMessage>("send_dm", {
        from: SELF,
        to: other,
        body: trimmed,
        imagePaths: images.length > 0 ? images : null,
      });
      const newDrafts: ChannelDrafts = {
        ...get().drafts,
        dms: { ...get().drafts.dms, [pairKey]: "" },
      };
      set({ drafts: newDrafts });
      await invoke("save_drafts", { drafts: newDrafts });
      if (!get().dmPairs.includes(pairKey)) {
        set((state) => ({ dmPairs: [...state.dmPairs, pairKey].sort() }));
      }
    } catch (e) {
      set({ error: String(e) });
      get().loadDmMessages(pairKey);
    }
  },

  editMessage: async (name, targetId, newBody) => {
    const trimmed = newBody.trim();
    if (!trimmed) return;
    try {
      await invoke<ChannelMessage>("edit_channel_message", {
        channel: name,
        targetId,
        from: SELF,
        newBody: trimmed,
      });
      // Watcher will trigger refetch — no optimistic update for edits since
      // the collapse pipeline owns the body.
    } catch (e) {
      set({ error: String(e) });
    }
  },

  deleteMessage: async (name, targetId) => {
    try {
      await invoke<ChannelMessage>("delete_channel_message", {
        channel: name,
        targetId,
        from: SELF,
      });
    } catch (e) {
      set({ error: String(e) });
    }
  },

  reactMessage: async (name, targetId, emoji) => {
    try {
      await invoke<ChannelMessage>("react_channel_message", {
        channel: name,
        targetId,
        from: SELF,
        emoji,
      });
    } catch (e) {
      set({ error: String(e) });
    }
  },

  createChannel: async (rawName) => {
    // Mirror Rust's normalize_channel_name: trim → strip leading '#' → trim
    // again → lowercase. The second trim catches "# foo" → "foo" rather than
    // " foo", which would otherwise fail server-side validation.
    const name = rawName.trim().replace(/^#/, "").trim().toLowerCase();
    if (!name) return null;
    try {
      const channel = await invoke<Channel>("create_channel", {
        name,
        by: SELF,
      });
      await invoke("join_channel", { name: channel.name, member: SELF });
      await get().refreshChannels();
      await get().selectChannel(channel.name);
      return channel;
    } catch (e) {
      set({ error: String(e) });
      return null;
    }
  },

  deleteChannel: async (name) => {
    try {
      await invoke<boolean>("delete_channel", { name });
      set((state) => {
        const { [name]: _, ...rest } = state.messagesByChannel;
        return {
          messagesByChannel: rest,
          selectedChannel: state.selectedChannel === name ? null : state.selectedChannel,
        };
      });
      await get().refreshChannels();
    } catch (e) {
      set({ error: String(e) });
    }
  },

  openDmTo: async (target) => {
    // Accept "@handle", "handle", or "card_<ksuid>"
    const trimmed = target.trim();
    if (!trimmed) return null;
    let other: ChannelParticipant;
    if (trimmed.startsWith("card_")) {
      other = { cardId: trimmed, handle: trimmed };
    } else if (trimmed.startsWith("@")) {
      other = { cardId: null, handle: trimmed.slice(1) };
    } else {
      other = { cardId: null, handle: trimmed };
    }
    if (!other.cardId && !other.handle) return null;
    if (other.cardId === null && other.handle === SELF.handle) {
      set({ error: "Can't DM yourself." });
      return null;
    }
    const key = dmPairKey(SELF, other);
    if (!get().dmPairs.includes(key)) {
      set((state) => ({ dmPairs: [...state.dmPairs, key].sort() }));
    }
    await get().selectDm(key);
    return key;
  },

  saveDraft: async (name, body) => {
    const newDrafts: ChannelDrafts = {
      ...get().drafts,
      channels: { ...get().drafts.channels, [name]: body },
    };
    set({ drafts: newDrafts });
    try {
      await invoke("save_drafts", { drafts: newDrafts });
    } catch {
      // Drafts are best-effort; failing to persist shouldn't block typing.
    }
  },

  saveDmDraft: async (pairKey, body) => {
    const newDrafts: ChannelDrafts = {
      ...get().drafts,
      dms: { ...get().drafts.dms, [pairKey]: body },
    };
    set({ drafts: newDrafts });
    try {
      await invoke("save_drafts", { drafts: newDrafts });
    } catch {
      // best-effort
    }
  },

  markRead: async (name) => {
    // Read-state pins to the latest "real" message id (not edit/delete/
    // reaction rows) so unreadCount doesn't get inflated by side-channel
    // activity on already-read messages.
    const visible = (get().messagesByChannel[name] ?? []).filter(isVisibleRow);
    if (visible.length === 0) return;
    const lastId = visible[visible.length - 1].id;
    if (get().readState.channels[name] === lastId) return;
    const newReadState: ChannelReadState = {
      ...get().readState,
      channels: { ...get().readState.channels, [name]: lastId },
    };
    set({ readState: newReadState });
    try {
      await invoke("save_read_state", { stateData: newReadState });
    } catch {
      // best-effort
    }
  },

  markDmRead: async (pairKey) => {
    const msgs = (get().messagesByDm[pairKey] ?? []).filter(isVisibleRow);
    if (msgs.length === 0) return;
    const lastId = msgs[msgs.length - 1].id;
    if (get().readState.dms[pairKey] === lastId) return;
    const newReadState: ChannelReadState = {
      ...get().readState,
      dms: { ...get().readState.dms, [pairKey]: lastId },
    };
    set({ readState: newReadState });
    try {
      await invoke("save_read_state", { stateData: newReadState });
    } catch {
      // best-effort
    }
  },

  clearError: () => set({ error: null }),

  unreadCount: (name) => {
    const visible = (get().messagesByChannel[name] ?? []).filter(isVisibleRow);
    if (visible.length === 0) return 0;
    const lastReadId = get().readState.channels[name];
    if (!lastReadId) return visible.length;
    const idx = visible.findIndex((m) => m.id === lastReadId);
    if (idx < 0) return visible.length;
    return visible.length - 1 - idx;
  },

  unreadDmCount: (pairKey) => {
    const msgs = (get().messagesByDm[pairKey] ?? []).filter(isVisibleRow);
    if (msgs.length === 0) return 0;
    const lastReadId = get().readState.dms[pairKey];
    if (!lastReadId) return msgs.length;
    const idx = msgs.findIndex((m) => m.id === lastReadId);
    if (idx < 0) return msgs.length;
    return msgs.length - 1 - idx;
  },

  editDm: async (pairKey, targetId, newBody) => {
    const trimmed = newBody.trim();
    if (!trimmed) return;
    try {
      const other = otherPartyOfPair(pairKey, SELF);
      await invoke<ChannelMessage>("edit_dm_message", {
        a: SELF,
        b: other,
        targetId,
        from: SELF,
        newBody: trimmed,
      });
    } catch (e) {
      set({ error: String(e) });
    }
  },

  deleteDm: async (pairKey, targetId) => {
    try {
      const other = otherPartyOfPair(pairKey, SELF);
      await invoke<ChannelMessage>("delete_dm_message", {
        a: SELF,
        b: other,
        targetId,
        from: SELF,
      });
    } catch (e) {
      set({ error: String(e) });
    }
  },

  reactDm: async (pairKey, targetId, emoji) => {
    try {
      const other = otherPartyOfPair(pairKey, SELF);
      await invoke<ChannelMessage>("react_dm_message", {
        a: SELF,
        b: other,
        targetId,
        from: SELF,
        emoji,
      });
    } catch (e) {
      set({ error: String(e) });
    }
  },
}));

function isVisibleRow(m: ChannelMessage): boolean {
  const k = m.type ?? "message";
  return k === "message" || k === "join" || k === "leave" || k === "system";
}
