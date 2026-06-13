import { useEffect, useMemo, useRef, useState } from "react";
import {
  otherPartyOfPair,
  partyDisplayName,
  useChannelsStore,
} from "../store/channelsStore";
import { useBoardStore } from "../store/boardStore";
import { useTheme, t } from "../theme";
import type { Channel, ChannelMessage } from "../types";

/// Phase-7 channel chat panel. Replaces the BoardView when `chatOpen` is true
/// (mirrors the SettingsView slot). Wire format matches the macOS app and the
/// TS CLI; live updates come from the Tauri watcher events.
export default function Channels() {
  const {
    channels,
    selectedChannel,
    selectedDm,
    messagesByChannel,
    messagesByDm,
    dmPairs,
    drafts,
    error,
    init,
    selectChannel,
    selectDm,
    sendMessage,
    sendDm,
    createChannel,
    openDmTo,
    saveDraft,
    saveDmDraft,
    unreadCount,
    unreadDmCount,
    clearError,
  } = useChannelsStore();
  const { setChatOpen } = useBoardStore();
  const { theme } = useTheme();
  const c = t(theme);

  const [newChannelOpen, setNewChannelOpen] = useState(false);
  const [newDmOpen, setNewDmOpen] = useState(false);

  useEffect(() => {
    init();
    // Intentionally do NOT teardown on unmount — keeping subscriptions live
    // lets the unread counts update even when the chat panel is closed.
  }, []);

  // Auto-select the first channel on first render if nothing is selected.
  useEffect(() => {
    if (!selectedChannel && !selectedDm && channels.length > 0) {
      selectChannel(channels[0].name);
    }
  }, [channels, selectedChannel, selectedDm, selectChannel]);

  const selected = useMemo(
    () => channels.find((ch) => ch.name === selectedChannel) ?? null,
    [channels, selectedChannel]
  );
  const channelMessages = selectedChannel
    ? messagesByChannel[selectedChannel] ?? []
    : [];
  const channelDraft = selectedChannel
    ? drafts.channels[selectedChannel] ?? ""
    : "";

  const dmMessages = selectedDm ? messagesByDm[selectedDm] ?? [] : [];
  const dmDraft = selectedDm ? drafts.dms[selectedDm] ?? "" : "";

  return (
    <div className="flex-1 flex overflow-hidden">
      {/* Sidebar */}
      <aside
        className="w-[240px] shrink-0 flex flex-col"
        style={{ background: c.bgColumn, borderRight: `1px solid ${c.border}` }}
      >
        <div
          className="flex items-center justify-between px-4 h-12 shrink-0"
          style={{ borderBottom: `1px solid ${c.border}` }}
        >
          <div className="flex items-center gap-2">
            <button
              onClick={() => setChatOpen(false)}
              className="transition-colors"
              style={{ color: c.textMuted }}
              onMouseEnter={(e) => (e.currentTarget.style.color = c.textPrimary)}
              onMouseLeave={(e) => (e.currentTarget.style.color = c.textMuted)}
              title="Back to board"
            >
              <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M15.75 19.5 8.25 12l7.5-7.5" />
              </svg>
            </button>
            <span className="text-[13px] font-semibold" style={{ color: c.textPrimary }}>
              Chat
            </span>
          </div>
        </div>

        <div className="flex-1 overflow-y-auto py-2">
          <SidebarHeader
            label="Channels"
            onAdd={() => setNewChannelOpen(true)}
            addTitle="Create channel"
            c={c}
          />
          {channels.length === 0 ? (
            <div className="px-4 py-3 text-[12px]" style={{ color: c.textMuted }}>
              No channels yet.
            </div>
          ) : (
            channels.map((ch) => (
              <ChannelRow
                key={ch.id}
                channel={ch}
                selected={selectedChannel === ch.name}
                unread={unreadCount(ch.name)}
                onClick={() => selectChannel(ch.name)}
                c={c}
              />
            ))
          )}

          <SidebarHeader
            label="Direct Messages"
            onAdd={() => setNewDmOpen(true)}
            addTitle="Start a DM"
            c={c}
          />
          {dmPairs.length === 0 ? (
            <div className="px-4 py-3 text-[12px]" style={{ color: c.textMuted }}>
              No direct messages yet.
            </div>
          ) : (
            dmPairs.map((key) => (
              <DmRow
                key={key}
                pairKey={key}
                selected={selectedDm === key}
                unread={unreadDmCount(key)}
                onClick={() => selectDm(key)}
                c={c}
              />
            ))
          )}
        </div>
      </aside>

      {/* Main pane */}
      <main className="flex-1 flex flex-col overflow-hidden" style={{ background: c.bg }}>
        {selected ? (
          <ChannelPane
            channel={selected}
            messages={channelMessages}
            draft={channelDraft}
            onSend={(body) => sendMessage(selected.name, body)}
            onDraftChange={(body) => saveDraft(selected.name, body)}
            c={c}
            theme={theme}
          />
        ) : selectedDm ? (
          <DmPane
            pairKey={selectedDm}
            messages={dmMessages}
            draft={dmDraft}
            onSend={(body) => sendDm(selectedDm, body)}
            onDraftChange={(body) => saveDmDraft(selectedDm, body)}
            c={c}
            theme={theme}
          />
        ) : (
          <div className="flex-1 flex items-center justify-center text-[13px]" style={{ color: c.textMuted }}>
            Select a channel or DM to start chatting.
          </div>
        )}
      </main>

      {newChannelOpen && (
        <NewChannelDialog
          onCancel={() => setNewChannelOpen(false)}
          onCreate={async (name) => {
            const ch = await createChannel(name);
            if (ch) setNewChannelOpen(false);
          }}
          c={c}
          theme={theme}
        />
      )}

      {newDmOpen && (
        <NewDmDialog
          onCancel={() => setNewDmOpen(false)}
          onOpen={async (target) => {
            const key = await openDmTo(target);
            if (key) setNewDmOpen(false);
          }}
          c={c}
          theme={theme}
        />
      )}

      {error && (
        <div
          className="fixed bottom-5 right-5 max-w-sm px-4 py-3 rounded-xl text-[13px] shadow-xl cursor-pointer"
          style={{
            background: theme === "dark" ? "#2a1215" : "#fef2f2",
            border: `1px solid rgba(248,81,73,0.3)`,
            color: "#f85149",
          }}
          onClick={clearError}
        >
          {error}
        </div>
      )}
    </div>
  );
}

