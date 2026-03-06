import { useEffect, useState, useRef, useCallback } from "react";
import {
  getTranscript,
  openInEditor,
  useBoardStore,
} from "../store/boardStore";
import { useTheme, t } from "../theme";
import type { Turn, TranscriptPage } from "../types";
import TerminalView from "./Terminal";

type Tab = "terminal" | "history" | "issue" | "pr" | "prompt";

const TAB_LABELS: Record<Tab, string> = {
  terminal: "Terminal",
  history: "History",
  issue: "Issue",
  pr: "PR",
  prompt: "Prompt",
};

export default function CardDetailView() {
  const { selectedCard, selectCard, renameCard, deleteCard, archiveCard } = useBoardStore();
  const card = selectedCard();
  const { theme } = useTheme();
  const c = t(theme);

  const [activeTab, setActiveTab] = useState<Tab>("terminal");
  const [turns, setTurns] = useState<Turn[]>([]);
  const [transcriptPage, setTranscriptPage] = useState<TranscriptPage | null>(null);
  const [loadingTranscript, setLoadingTranscript] = useState(false);
  const [isEditing, setIsEditing] = useState(false);
  const [editName, setEditName] = useState("");
  const [terminalActive, setTerminalActive] = useState(false);
  const [drawerWidth, setDrawerWidth] = useState(480);
  const isResizing = useRef(false);

  const handleMouseDown = useCallback((e: React.MouseEvent) => {
    e.preventDefault();
    isResizing.current = true;
    const startX = e.clientX;
    const startWidth = drawerWidth;

    const onMouseMove = (e: MouseEvent) => {
      if (!isResizing.current) return;
      const delta = startX - e.clientX;
      setDrawerWidth(Math.min(Math.max(startWidth + delta, 340), 960));
    };

    const onMouseUp = () => {
      isResizing.current = false;
      document.removeEventListener("mousemove", onMouseMove);
      document.removeEventListener("mouseup", onMouseUp);
      document.body.style.cursor = "";
      document.body.style.userSelect = "";
    };

    document.body.style.cursor = "col-resize";
    document.body.style.userSelect = "none";
    document.addEventListener("mousemove", onMouseMove);
    document.addEventListener("mouseup", onMouseUp);
  }, [drawerWidth]);

  useEffect(() => {
    if (!card) return;
    setActiveTab(card.link.sessionLink?.sessionId ? "terminal" : "history");
    setTurns([]);
    setTranscriptPage(null);
    setTerminalActive(false);
    if (card.link.sessionLink?.sessionId) {
      loadTranscript(card.link.sessionLink.sessionId, 0, true);
    }
  }, [card?.id]);

  const loadTranscript = async (sessionId: string, offset: number, reset: boolean) => {
    setLoadingTranscript(true);
    try {
      const page = await getTranscript(sessionId, offset);
      setTranscriptPage(page);
      setTurns((prev) => (reset ? page.turns : [...prev, ...page.turns]));
    } catch {
      // silent
    } finally {
      setLoadingTranscript(false);
    }
  };

  if (!card) return null;

  const sessionId = card.link.sessionLink?.sessionId;
  const projectPath = card.link.projectPath ?? card.session?.projectPath;
  const branch = card.link.worktreeLink?.branch;
  const pr = card.link.prLinks[0];
  const issue = card.link.issueLink;

  const handleRename = () => {
    if (editName.trim()) renameCard(card.id, editName.trim());
    setIsEditing(false);
  };

  const shellCommand = ["wsl.exe"];
  const cdCmd = projectPath ? `cd ${projectPath.replace(/ /g, "\\ ")} && ` : "";
  const resumeInput = `${cdCmd}claude --resume ${sessionId}\r`;

  const handleStartTerminal = () => {
    setTerminalActive(true);
    setActiveTab("terminal");
  };

  // Only show tabs that have data
  const availableTabs: Tab[] = (["terminal", "history", "issue", "pr", "prompt"] as Tab[]).filter((tab) => {
    if (tab === "terminal") return !!sessionId;
    if (tab === "history") return !!sessionId;
    if (tab === "issue") return !!issue;
    if (tab === "pr") return !!pr;
    if (tab === "prompt") return !!card.link.promptBody;
    return false;
  });

  return (
    <div
      className="flex flex-col h-full overflow-hidden relative animate-slide-in"
      style={{
        width: drawerWidth,
        minWidth: 340,
        maxWidth: 960,
        background: c.bgDetail,
        borderLeft: `1px solid ${c.border}`,
      }}
    >
      {/* Resize handle */}
      <div
        onMouseDown={handleMouseDown}
        className="absolute left-0 top-0 bottom-0 z-10 group"
        style={{ width: 6, cursor: "col-resize" }}
      >
        <div
          className="absolute left-[2px] top-0 bottom-0 w-[2px] rounded-full transition-all duration-150 opacity-0 group-hover:opacity-100 group-active:opacity-100"
          style={{ background: "#4f8ef7" }}
        />
      </div>

      {/* Header */}
      <div className="px-5 pt-5 pb-4 shrink-0">
        {/* Title row */}
        <div className="flex items-start justify-between gap-3">
          {isEditing ? (
            <input
              autoFocus
              className="flex-1 rounded-lg px-3 py-1.5 text-[15px] font-medium outline-none"
              style={{
                background: c.bgInput,
                border: `1px solid rgba(79,142,247,0.4)`,
                color: c.textPrimary,
              }}
              value={editName}
              onChange={(e) => setEditName(e.target.value)}
              onBlur={handleRename}
              onKeyDown={(e) => {
                if (e.key === "Enter") handleRename();
                if (e.key === "Escape") setIsEditing(false);
              }}
            />
          ) : (
            <h2
              className="flex-1 text-[17px] font-semibold leading-snug tracking-[-0.01em] cursor-text"
              style={{ color: c.textPrimary }}
              onClick={() => { setEditName(card.displayTitle); setIsEditing(true); }}
              title="Click to rename"
            >
              {card.displayTitle}
            </h2>
          )}
          <button
            onClick={() => selectCard(null)}
            className="mt-0.5 shrink-0 rounded-md p-1 transition-all duration-150"
            style={{ color: c.textDim }}
            onMouseEnter={(e) => { e.currentTarget.style.background = c.hoverBg; e.currentTarget.style.color = c.textSecondary; }}
            onMouseLeave={(e) => { e.currentTarget.style.background = ""; e.currentTarget.style.color = c.textDim; }}
            title="Close"
          >
            <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2.5}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M6 18 18 6M6 6l12 12" />
            </svg>
          </button>
        </div>

        {/* Meta row */}
        <div className="flex flex-wrap items-center gap-2 mt-3">
          {card.projectName && (
            <span
              className="text-[12px] font-medium px-2 py-0.5 rounded-md"
              style={{ color: c.textMuted, background: c.bgAccent("0.04") }}
              title={projectPath ?? ""}
            >
              {card.projectName}
            </span>
          )}
          {branch && <MetaBadge label={branch} color="#4f8ef7" theme={theme} title={`Branch: ${branch}`} />}
          {pr && <MetaBadge label={`PR #${pr.number}`} color="#3fb950" theme={theme} title={pr.title ?? ""} />}
          {issue && <MetaBadge label={`#${issue.number}`} color="#d29922" theme={theme} title={issue.title ?? ""} />}
        </div>

        {/* Actions */}
        <div className="flex gap-2.5 mt-4">
          {sessionId && (
            <button
              onClick={handleStartTerminal}
              className="flex-1 flex items-center justify-center gap-2 h-9 rounded-lg text-[13px] font-semibold transition-all duration-150"
              style={{
                background: "#4f8ef7",
                color: "#fff",
              }}
              onMouseEnter={(e) => { e.currentTarget.style.background = "#5e9aff"; e.currentTarget.style.transform = "translateY(-0.5px)"; }}
              onMouseLeave={(e) => { e.currentTarget.style.background = "#4f8ef7"; e.currentTarget.style.transform = ""; }}
              title={terminalActive ? "Switch to terminal view" : "Resume this session in an embedded terminal"}
            >
              <svg className="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2.5}>
                <path strokeLinecap="round" strokeLinejoin="round" d="m5.25 4.5 7.5 7.5-7.5 7.5m6-15 7.5 7.5-7.5 7.5" />
              </svg>
              {terminalActive ? "Terminal" : "Resume"}
            </button>
          )}
          {projectPath && (
            <button
              onClick={() => openInEditor(projectPath)}
              className="flex-1 flex items-center justify-center gap-2 h-9 rounded-lg text-[13px] font-medium transition-all duration-150"
              style={{ border: `1px solid ${c.border}`, color: c.textSecondary }}
              onMouseEnter={(e) => { e.currentTarget.style.borderColor = c.borderBright; e.currentTarget.style.background = c.hoverBg; e.currentTarget.style.transform = "translateY(-0.5px)"; }}
              onMouseLeave={(e) => { e.currentTarget.style.borderColor = c.border; e.currentTarget.style.background = ""; e.currentTarget.style.transform = ""; }}
              title={`Open in editor: ${projectPath}`}
            >
              <svg className="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                <path strokeLinecap="round" strokeLinejoin="round" d="m10 20-7-7 7-7M17 20l7-7-7-7" />
              </svg>
              Editor
            </button>
          )}
          <button
            onClick={() => { deleteCard(card.id); selectCard(null); }}
            className="flex items-center justify-center gap-2 h-9 px-3 rounded-lg text-[13px] font-medium transition-all duration-150"
            style={{ border: `1px solid ${c.border}`, color: c.textDim }}
            onMouseEnter={(e) => { e.currentTarget.style.borderColor = "#f85149"; e.currentTarget.style.color = "#f85149"; e.currentTarget.style.background = "rgba(248,81,73,0.06)"; }}
            onMouseLeave={(e) => { e.currentTarget.style.borderColor = c.border; e.currentTarget.style.color = c.textDim; e.currentTarget.style.background = ""; }}
            title="Delete this card"
          >
            <svg className="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
              <path strokeLinecap="round" strokeLinejoin="round" d="m14.74 9-.346 9m-4.788 0L9.26 9m9.968-3.21c.342.052.682.107 1.022.166m-1.022-.165L18.16 19.673a2.25 2.25 0 0 1-2.244 2.077H8.084a2.25 2.25 0 0 1-2.244-2.077L4.772 5.79m14.456 0a48.108 48.108 0 0 0-3.478-.397m-12 .562c.34-.059.68-.114 1.022-.165m0 0a48.11 48.11 0 0 1 3.478-.397m7.5 0v-.916c0-1.18-.91-2.164-2.09-2.201a51.964 51.964 0 0 0-3.32 0c-1.18.037-2.09 1.022-2.09 2.201v.916m7.5 0a48.667 48.667 0 0 0-7.5 0" />
            </svg>
          </button>
        </div>
      </div>

      {/* Tabs — only show ones with content */}
      {availableTabs.length > 1 && (
        <div className="flex px-5 shrink-0 gap-1" style={{ borderBottom: `1px solid ${c.border}` }}>
          {availableTabs.map((tab) => {
            const active = activeTab === tab;
            return (
              <button
                key={tab}
                onClick={() => setActiveTab(tab)}
                className="relative pb-2.5 pt-1.5 px-3 text-[12px] font-medium transition-colors duration-150"
                style={{
                  color: active ? c.textPrimary : c.textMuted,
                }}
                onMouseEnter={(e) => { if (!active) e.currentTarget.style.color = c.textSecondary; }}
                onMouseLeave={(e) => { if (!active) e.currentTarget.style.color = c.textMuted; }}
              >
                {TAB_LABELS[tab]}
                {active && (
                  <div
                    className="absolute bottom-0 left-1/2 -translate-x-1/2 h-[2px] rounded-full"
                    style={{ width: "60%", background: "#4f8ef7" }}
                  />
                )}
              </button>
            );
          })}
        </div>
      )}

      {/* Tab content */}
      <div className="flex-1 overflow-hidden flex flex-col min-h-0">
        {activeTab === "terminal" && sessionId && (
          terminalActive ? (
            <TerminalView
              ptyId={`resume-${card.id}`}
              command={shellCommand}
              initialInput={resumeInput}
              onExit={() => {}}
            />
          ) : (
            <div className="flex flex-col items-center justify-center flex-1 gap-4 p-8">
              <div
                className="w-12 h-12 rounded-2xl flex items-center justify-center"
                style={{ background: c.bgAccent("0.04") }}
              >
                <svg className="w-6 h-6" style={{ color: c.textDim }} fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
                  <path strokeLinecap="round" strokeLinejoin="round" d="m5.25 4.5 7.5 7.5-7.5 7.5m6-15 7.5 7.5-7.5 7.5" />
                </svg>
              </div>
              <div className="text-center">
                <p className="text-[13px] font-medium" style={{ color: c.textSecondary }}>
                  Ready to resume
                </p>
                <p className="text-[12px] mt-1" style={{ color: c.textDim }}>
                  Click Resume to start an interactive Claude session
                </p>
              </div>
            </div>
          )
        )}

        {activeTab === "history" && (
          <div className="overflow-y-auto flex-1">
            <HistoryTab
              turns={turns}
              transcriptPage={transcriptPage}
              loading={loadingTranscript}
              onLoadMore={() => {
                if (sessionId && transcriptPage?.hasMore)
                  loadTranscript(sessionId, transcriptPage.nextOffset, false);
              }}
            />
          </div>
        )}

        {activeTab === "issue" && issue && (
          <div className="overflow-y-auto flex-1">
            <ContentTab title={issue.title ?? `Issue #${issue.number}`} body={issue.body} url={issue.url} />
          </div>
        )}
        {activeTab === "pr" && pr && (
          <div className="overflow-y-auto flex-1">
            <ContentTab title={pr.title ?? `PR #${pr.number}`} body={pr.body} url={pr.url} />
          </div>
        )}
        {activeTab === "prompt" && card.link.promptBody && (
          <div className="overflow-y-auto flex-1 p-5">
            <pre
              className="text-[13px] whitespace-pre-wrap break-words leading-relaxed font-mono rounded-xl p-4"
              style={{
                color: c.textSecondary,
                background: c.bgAccent("0.03"),
                border: `1px solid ${c.border}`,
              }}
            >
              {card.link.promptBody}
            </pre>
          </div>
        )}
      </div>
    </div>
  );
}

