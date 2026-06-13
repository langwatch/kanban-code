import { useEffect, useState, useRef, useCallback } from "react";
import { ask } from "@tauri-apps/plugin-dialog";
import {
  getTranscript,
  getSettings,
  openInEditor,
  useBoardStore,
  addQueuedPrompt,
  updateQueuedPrompt,
  removeQueuedPrompt,
  searchTranscript,
} from "../store/boardStore";
import { useTheme, t } from "../theme";
import type { Turn, TranscriptPage, QueuedPrompt } from "../types";
import TerminalView from "./Terminal";
import QueuedPromptDialog from "./QueuedPromptDialog";
import QueuedPromptsBar from "./QueuedPromptsBar";

type Tab = "terminal" | "history" | "issue" | "pr" | "prompt";

const TAB_LABELS: Record<Tab, string> = {
  terminal: "Terminal",
  history: "History",
  issue: "Issue",
  pr: "PR",
  prompt: "Prompt",
};

export default function CardDetailView() {
  const { selectedCard, selectCard, renameCard, deleteCard } = useBoardStore();
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

  // Queued prompts state
  const [showQueueDialog, setShowQueueDialog] = useState(false);
  const [editingPrompt, setEditingPrompt] = useState<QueuedPrompt | null>(null);
  const [queuedPrompts, setQueuedPrompts] = useState<QueuedPrompt[]>([]);
  const terminalWriteRef = useRef<((text: string) => void) | null>(null);

  // Settings
  const [terminalFontSize, setTerminalFontSize] = useState(15);
  const [terminalShell, setTerminalShell] = useState<string>("cmd.exe");

  // Search state
  const [searchText, setSearchText] = useState("");
  const [searchMatches, setSearchMatches] = useState<number[]>([]);
  const [currentMatchIdx, setCurrentMatchIdx] = useState(0);
  const [isSearching, setIsSearching] = useState(false);
  const searchDebounce = useRef<ReturnType<typeof setTimeout> | null>(null);

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

  // Load terminal font size + shell from settings
  useEffect(() => {
    getSettings()
      .then((s) => {
        setTerminalFontSize(s.terminalFontSize || 15);
        setTerminalShell((s.terminalShell && s.terminalShell.trim()) || "cmd.exe");
      })
      .catch(() => {});
  }, []);

  // Reset state when card changes
  useEffect(() => {
    if (!card) return;
    const hasTerminal = !!card.link.sessionLink?.sessionId || !!card.link.promptBody;
    setActiveTab(hasTerminal ? "terminal" : "history");
    setTurns([]);
    setTranscriptPage(null);
    setTerminalActive(false);
    setQueuedPrompts(card.link.queuedPrompts ?? []);
    setSearchText("");
    setSearchMatches([]);
    setCurrentMatchIdx(0);
    if (card.link.sessionLink?.sessionId) {
      loadTranscript(card.link.sessionLink.sessionId, 0, true);
    }
  }, [card?.id]);

  // Sync queued prompts when card data updates
  useEffect(() => {
    if (card) {
      setQueuedPrompts(card.link.queuedPrompts ?? []);
    }
  }, [card?.link.updatedAt]);

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

  // Search debounce
  useEffect(() => {
    if (!card?.link.sessionLink?.sessionId) return;
    if (searchDebounce.current) clearTimeout(searchDebounce.current);

    if (searchText.trim().length < 2) {
      setSearchMatches([]);
      setCurrentMatchIdx(0);
      setIsSearching(false);
      return;
    }

    setIsSearching(true);
    searchDebounce.current = setTimeout(async () => {
      try {
        const matches = await searchTranscript(card.link.sessionLink!.sessionId, searchText.trim());
        setSearchMatches(matches);
        setCurrentMatchIdx(0);
      } catch {
        setSearchMatches([]);
      } finally {
        setIsSearching(false);
      }
    }, 300);

    return () => { if (searchDebounce.current) clearTimeout(searchDebounce.current); };
  }, [searchText, card?.link.sessionLink?.sessionId]);

  if (!card) return null;

  const sessionId = card.link.sessionLink?.sessionId;
  const projectPath = card.link.projectPath ?? card.session?.projectPath;
  const branch = card.link.worktreeLink?.branch;
  const pr = card.link.prLinks[0];
  const issue = card.link.issueLink;
  const promptBody = card.link.promptBody;
  const canTerminal = !!sessionId || !!promptBody;

  const handleRename = () => {
    if (editName.trim()) renameCard(card.id, editName.trim());
    setIsEditing(false);
  };

  const handleConfirmDelete = async () => {
    if (!card) return;
    const title = card.displayTitle || card.link.name || "this card";
    const detail = terminalActive
      ? "The open terminal will be stopped. The Claude session .jsonl on disk is not deleted."
      : "The Claude session .jsonl on disk is not deleted — you can still find it in All Sessions.";
    const ok = await ask(`Delete "${title}"?\n\n${detail}`, {
      title: "Delete card",
      kind: "warning",
      okLabel: "Delete",
      cancelLabel: "Cancel",
    });
    if (ok) deleteCard(card.id);
  };

  // Split the user-configurable shell string into [exe, ...args]. Default is
  // cmd.exe so the app is Windows-native out of the box; setting it to
  // "wsl.exe" launches Claude inside WSL instead.
  const shellCommand = terminalShell.trim().split(/\s+/).filter(Boolean);
  const shellExe = (shellCommand[0] ?? "cmd.exe").toLowerCase();
  const isUnixShell = /(^|[\\/])(wsl|bash|sh|zsh|fish)(\.exe)?$/.test(shellExe);

  const terminalInput = (() => {
    if (isUnixShell) {
      // bash-style: backslash-escape spaces in path, single-quote the prompt.
      const cdCmd = projectPath ? `cd ${projectPath.replace(/ /g, "\\ ")} && ` : "";
      return sessionId
        ? `${cdCmd}claude --resume ${sessionId}\r`
        : `${cdCmd}claude '${(promptBody ?? "").replace(/'/g, "'\\''")}'\r`;
    }
    // cmd.exe / pwsh — double-quote the path; "" escapes a quote inside cmd
    // double-quotes (PowerShell also accepts it).
    const cdCmd = projectPath ? `cd "${projectPath}" && ` : "";
    return sessionId
      ? `${cdCmd}claude --resume ${sessionId}\r`
      : `${cdCmd}claude "${(promptBody ?? "").replace(/"/g, '""')}"\r`;
  })();

  const handleStartTerminal = () => {
    setTerminalActive(true);
    setActiveTab("terminal");
  };

  // Auto-start terminal for freshly created tasks
  useEffect(() => {
    if (!sessionId && promptBody && !terminalActive) {
      handleStartTerminal();
    }
  }, [card.id]);

  // Queued prompt handlers
  const handleAddPrompt = async (body: string, sendAutomatically: boolean) => {
    try {
      const prompt = await addQueuedPrompt(card.id, body, sendAutomatically);
      setQueuedPrompts((prev) => [...prev, prompt]);
    } catch { /* silent */ }
  };

  const handleUpdatePrompt = async (body: string, sendAutomatically: boolean) => {
    if (!editingPrompt) return;
    try {
      await updateQueuedPrompt(card.id, editingPrompt.id, body, sendAutomatically);
      setQueuedPrompts((prev) =>
        prev.map((p) => p.id === editingPrompt.id ? { ...p, body, sendAutomatically } : p)
      );
    } catch { /* silent */ }
  };

  const handleRemovePrompt = async (promptId: string) => {
    try {
      await removeQueuedPrompt(card.id, promptId);
      setQueuedPrompts((prev) => prev.filter((p) => p.id !== promptId));
    } catch { /* silent */ }
  };

  const handleSendNow = async (promptId: string) => {
    const prompt = queuedPrompts.find((p) => p.id === promptId);
    if (!prompt || !terminalWriteRef.current) return;
    // Write to terminal
    terminalWriteRef.current(prompt.body + "\r");
    // Remove from queue
    handleRemovePrompt(promptId);
  };

  const handleEditPrompt = (prompt: QueuedPrompt) => {
    setEditingPrompt(prompt);
    setShowQueueDialog(true);
  };

  // Search navigation
  const goToMatch = (dir: "prev" | "next") => {
    if (searchMatches.length === 0) return;
    setCurrentMatchIdx((prev) => {
      if (dir === "next") return (prev + 1) % searchMatches.length;
      return (prev - 1 + searchMatches.length) % searchMatches.length;
    });
  };

  // Only show tabs that have data
  const availableTabs: Tab[] = (["terminal", "history", "issue", "pr", "prompt"] as Tab[]).filter((tab) => {
    if (tab === "terminal") return canTerminal;
    if (tab === "history") return !!sessionId;
    if (tab === "issue") return !!issue;
    if (tab === "pr") return !!pr;
    if (tab === "prompt") return !!promptBody;
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
          {canTerminal && (
            <button
              onClick={handleStartTerminal}
              className="flex-1 flex items-center justify-center gap-2 h-9 rounded-lg text-[13px] font-semibold transition-all duration-150"
              style={{
                background: "#4f8ef7",
                color: "#fff",
              }}
              onMouseEnter={(e) => { e.currentTarget.style.background = "#5e9aff"; e.currentTarget.style.transform = "translateY(-0.5px)"; }}
              onMouseLeave={(e) => { e.currentTarget.style.background = "#4f8ef7"; e.currentTarget.style.transform = ""; }}
              title={terminalActive ? "Switch to terminal view" : sessionId ? "Resume this session" : "Start Claude session"}
            >
              <svg className="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2.5}>
                <path strokeLinecap="round" strokeLinejoin="round" d="m5.25 4.5 7.5 7.5-7.5 7.5m6-15 7.5 7.5-7.5 7.5" />
              </svg>
              {terminalActive ? "Terminal" : sessionId ? "Resume" : "Start"}
            </button>
          )}
          {canTerminal && terminalActive && (
            <button
              onClick={() => { setEditingPrompt(null); setShowQueueDialog(true); }}
              className="flex items-center justify-center gap-1.5 h-9 px-3 rounded-lg text-[13px] font-medium transition-all duration-150"
              style={{ border: `1px solid ${c.border}`, color: c.textSecondary }}
              onMouseEnter={(e) => { e.currentTarget.style.borderColor = c.borderBright; e.currentTarget.style.background = c.hoverBg; }}
              onMouseLeave={(e) => { e.currentTarget.style.borderColor = c.border; e.currentTarget.style.background = ""; }}
              title="Queue a prompt to send to Claude later"
            >
              <svg className="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M12 4.5v15m7.5-7.5h-15" />
              </svg>
              Queue
            </button>
          )}
          {projectPath && (
            <button
              onClick={() => openInEditor(projectPath)}
              className="flex items-center justify-center gap-2 h-9 px-3 rounded-lg text-[13px] font-medium transition-all duration-150"
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
            onClick={handleConfirmDelete}
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

      {/* Tabs */}
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
                onMouseLeave={(e) => { if (!active) e.currentTarget.style.color = active ? c.textPrimary : c.textMuted; }}
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
      <div
        className="flex-1 overflow-hidden flex flex-col min-h-0"
        style={{ background: activeTab === "terminal" && terminalActive ? "#0a0a0c" : undefined }}
      >
        {activeTab === "terminal" && canTerminal && (
          terminalActive ? (
            <div className="flex-1 flex flex-col min-h-0">
              <QueuedPromptsBar
                prompts={queuedPrompts}
                onSendNow={handleSendNow}
                onEdit={handleEditPrompt}
                onRemove={handleRemovePrompt}
              />
              <TerminalView
                ptyId={`term-${card.id}`}
                command={shellCommand}
                initialInput={terminalInput}
                onExit={() => {}}
                writeRef={terminalWriteRef}
                fontSize={terminalFontSize}
              />
            </div>
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
          <div className="overflow-y-auto flex-1 flex flex-col min-h-0">
            <HistoryTab
              turns={turns}
              transcriptPage={transcriptPage}
              loading={loadingTranscript}
              onLoadMore={() => {
                if (sessionId && transcriptPage?.hasMore)
                  loadTranscript(sessionId, transcriptPage.nextOffset, false);
              }}
              searchText={searchText}
              searchMatches={searchMatches}
              currentMatchIdx={currentMatchIdx}
              isSearching={isSearching}
              onSearchChange={setSearchText}
              onNextMatch={() => goToMatch("next")}
              onPrevMatch={() => goToMatch("prev")}
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
          <div className="overflow-y-auto flex-1 p-4">
            <div
              className="rounded-xl p-4"
              style={{ background: c.bgAccent("0.03") }}
            >
              <pre
                className="text-[13px] whitespace-pre-wrap break-words leading-[1.65] font-mono"
                style={{ color: c.textSecondary }}
              >
                {card.link.promptBody}
              </pre>
            </div>
          </div>
        )}
      </div>

      {/* Queued prompt dialog */}
      <QueuedPromptDialog
        open={showQueueDialog}
        onClose={() => { setShowQueueDialog(false); setEditingPrompt(null); }}
        onSave={editingPrompt ? handleUpdatePrompt : handleAddPrompt}
        editBody={editingPrompt?.body}
        editSendAuto={editingPrompt?.sendAutomatically}
      />
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

/* ── History Tab with Search ────────────────────────────────────── */

function HistoryTab({ turns, transcriptPage, loading, onLoadMore, searchText, searchMatches, currentMatchIdx, isSearching, onSearchChange, onNextMatch, onPrevMatch }: {
  turns: Turn[];
  transcriptPage: TranscriptPage | null;
  loading: boolean;
  onLoadMore: () => void;
  searchText: string;
  searchMatches: number[];
  currentMatchIdx: number;
  isSearching: boolean;
  onSearchChange: (q: string) => void;
  onNextMatch: () => void;
  onPrevMatch: () => void;
}) {
  const { theme } = useTheme();
  const c = t(theme);
  const currentMatchTurnIdx = searchMatches.length > 0 ? searchMatches[currentMatchIdx] : -1;
  const matchRef = useRef<HTMLDivElement>(null);

  // Scroll to current match
  useEffect(() => {
    if (matchRef.current) {
      matchRef.current.scrollIntoView({ behavior: "smooth", block: "center" });
    }
  }, [currentMatchIdx, searchMatches]);

  return (
    <>
      {/* Search bar */}
      <div
        className="shrink-0 flex items-center gap-2 px-3 py-2"
        style={{ background: "#141416", borderBottom: `1px solid rgba(255,255,255,0.04)` }}
      >
        <svg className="w-3.5 h-3.5 shrink-0" style={{ color: "#555" }} fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
          <path strokeLinecap="round" strokeLinejoin="round" d="m21 21-5.197-5.197m0 0A7.5 7.5 0 1 0 5.196 5.196a7.5 7.5 0 0 0 10.607 10.607Z" />
        </svg>
        <input
          type="text"
          value={searchText}
          onChange={(e) => onSearchChange(e.target.value)}
          placeholder="Search transcript..."
          className="flex-1 bg-transparent text-[12px] font-mono outline-none"
          style={{ color: "#e4e4e7" }}
          onKeyDown={(e) => {
            if (e.key === "Enter") {
              if (e.shiftKey) onPrevMatch();
              else onNextMatch();
            }
          }}
        />
        {searchText.length >= 2 && (
          <div className="flex items-center gap-1.5 shrink-0">
            {isSearching ? (
              <div className="w-3 h-3 border border-[#4f8ef7] border-t-transparent rounded-full animate-spin" />
            ) : (
              <span className="text-[11px] font-mono" style={{ color: "#666" }}>
                {searchMatches.length > 0
                  ? `${currentMatchIdx + 1}/${searchMatches.length}`
                  : "0 results"}
              </span>
            )}
            <button
              onClick={onPrevMatch}
              disabled={searchMatches.length === 0}
              className="p-0.5 rounded transition-colors disabled:opacity-30"
              style={{ color: "#888" }}
              title="Previous match (Shift+Enter)"
            >
              <svg className="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2.5}>
                <path strokeLinecap="round" strokeLinejoin="round" d="m4.5 15.75 7.5-7.5 7.5 7.5" />
              </svg>
            </button>
            <button
              onClick={onNextMatch}
              disabled={searchMatches.length === 0}
              className="p-0.5 rounded transition-colors disabled:opacity-30"
              style={{ color: "#888" }}
              title="Next match (Enter)"
            >
              <svg className="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2.5}>
                <path strokeLinecap="round" strokeLinejoin="round" d="m19.5 8.25-7.5 7.5-7.5-7.5" />
              </svg>
            </button>
            <button
              onClick={() => onSearchChange("")}
              className="p-0.5 rounded transition-colors"
              style={{ color: "#666" }}
              title="Clear search"
            >
              <svg className="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2.5}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M6 18 18 6M6 6l12 12" />
              </svg>
            </button>
          </div>
        )}
      </div>

      {/* Turns list */}
      {loading && turns.length === 0 ? (
        <div className="flex items-center justify-center p-12" style={{ background: "#141416" }}>
          <div className="w-5 h-5 border-2 border-[#4f8ef7] border-t-transparent rounded-full animate-spin" />
        </div>
      ) : turns.length === 0 ? (
        <div className="flex flex-col items-center justify-center p-12 gap-2" style={{ background: "#141416" }}>
          <svg className="w-8 h-8 text-[#555]" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1}>
            <path strokeLinecap="round" strokeLinejoin="round" d="M7.5 8.25h9m-9 3H12m-9.75 1.51c0 1.6 1.123 2.994 2.707 3.227 1.087.16 2.185.283 3.293.369V21l4.076-4.076a1.526 1.526 0 0 1 1.037-.443 48.2 48.2 0 0 0 5.887-.512c1.584-.233 2.707-1.626 2.707-3.228V6.741c0-1.602-1.123-2.995-2.707-3.228A48.394 48.394 0 0 0 12 3c-2.392 0-4.744.175-7.043.513C3.373 3.746 2.25 5.14 2.25 6.741v6.018Z" />
          </svg>
          <span className="text-[12px] text-[#555]">No conversation history</span>
        </div>
      ) : (
        <div
          className="flex flex-col px-3 pt-2 pb-3 gap-0.5 font-mono overflow-y-auto flex-1"
          style={{ background: "#141416" }}
        >
          {turns.map((turn) => {
            const isMatch = searchMatches.includes(turn.index);
            const isCurrent = turn.index === currentMatchTurnIdx;
            return (
              <div key={turn.index} ref={isCurrent ? matchRef : undefined}>
                <TurnItem
                  turn={turn}
                  searchQuery={searchText.length >= 2 ? searchText : ""}
                  isSearchMatch={isMatch}
                  isCurrentMatch={isCurrent}
                />
              </div>
            );
          })}
          {transcriptPage?.hasMore && (
            <button
              onClick={onLoadMore}
              disabled={loading}
              className="mt-2 py-2 rounded-lg text-[11px] font-mono font-medium transition-all duration-150 disabled:opacity-40"
              style={{ color: "#666", background: "rgba(255,255,255,0.03)" }}
              onMouseEnter={(e) => { e.currentTarget.style.background = "rgba(255,255,255,0.06)"; }}
              onMouseLeave={(e) => { e.currentTarget.style.background = "rgba(255,255,255,0.03)"; }}
            >
              {loading ? "Loading..." : `Load more (${transcriptPage.totalTurns - turns.length} remaining)`}
            </button>
          )}
        </div>
      )}
    </>
  );
}

/* ── Turn rendering with search highlighting ────────────────────── */

function TurnItem({ turn, searchQuery, isSearchMatch, isCurrentMatch }: {
  turn: Turn;
  searchQuery: string;
  isSearchMatch: boolean;
  isCurrentMatch: boolean;
}) {
  const isUser = turn.role === "user";
  const blocks = turn.contentBlocks;

  let borderStyle: string | undefined;
  if (isCurrentMatch) borderStyle = "rgba(249,115,22,0.5)";
  else if (isSearchMatch) borderStyle = "rgba(234,179,8,0.3)";

  return (
    <div
      className="rounded px-2 py-1 transition-colors duration-100"
      style={{
        background: isCurrentMatch
          ? "rgba(249,115,22,0.08)"
          : isSearchMatch
          ? "rgba(234,179,8,0.05)"
          : isUser && blocks.some(b => b.kind === "text")
          ? "rgba(255,255,255,0.04)"
          : undefined,
        outline: borderStyle ? `1px solid ${borderStyle}` : undefined,
      }}
      onMouseEnter={(e) => {
        if (!isCurrentMatch && !isSearchMatch) e.currentTarget.style.background = "rgba(255,255,255,0.06)";
      }}
      onMouseLeave={(e) => {
        if (!isCurrentMatch && !isSearchMatch) {
          e.currentTarget.style.background = isUser && blocks.some(b => b.kind === "text") ? "rgba(255,255,255,0.04)" : "";
        }
      }}
    >
      {blocks.length > 0 ? (
        blocks.map((block, i) => (
          <BlockLine key={i} block={block} isUser={isUser} isFirst={i === 0} searchQuery={searchQuery} />
        ))
      ) : (
        <div className="flex gap-1.5 items-start">
          <span className="text-[12px] leading-[1.6] shrink-0" style={{ color: isUser ? "#3fb950" : "#d4d4d4" }}>
            {isUser ? "\u276F" : "\u25CF"}
          </span>
          <span className="text-[12px] leading-[1.6] line-clamp-6" style={{ color: isUser ? "#e4e4e7" : "rgba(220,220,220,0.85)" }}>
            <HighlightedText text={turn.textPreview || "(empty)"} query={searchQuery} />
          </span>
        </div>
      )}
    </div>
  );
}

function BlockLine({ block, isUser, isFirst, searchQuery }: {
  block: { kind: string; text: string };
  isUser: boolean;
  isFirst: boolean;
  searchQuery: string;
}) {
  if (block.kind === "text") {
    const trimmed = block.text.trim();
    if (!trimmed) return null;
    return (
      <div className="flex gap-1.5 items-start">
        <span className="text-[12px] leading-[1.6] shrink-0" style={{ color: isUser ? "#3fb950" : "#d4d4d4" }}>
          {isFirst ? (isUser ? "\u276F" : "\u25CF") : "\u00A0\u00A0"}
        </span>
        <span
          className="text-[12px] leading-[1.6]"
          style={{
            color: isUser ? "#e4e4e7" : "rgba(220,220,220,0.85)",
            display: "-webkit-box",
            WebkitLineClamp: isUser ? undefined : 20,
            WebkitBoxOrient: "vertical",
            overflow: "hidden",
          }}
        >
          <HighlightedText text={trimmed} query={searchQuery} />
        </span>
      </div>
    );
  }

  if (block.kind === "tool_use") {
    const name = block.text.split("(")[0] || block.text;
    const args = block.text.includes("(") ? block.text.slice(block.text.indexOf("(")) : "";
    return (
      <div className="flex gap-1.5 items-start">
        <span className="text-[12px] leading-[1.6] shrink-0 text-[#3fb950]">{"\u00A0\u00A0\u25CF"}</span>
        <span className="text-[12px] leading-[1.6]">
          <span style={{ color: "rgba(63,185,80,0.8)" }}><HighlightedText text={name} query={searchQuery} /></span>
          {args && <span className="line-clamp-2" style={{ color: "#555" }}>{args}</span>}
        </span>
      </div>
    );
  }

  if (block.kind === "tool_result") {
    return (
      <div className="flex gap-1.5 items-start">
        <span className="text-[12px] leading-[1.6] shrink-0" style={{ color: "#444" }}>{"\u00A0\u00A0\u23BF"}</span>
        <span className="text-[12px] leading-[1.6] line-clamp-3" style={{ color: "#444" }}>
          <HighlightedText text={block.text} query={searchQuery} />
        </span>
      </div>
    );
  }

  if (block.kind === "thinking") {
    return (
      <div className="flex gap-1.5 items-start">
        <span className="text-[12px] leading-[1.6] shrink-0" style={{ color: "#444" }}>{"\u00A0\u00A0\u2234"}</span>
        <span className="text-[12px] leading-[1.6] italic" style={{ color: "#444" }}>Thinking...</span>
      </div>
    );
  }

  return null;
}

/* ── Search text highlighting ───────────────────────────────────── */

function HighlightedText({ text, query }: { text: string; query: string }) {
  if (!query || query.length < 2) return <>{text}</>;

  const lowerText = text.toLowerCase();
  const lowerQuery = query.toLowerCase();
  const parts: { text: string; highlight: boolean }[] = [];
  let lastIdx = 0;

  let idx = lowerText.indexOf(lowerQuery, lastIdx);
  while (idx !== -1) {
    if (idx > lastIdx) {
      parts.push({ text: text.slice(lastIdx, idx), highlight: false });
    }
    parts.push({ text: text.slice(idx, idx + query.length), highlight: true });
    lastIdx = idx + query.length;
    idx = lowerText.indexOf(lowerQuery, lastIdx);
  }

  if (lastIdx < text.length) {
    parts.push({ text: text.slice(lastIdx), highlight: false });
  }

  if (parts.length === 0) return <>{text}</>;

  return (
    <>
      {parts.map((part, i) =>
        part.highlight ? (
          <mark
            key={i}
            style={{
              background: "rgba(234,179,8,0.35)",
              color: "inherit",
              borderRadius: 2,
              padding: "0 1px",
            }}
          >
            {part.text}
          </mark>
        ) : (
          <span key={i}>{part.text}</span>
        )
      )}
    </>
  );
}

/* ── Content Tab (Issue / PR) ───────────────────────────────────── */

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
            className="shrink-0 p-1.5 rounded-lg transition-all duration-150"
            style={{ color: "#4f8ef7" }}
            onMouseEnter={(e) => { e.currentTarget.style.background = "rgba(79,142,247,0.08)"; }}
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