// ── Sidebar section header with an inline "+" affordance ────────────────────

function SidebarHeader({
  label,
  onAdd,
  addTitle,
  c,
}: {
  label: string;
  onAdd: () => void;
  addTitle: string;
  c: ReturnType<typeof t>;
}) {
  return (
    <div className="flex items-center justify-between px-4 pt-3 pb-1">
      <span
        className="text-[10px] uppercase tracking-wider font-semibold"
        style={{ color: c.textMuted }}
      >
        {label}
      </span>
      <button
        onClick={onAdd}
        className="p-0.5 rounded transition-colors"
        style={{ color: c.textMuted }}
        onMouseEnter={(e) => {
          e.currentTarget.style.background = c.hoverBg;
          e.currentTarget.style.color = c.textPrimary;
        }}
        onMouseLeave={(e) => {
          e.currentTarget.style.background = "";
          e.currentTarget.style.color = c.textMuted;
        }}
        title={addTitle}
      >
        <svg className="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
          <path strokeLinecap="round" strokeLinejoin="round" d="M12 4v16m8-8H4" />
        </svg>
      </button>
    </div>
  );
}

// ── Sidebar rows ─────────────────────────────────────────────────────────────

function ChannelRow({
  channel,
  selected,
  unread,
  onClick,
  c,
}: {
  channel: Channel;
  selected: boolean;
  unread: number;
  onClick: () => void;
  c: ReturnType<typeof t>;
}) {
  return (
    <button
      onClick={onClick}
      className="w-full flex items-center justify-between px-4 py-1.5 text-[13px] transition-colors text-left"
      style={{
        background: selected ? c.bgCardSelected : "transparent",
        color: selected ? c.textPrimary : unread > 0 ? c.textPrimary : c.textSecondary,
        fontWeight: unread > 0 ? 600 : 400,
      }}
      onMouseEnter={(e) => {
        if (!selected) e.currentTarget.style.background = c.hoverBg;
      }}
      onMouseLeave={(e) => {
        if (!selected) e.currentTarget.style.background = "transparent";
      }}
    >
      <span className="truncate"># {channel.name}</span>
      {unread > 0 && <UnreadBadge count={unread} />}
    </button>
  );
}

