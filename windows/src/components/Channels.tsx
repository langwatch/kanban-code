import { useEffect, useMemo, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { open as openDialog } from "@tauri-apps/plugin-dialog";
import { open as openPath } from "@tauri-apps/plugin-shell";
import { getCurrentWebview } from "@tauri-apps/api/webview";
import { useChannelsStore } from "../store/channelsStore";
import { useBoardStore } from "../store/boardStore";
import { useTheme, t } from "../theme";
import type { Channel, ChannelMessage } from "../types";

const IMAGE_EXTS = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "svg"];

/// Caches blob URLs per source path so repeated message renders don't burn
/// IPC reads — the URL stays valid for the document lifetime.
const blobUrlCache = new Map<string, string>();

async function getImageBlobUrl(path: string): Promise<string | null> {
  const cached = blobUrlCache.get(path);
  if (cached) return cached;
  try {
    const bytes = await invoke<number[]>("read_image_bytes", { path });
    const blob = new Blob([new Uint8Array(bytes)]);
    const url = URL.createObjectURL(blob);
    blobUrlCache.set(path, url);
    return url;
  } catch {
    return null;
  }
}

function useImageBlobUrl(path: string | undefined): string | null {
  const [url, setUrl] = useState<string | null>(
    path ? blobUrlCache.get(path) ?? null : null
  );
  useEffect(() => {
    if (!path) return;
    let cancelled = false;
    getImageBlobUrl(path).then((u) => {
      if (!cancelled) setUrl(u);
    });
    return () => { cancelled = true; };
  }, [path]);
  return url;
}

