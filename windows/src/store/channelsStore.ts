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

/// The local identity the Tauri app sends as — matches macOS where the GUI
/// always posts as the human user. Card-scoped sends come through the
/// `kanban` CLI from a tmux session, never from the GUI.
export const SELF: ChannelParticipant = { cardId: null, handle: "user" };

interface ChannelsStore {
  channels: Channel[];
  selectedChannel: string | null;
  /// channel name → messages (most recent at the bottom)
  messagesByChannel: Record<string, ChannelMessage[]>;
  readState: ChannelReadState;
  drafts: ChannelDrafts;
  error: string | null;
  isLoadingChannels: boolean;
  /// Subscribed listeners — kept on the store so init/teardown is idempotent.
  unlisten: UnlistenFn[];

  init: () => Promise<void>;
  teardown: () => void;

  refreshChannels: () => Promise<void>;
  selectChannel: (name: string | null) => Promise<void>;
  loadMessages: (name: string) => Promise<void>;
  sendMessage: (name: string, body: string, imagePaths?: string[]) => Promise<void>;
  createChannel: (name: string) => Promise<Channel | null>;
  deleteChannel: (name: string) => Promise<void>;
  saveDraft: (name: string, body: string) => Promise<void>;
  markRead: (name: string) => Promise<void>;
  clearError: () => void;

  unreadCount: (name: string) => number;
}

export const useChannelsStore = create<ChannelsStore>((set, get) => ({
  channels: [],
  selectedChannel: null,
  messagesByChannel: {},
  readState: { channels: {}, dms: {} },
  drafts: { channels: {}, dms: {} },
  error: null,
  isLoadingChannels: false,
  unlisten: [],

  init: async () => {
    if (get().unlisten.length > 0) return; // already initialized
    await get().refreshChannels();
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
      (event) => {
        const name = event.payload?.channelName;
        if (!name) return;
        // Only refetch if this channel is currently loaded — avoids burning
        // I/O for channels the user hasn't opened yet.
        const loaded = get().messagesByChannel[name] !== undefined;
        if (loaded || name === get().selectedChannel) {
          get().loadMessages(name);
        }
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
    // DM logs — the watcher emits this when a per-pair JSONL changes. The
    // store doesn't currently track in-memory DM messages (the DM view loads
    // them on demand via read_dm_messages), so this listener just bumps a
    // global event the DM view subscribes to. For now we forward the raw event
    // so consumers can subscribe to channelsStore subscribers; refetching is
    // the consumer's job. Wiring this in completes the 4-event watcher
    // contract — otherwise live DM updates were silently dropped.
    const unsubDmLogs = await listen<{ dmKey: string }>(
      "dm-logs-changed",
      (event) => {
        const key = event.payload?.dmKey;
        if (!key) return;
        // Re-emit on the window so DM view components can listen without
        // needing to import the Tauri event API directly.
        window.dispatchEvent(
          new CustomEvent("kanban:dm-logs-changed", { detail: { dmKey: key } })
        );
      }
    );
    set({ unlisten: [unsubChannels, unsubMessages, unsubReadState, unsubDmLogs] });
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

  selectChannel: async (name) => {
    set({ selectedChannel: name });
    if (name) {
      await get().loadMessages(name);
      await get().markRead(name);
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
      // Auto-mark-read on refresh of the currently-open channel.
      if (get().selectedChannel === name) {
        get().markRead(name);
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
      // Optimistic: append locally; the watcher will trigger a refetch shortly
      // and replace the optimistic entry with the canonical row.
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
      // Clear the draft on successful send.
      const newDrafts = {
        ...get().drafts,
        channels: { ...get().drafts.channels, [name]: "" },
      };
      set({ drafts: newDrafts });
      await invoke("save_drafts", { drafts: newDrafts });
    } catch (e) {
      set({ error: String(e) });
      // Roll back the optimistic entry by refetching.
      get().loadMessages(name);
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
      // Auto-join the creator so messages we send aren't from a non-member.
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

  markRead: async (name) => {
    const msgs = get().messagesByChannel[name] ?? [];
    if (msgs.length === 0) return;
    const lastId = msgs[msgs.length - 1].id;
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

  clearError: () => set({ error: null }),

  unreadCount: (name) => {
    const msgs = get().messagesByChannel[name] ?? [];
    if (msgs.length === 0) return 0;
    const lastReadId = get().readState.channels[name];
    if (!lastReadId) return msgs.length;
    const idx = msgs.findIndex((m) => m.id === lastReadId);
    if (idx < 0) return msgs.length;
    return msgs.length - 1 - idx;
  },
}));