function DmRow({
  pairKey,
  selected,
  unread,
  onClick,
  c,
}: {
  pairKey: string;
  selected: boolean;
  unread: number;
  onClick: () => void;
  c: ReturnType<typeof t>;
}) {
  const other = useMemo(() => otherPartyOfPair(pairKey), [pairKey]);
  const label = partyDisplayName(other);
  return (
    <button
      onClick={onClick}
      className="w-full flex items-center justify-between px-4 py-1.5 text-[13px] transition-colors text-left"
      style={{
        background: selected ? c.bgCardSelected : "transparent",
        color: selected ? c.textPrimary : unread > 0 ? c.textPrimary : c.textSecondary,
        fontWeight: unread > 0 ? 600 : 400,
      }}
      onMouseEnter={(e) => {
        if (!selected) e.currentTarget.style.background = c.hoverBg;
      }}
      onMouseLeave={(e) => {
        if (!selected) e.currentTarget.style.background = "transparent";
      }}
    >
      <span className="truncate flex items-center gap-1.5">
        <span
          className="inline-block w-1.5 h-1.5 rounded-full"
          style={{ background: other.cardId ? "#a78bfa" : "#4f8ef7" }}
        />
        {label}
      </span>
      {unread > 0 && <UnreadBadge count={unread} />}
    </button>
  );
}

function UnreadBadge({ count }: { count: number }) {
  return (
    <span
      className="ml-2 shrink-0 inline-flex items-center justify-center text-[10px] font-semibold rounded-full px-1.5"
      style={{
        background: "#4f8ef7",
        color: "white",
        minWidth: 18,
        height: 18,
      }}
    >
      {count > 99 ? "99+" : count}
    </span>
  );
}

// ── Channel pane (header + message list + input) ─────────────────────────────

function ChannelPane({
  channel,
  messages,
  draft,
  onSend,
  onDraftChange,
  c,
  theme,
}: {
  channel: Channel;
  messages: ChannelMessage[];
  draft: string;
  onSend: (body: string) => void;
  onDraftChange: (body: string) => void;
  c: ReturnType<typeof t>;
  theme: "dark" | "light";
}) {
  return (
    <ThreadPane
      title={`#${channel.name}`}
      subtitle={`${channel.members.length} member${channel.members.length === 1 ? "" : "s"}`}
      placeholder={`Message #${channel.name}`}
      messages={messages}
      draft={draft}
      onSend={onSend}
      onDraftChange={onDraftChange}
      c={c}
      theme={theme}
    />
  );
}

function DmPane({
  pairKey,
  messages,
  draft,
  onSend,
  onDraftChange,
  c,
  theme,
}: {
  pairKey: string;
  messages: ChannelMessage[];
  draft: string;
  onSend: (body: string) => void;
  onDraftChange: (body: string) => void;
  c: ReturnType<typeof t>;
  theme: "dark" | "light";
}) {
  const other = useMemo(() => otherPartyOfPair(pairKey), [pairKey]);
  const label = partyDisplayName(other);
  return (
    <ThreadPane
      title={label}
      subtitle={other.cardId ? "Card" : "Direct message"}
      placeholder={`Message ${label}`}
      messages={messages}
      draft={draft}
      onSend={onSend}
      onDraftChange={onDraftChange}
      c={c}
      theme={theme}
    />
  );
}