/* ── Sub-components ──────────────────────────────────────────────── */

function MetaBadge({ label, color, theme, title }: { label: string; color: string; theme: string; title?: string }) {
  return (
    <span
      className="text-[11px] font-semibold px-2 py-0.5 rounded-md transition-all duration-150 cursor-default"
      style={{
        color,
        background: color + (theme === "dark" ? "14" : "10"),
      }}
      title={title}
    >
      {label}
    </span>
  );
}

function HistoryTab({ turns, transcriptPage, loading, onLoadMore }: {
  turns: Turn[]; transcriptPage: TranscriptPage | null; loading: boolean; onLoadMore: () => void;
}) {
  const { theme } = useTheme();
  const c = t(theme);

  if (loading && turns.length === 0) {
    return (
      <div className="flex items-center justify-center p-10">
        <div className="flex items-center gap-2.5">
          <div className="w-4 h-4 border-2 border-[#4f8ef7] border-t-transparent rounded-full animate-spin" />
          <span className="text-[13px]" style={{ color: c.textMuted }}>Loading transcript...</span>
        </div>
      </div>
    );
  }

  if (turns.length === 0) {
    return (
      <div className="flex items-center justify-center p-10 text-[13px]" style={{ color: c.textDim }}>
        No history yet
      </div>
    );
  }

  return (
    <div className="flex flex-col py-1">
      {turns.map((turn) => <TurnItem key={turn.index} turn={turn} />)}
      {transcriptPage?.hasMore && (
        <button
          onClick={onLoadMore}
          disabled={loading}
          className="mx-4 my-3 py-2 rounded-lg text-[12px] font-medium transition-all duration-150 disabled:opacity-40"
          style={{ border: `1px solid ${c.border}`, color: c.textMuted }}
          onMouseEnter={(e) => { e.currentTarget.style.background = c.hoverBg; }}
          onMouseLeave={(e) => { e.currentTarget.style.background = ""; }}
        >
          {loading ? "Loading..." : `Load more (${transcriptPage.totalTurns - turns.length} remaining)`}
        </button>
      )}
    </div>
  );
}