/// Phase-7 channel chat panel. Replaces the BoardView when `chatOpen` is true
/// (mirrors the SettingsView slot). Wire format matches the macOS app and the
/// TS CLI; live updates come from the Tauri watcher events.
export default function Channels() {
  const {
    channels,
    selectedChannel,
    messagesByChannel,
    drafts,
    error,
    init,
    selectChannel,
    sendMessage,
    createChannel,
    saveDraft,
    unreadCount,
    clearError,
  } = useChannelsStore();
  const { setChatOpen } = useBoardStore();
  const { theme } = useTheme();
  const c = t(theme);

  const [newChannelOpen, setNewChannelOpen] = useState(false);

  useEffect(() => {
    init();
    // Intentionally do NOT teardown on unmount — keeping subscriptions live
    // lets the unread counts update even when the chat panel is closed.
  }, []);

  // Auto-select the first channel on first render if none is selected.
  useEffect(() => {
    if (!selectedChannel && channels.length > 0) {
      selectChannel(channels[0].name);
    }
  }, [channels, selectedChannel, selectChannel]);

  const selected = useMemo(
    () => channels.find((ch) => ch.name === selectedChannel) ?? null,
    [channels, selectedChannel]
  );
  const messages = selectedChannel ? messagesByChannel[selectedChannel] ?? [] : [];
  const draft = selectedChannel ? drafts.channels[selectedChannel] ?? "" : "";

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
              Channels
            </span>
          </div>
          <button
            onClick={() => setNewChannelOpen(true)}
            className="p-1 rounded transition-colors"
            style={{ color: c.textMuted }}
            onMouseEnter={(e) => {
              e.currentTarget.style.background = c.hoverBg;
              e.currentTarget.style.color = c.textPrimary;
            }}
            onMouseLeave={(e) => {
              e.currentTarget.style.background = "";
              e.currentTarget.style.color = c.textMuted;
            }}
            title="Create channel"
          >
            <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M12 4v16m8-8H4" />
            </svg>
          </button>
        </div>

        <div className="flex-1 overflow-y-auto py-2">
          {channels.length === 0 ? (
            <div className="px-4 py-6 text-[12px] text-center" style={{ color: c.textMuted }}>
              No channels yet.
              <br />
              Create one to start coordinating with agents.
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
        </div>
      </aside>

      {/* Main pane */}
      <main className="flex-1 flex flex-col overflow-hidden" style={{ background: c.bg }}>
        {selected ? (
          <ChannelPane
            channel={selected}
            messages={messages}
            draft={draft}
            onSend={(body, imagePaths) => sendMessage(selected.name, body, imagePaths)}
            onDraftChange={(body) => saveDraft(selected.name, body)}
            c={c}
            theme={theme}
          />
        ) : (
          <div className="flex-1 flex items-center justify-center text-[13px]" style={{ color: c.textMuted }}>
            Select a channel to start chatting.
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

// ── Sidebar row ──────────────────────────────────────────────────────────────

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
      {unread > 0 && (
        <span
          className="ml-2 shrink-0 inline-flex items-center justify-center text-[10px] font-semibold rounded-full px-1.5"
          style={{
            background: "#4f8ef7",
            color: "white",
            minWidth: 18,
            height: 18,
          }}
        >
          {unread > 99 ? "99+" : unread}
        </span>
      )}
    </button>
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
  onSend: (body: string, imagePaths?: string[]) => void;
  onDraftChange: (body: string) => void;
  c: ReturnType<typeof t>;
  theme: "dark" | "light";
}) {
  const listRef = useRef<HTMLDivElement>(null);
  const composeRef = useRef<HTMLDivElement>(null);
  const lastSeenRef = useRef<number>(0);
  const [attachments, setAttachments] = useState<string[]>([]);
  const [isDragHover, setIsDragHover] = useState(false);

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

  // Drag-drop: Tauri webview intercepts native OS file drops and emits a
  // synthetic event with absolute paths — HTML drag-drop events would not
  // fire here. Only queue when the drop happens over the compose region.
  useEffect(() => {
    let unlisten: undefined | (() => void);
    (async () => {
      unlisten = await getCurrentWebview().onDragDropEvent((event) => {
        const composeEl = composeRef.current;
        if (!composeEl) return;
        const rect = composeEl.getBoundingClientRect();
        const inCompose = (pos: { x: number; y: number }) => {
          const dpr = window.devicePixelRatio || 1;
          const x = pos.x / dpr;
          const y = pos.y / dpr;
          return x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom;
        };
        if (event.payload.type === "over") {
          setIsDragHover(inCompose(event.payload.position));
        } else if (event.payload.type === "drop") {
          setIsDragHover(false);
          if (!inCompose(event.payload.position)) return;
          const imageOnly = event.payload.paths.filter((p) =>
            IMAGE_EXTS.some((ext) => p.toLowerCase().endsWith(`.${ext}`))
          );
          if (imageOnly.length > 0) {
            setAttachments((prev) => [...prev, ...imageOnly]);
          }
        } else {
          setIsDragHover(false);
        }
      });
    })();
    return () => { unlisten?.(); };
  }, []);

  const handlePickFiles = async () => {
    try {
      const picked = await openDialog({
        multiple: true,
        filters: [{ name: "Images", extensions: IMAGE_EXTS }],
      });
      if (!picked) return;
      const paths = Array.isArray(picked) ? picked : [picked];
      setAttachments((prev) => [...prev, ...paths]);
    } catch {
      // dialog dismissed
    }
  };

  const handlePaste = async (e: React.ClipboardEvent<HTMLTextAreaElement>) => {
    const items = Array.from(e.clipboardData.items);
    const imageItems = items.filter(
      (it) => it.kind === "file" && it.type.startsWith("image/")
    );
    if (imageItems.length === 0) return;
    e.preventDefault();
    for (const it of imageItems) {
      const file = it.getAsFile();
      if (!file) continue;
      const buf = await file.arrayBuffer();
      const ext = (it.type.split("/")[1] ?? "png").replace(/[^a-z0-9]/gi, "");
      try {
        const path = await invoke<string>("persist_clipboard_image", {
          bytes: Array.from(new Uint8Array(buf)),
          ext,
        });
        setAttachments((prev) => [...prev, path]);
      } catch (err) {
        console.error("paste image persist failed:", err);
      }
    }
  };

  const removeAttachment = (idx: number) =>
    setAttachments((prev) => prev.filter((_, i) => i !== idx));

  const canSend = draft.trim().length > 0 || attachments.length > 0;

  const submitSend = () => {
    if (!canSend) return;
    onSend(draft, attachments);
    setAttachments([]);
  };

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    submitSend();
  };

  return (
    <>
      <div
        className="flex items-center justify-between px-6 h-12 shrink-0"
        style={{ borderBottom: `1px solid ${c.border}` }}
      >
        <div className="flex items-center gap-3">
          <span className="text-[15px] font-semibold" style={{ color: c.textPrimary }}>
            #{channel.name}
          </span>
          <span className="text-[12px]" style={{ color: c.textMuted }}>
            {channel.members.length} member{channel.members.length === 1 ? "" : "s"}
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

      <div
        ref={composeRef}
        className="shrink-0"
        style={{ borderTop: `1px solid ${c.border}` }}
      >
        {attachments.length > 0 && (
          <div className="flex flex-wrap gap-2 px-6 pt-3">
            {attachments.map((p, i) => (
              <AttachmentThumb
                key={`${p}-${i}`}
                path={p}
                onRemove={() => removeAttachment(i)}
                c={c}
              />
            ))}
          </div>
        )}
        <form
          onSubmit={handleSubmit}
          className="flex items-end gap-2 px-6 py-3"
          style={{
            background: isDragHover ? "rgba(79,142,247,0.08)" : "transparent",
            transition: "background 120ms",
          }}
        >
          <button
            type="button"
            onClick={handlePickFiles}
            className="p-2 rounded-lg transition-colors"
            style={{ color: c.textMuted, border: `1px solid ${c.border}`, background: c.bgInput }}
            onMouseEnter={(e) => (e.currentTarget.style.color = c.textPrimary)}
            onMouseLeave={(e) => (e.currentTarget.style.color = c.textMuted)}
            title="Attach images"
          >
            <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
              <path
                strokeLinecap="round"
                strokeLinejoin="round"
                d="m18.375 12.739-7.693 7.693a4.5 4.5 0 0 1-6.364-6.364l10.94-10.94A3 3 0 1 1 19.5 7.372L8.552 18.32m.009-.01-.01.01m5.699-9.941-7.81 7.81a1.5 1.5 0 0 0 2.122 2.122l7.81-7.81"
              />
            </svg>
          </button>
          <textarea
            value={draft}
            onChange={(e) => onDraftChange(e.target.value)}
            onPaste={handlePaste}
            onKeyDown={(e) => {
              if (e.key === "Enter" && !e.shiftKey) {
                e.preventDefault();
                submitSend();
              }
            }}
            placeholder={`Message #${channel.name}`}
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
            disabled={!canSend}
            className="px-4 py-2 rounded-lg text-[13px] font-semibold transition-colors"
            style={{
              background: canSend ? "#4f8ef7" : c.bgInput,
              color: canSend ? "white" : c.textMuted,
              cursor: canSend ? "pointer" : "not-allowed",
              border: `1px solid ${c.border}`,
            }}
          >
            Send
          </button>
        </form>
      </div>
      {/* `theme` is currently informational; kept on the signature so we can
          add theme-specific message rendering without changing call sites. */}
      <span style={{ display: "none" }}>{theme}</span>
    </>
  );
}

function AttachmentThumb({
  path,
  onRemove,
  c,
}: {
  path: string;
  onRemove: () => void;
  c: ReturnType<typeof t>;
}) {
  const url = useImageBlobUrl(path);
  const name = path.split(/[\\/]/).pop() ?? path;
  return (
    <div
      className="relative rounded-lg overflow-hidden flex items-center justify-center"
      style={{
        width: 64,
        height: 64,
        background: c.bgInput,
        border: `1px solid ${c.border}`,
      }}
      title={name}
    >
      {url ? (
        <img src={url} alt={name} className="w-full h-full object-cover" />
      ) : (
        <span className="text-[10px]" style={{ color: c.textMuted }}>…</span>
      )}
      <button
        type="button"
        onClick={onRemove}
        className="absolute top-0 right-0 w-5 h-5 flex items-center justify-center text-[11px] leading-none"
        style={{
          background: "rgba(0,0,0,0.6)",
          color: "white",
          borderBottomLeftRadius: 6,
        }}
        title="Remove"
      >
        ×
      </button>
    </div>
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
    <div>
      <div className="flex items-baseline gap-2">
        <span className="text-[13px] font-semibold shrink-0" style={{ color: c.textPrimary }}>
          @{message.from.handle}
        </span>
        <span className="text-[10px] shrink-0" style={{ color: c.textMuted }}>
          {ts}
        </span>
        {message.body && (
          <span className="text-[13px] whitespace-pre-wrap break-words" style={{ color: c.text }}>
            {message.body}
          </span>
        )}
      </div>
      {message.imagePaths && message.imagePaths.length > 0 && (
        <div className="flex flex-wrap gap-2 mt-1 ml-1">
          {message.imagePaths.map((p, i) => (
            <MessageImage key={`${p}-${i}`} path={p} c={c} />
          ))}
        </div>
      )}
    </div>
  );
}

function MessageImage({ path, c }: { path: string; c: ReturnType<typeof t> }) {
  const url = useImageBlobUrl(path);
  return (
    <button
      type="button"
      onClick={() => { void openPath(path); }}
      className="rounded-lg overflow-hidden block"
      style={{
        width: 160,
        maxHeight: 160,
        background: c.bgInput,
        border: `1px solid ${c.border}`,
        cursor: "zoom-in",
      }}
      title={path}
    >
      {url ? (
        <img src={url} alt="" className="block w-full h-auto max-h-[160px] object-contain" />
      ) : (
        <div className="w-full h-[80px] flex items-center justify-center text-[10px]" style={{ color: c.textMuted }}>
          …
        </div>
      )}
    </button>
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