function ThreadPane({
  title,
  subtitle,
  placeholder,
  messages,
  draft,
  onSend,
  onDraftChange,
  c,
  theme,
}: {
  title: string;
  subtitle: string;
  placeholder: string;
  messages: ChannelMessage[];
  draft: string;
  onSend: (body: string) => void;
  onDraftChange: (body: string) => void;
  c: ReturnType<typeof t>;
  theme: "dark" | "light";
}) {
  const listRef = useRef<HTMLDivElement>(null);
  const lastSeenRef = useRef<number>(0);

  // Auto-scroll to bottom when new messages arrive (only if user was at bottom).
  useEffect(() => {
    const el = listRef.current;
    if (!el) return;
    const wasAtBottom =
      lastSeenRef.current === 0 ||
      el.scrollHeight - el.scrollTop - el.clientHeight < 80;
    if (wasAtBottom) {
      el.scrollTop = el.scrollHeight;
    }
    lastSeenRef.current = messages.length;
  }, [messages.length]);

  // Reset auto-scroll tracking when thread changes.
  useEffect(() => {
    lastSeenRef.current = 0;
  }, [title]);

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    if (!draft.trim()) return;
    onSend(draft);
  };

  return (
    <>
      <div
        className="flex items-center justify-between px-6 h-12 shrink-0"
        style={{ borderBottom: `1px solid ${c.border}` }}
      >
        <div className="flex items-center gap-3">
          <span className="text-[15px] font-semibold" style={{ color: c.textPrimary }}>
            {title}
          </span>
          <span className="text-[12px]" style={{ color: c.textMuted }}>
            {subtitle}
          </span>
        </div>
      </div>

      <div ref={listRef} className="flex-1 overflow-y-auto px-6 py-4 space-y-3">
        {messages.length === 0 ? (
          <div className="text-center py-8 text-[13px]" style={{ color: c.textMuted }}>
            No messages yet. Say hi.
          </div>
        ) : (
          messages.map((m) => <MessageRow key={m.id} message={m} c={c} />)
        )}
      </div>

      <form
        onSubmit={handleSubmit}
        className="flex items-end gap-2 px-6 py-3 shrink-0"
        style={{ borderTop: `1px solid ${c.border}` }}
      >
        <textarea
          value={draft}
          onChange={(e) => onDraftChange(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter" && !e.shiftKey) {
              e.preventDefault();
              if (draft.trim()) onSend(draft);
            }
          }}
          placeholder={placeholder}
          rows={1}
          className="flex-1 resize-none rounded-lg px-3 py-2 text-[13px] focus:outline-none"
          style={{
            background: c.bgInput,
            border: `1px solid ${c.border}`,
            color: c.text,
            maxHeight: 160,
          }}
        />
        <button
          type="submit"
          disabled={!draft.trim()}
          className="px-4 py-2 rounded-lg text-[13px] font-semibold transition-colors"
          style={{
            background: draft.trim() ? "#4f8ef7" : c.bgInput,
            color: draft.trim() ? "white" : c.textMuted,
            cursor: draft.trim() ? "pointer" : "not-allowed",
            border: `1px solid ${c.border}`,
          }}
        >
          Send
        </button>
      </form>
      <span style={{ display: "none" }}>{theme}</span>
    </>
  );
}

// ── Single message row ──────────────────────────────────────────────────────

function MessageRow({ message, c }: { message: ChannelMessage; c: ReturnType<typeof t> }) {
  const ts = new Date(message.ts).toLocaleTimeString([], {
    hour: "2-digit",
    minute: "2-digit",
  });
  const isSystem = message.type === "join" || message.type === "leave" || message.type === "system";
  if (isSystem) {
    return (
      <div className="text-center text-[11px]" style={{ color: c.textMuted }}>
        — {message.body} —
      </div>
    );
  }
  return (
    <div className="flex items-baseline gap-2">
      <span className="text-[13px] font-semibold shrink-0" style={{ color: c.textPrimary }}>
        @{message.from.handle}
      </span>
      <span className="text-[10px] shrink-0" style={{ color: c.textMuted }}>
        {ts}
      </span>
      <span className="text-[13px] whitespace-pre-wrap break-words" style={{ color: c.text }}>
        {message.body}
      </span>
    </div>
  );
}

// ── New channel modal ───────────────────────────────────────────────────────