function TurnItem({ turn }: { turn: Turn }) {
  const { theme } = useTheme();
  const c = t(theme);
  const isUser = turn.role === "user";
  return (
    <div
      className="px-5 py-3.5 transition-colors duration-100"
      style={{ borderBottom: `1px solid ${c.bgAccent("0.03")}` }}
      onMouseEnter={(e) => { e.currentTarget.style.background = c.bgAccent("0.02"); }}
      onMouseLeave={(e) => { e.currentTarget.style.background = ""; }}
    >
      <div className="flex items-center gap-2 mb-1.5">
        <div
          className="w-1.5 h-1.5 rounded-full"
          style={{ background: isUser ? "#4f8ef7" : "#3fb950" }}
        />
        <span className="text-[11px] font-semibold uppercase tracking-wider" style={{ color: isUser ? "#4f8ef7" : "#3fb950" }}>
          {isUser ? "You" : "Claude"}
        </span>
        {turn.timestamp && (
          <span className="text-[11px] ml-auto" style={{ color: c.textDim }}>
            {new Date(turn.timestamp).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}
          </span>
        )}
      </div>
      <p className="text-[13px] leading-[1.6] line-clamp-4 pl-3.5" style={{ color: c.textSecondary }}>
        {turn.textPreview || "(tool use)"}
      </p>
    </div>
  );
}