function NewChannelDialog({
  onCancel,
  onCreate,
  c,
  theme,
}: {
  onCancel: () => void;
  onCreate: (name: string) => Promise<void>;
  c: ReturnType<typeof t>;
  theme: "dark" | "light";
}) {
  const [name, setName] = useState("");
  const valid = /^[a-z0-9][a-z0-9_-]{0,63}$/.test(name);

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center"
      style={{ background: c.bgOverlay }}
      onClick={onCancel}
    >
      <div
        className="rounded-xl p-6 w-[440px] max-w-[90vw]"
        style={{
          background: c.bgDialog,
          border: `1px solid ${c.border}`,
          boxShadow: theme === "dark" ? "0 16px 48px rgba(0,0,0,0.6)" : "0 16px 48px rgba(0,0,0,0.18)",
        }}
        onClick={(e) => e.stopPropagation()}
      >
        <h2 className="text-[15px] font-semibold mb-1" style={{ color: c.textPrimary }}>
          Create a channel
        </h2>
        <p className="text-[12px] mb-4" style={{ color: c.textSecondary }}>
          Letters, digits, underscores, dashes. Up to 64 characters.
        </p>
        <input
          autoFocus
          value={name}
          onChange={(e) => setName(e.target.value)}
          placeholder="e.g. eng-updates"
          className="w-full rounded-lg px-3 py-2 text-[13px] focus:outline-none mb-4"
          style={{
            background: c.bgInput,
            border: `1px solid ${c.border}`,
            color: c.text,
          }}
          onKeyDown={(e) => {
            if (e.key === "Enter" && valid) onCreate(name);
            if (e.key === "Escape") onCancel();
          }}
        />
        <div className="flex justify-end gap-2">
          <button
            onClick={onCancel}
            className="px-3 py-1.5 rounded-lg text-[13px] transition-colors"
            style={{ color: c.textSecondary, background: c.bgInput, border: `1px solid ${c.border}` }}
          >
            Cancel
          </button>
          <button
            onClick={() => valid && onCreate(name)}
            disabled={!valid}
            className="px-3 py-1.5 rounded-lg text-[13px] font-semibold transition-colors"
            style={{
              background: valid ? "#4f8ef7" : c.bgInput,
              color: valid ? "white" : c.textMuted,
              cursor: valid ? "pointer" : "not-allowed",
              border: `1px solid ${c.border}`,
            }}
          >
            Create
          </button>
        </div>
      </div>
    </div>
  );
}

// ── New DM modal ────────────────────────────────────────────────────────────

function NewDmDialog({
  onCancel,
  onOpen,
  c,
  theme,
}: {
  onCancel: () => void;
  onOpen: (target: string) => Promise<void>;
  c: ReturnType<typeof t>;
  theme: "dark" | "light";
}) {
  const [target, setTarget] = useState("");
  const trimmed = target.trim();
  // Allow `@handle`, `handle`, or `card_<ksuid>`. Reject the empty string and
  // the literal "user" (DMing yourself).
  const isCard = /^card_[a-zA-Z0-9]+$/.test(trimmed);
  const isHandle = /^@?[a-zA-Z0-9_-]+$/.test(trimmed);
  const isSelf = trimmed === "@user" || trimmed === "user";
  const valid = (isCard || isHandle) && !isSelf;

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center"
      style={{ background: c.bgOverlay }}
      onClick={onCancel}
    >
      <div
        className="rounded-xl p-6 w-[440px] max-w-[90vw]"
        style={{
          background: c.bgDialog,
          border: `1px solid ${c.border}`,
          boxShadow: theme === "dark" ? "0 16px 48px rgba(0,0,0,0.6)" : "0 16px 48px rgba(0,0,0,0.18)",
        }}
        onClick={(e) => e.stopPropagation()}
      >
        <h2 className="text-[15px] font-semibold mb-1" style={{ color: c.textPrimary }}>
          Start a direct message
        </h2>
        <p className="text-[12px] mb-4" style={{ color: c.textSecondary }}>
          Enter <code>@handle</code> for a user, or <code>card_…</code> for a card session.
        </p>
        <input
          autoFocus
          value={target}
          onChange={(e) => setTarget(e.target.value)}
          placeholder="@agent-a or card_2abc…"
          className="w-full rounded-lg px-3 py-2 text-[13px] focus:outline-none mb-4"
          style={{
            background: c.bgInput,
            border: `1px solid ${c.border}`,
            color: c.text,
          }}
          onKeyDown={(e) => {
            if (e.key === "Enter" && valid) onOpen(trimmed);
            if (e.key === "Escape") onCancel();
          }}
        />
        <div className="flex justify-end gap-2">
          <button
            onClick={onCancel}
            className="px-3 py-1.5 rounded-lg text-[13px] transition-colors"
            style={{ color: c.textSecondary, background: c.bgInput, border: `1px solid ${c.border}` }}
          >
            Cancel
          </button>
          <button
            onClick={() => valid && onOpen(trimmed)}
            disabled={!valid}
            className="px-3 py-1.5 rounded-lg text-[13px] font-semibold transition-colors"
            style={{
              background: valid ? "#4f8ef7" : c.bgInput,
              color: valid ? "white" : c.textMuted,
              cursor: valid ? "pointer" : "not-allowed",
              border: `1px solid ${c.border}`,
            }}
          >
            Open
          </button>
        </div>
      </div>
    </div>
  );
}