function ContentTab({ title, body, url }: { title: string; body?: string; url?: string }) {
  const { theme } = useTheme();
  const c = t(theme);
  return (
    <div className="p-5 flex flex-col gap-4">
      <div className="flex items-start justify-between gap-3">
        <h3 className="text-[15px] font-semibold leading-snug" style={{ color: c.textPrimary }}>{title}</h3>
        {url && (
          <a
            href={url}
            target="_blank"
            rel="noreferrer"
            className="shrink-0 p-1 rounded-md transition-all duration-150"
            style={{ color: "#4f8ef7" }}
            onMouseEnter={(e) => { e.currentTarget.style.background = "rgba(79,142,247,0.1)"; }}
            onMouseLeave={(e) => { e.currentTarget.style.background = ""; }}
            title="Open in browser"
          >
            <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M10 6H6a2 2 0 0 0-2 2v10a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-4M14 4h6m0 0v6m0-6L10 14" />
            </svg>
          </a>
        )}
      </div>
      {body ? (
        <div className="text-[13px] leading-[1.7] whitespace-pre-wrap break-words" style={{ color: c.textSecondary }}>
          {body}
        </div>
      ) : (
        <p className="text-[13px]" style={{ color: c.textDim }}>No description</p>
      )}
    </div>
  );
}
