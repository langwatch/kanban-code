import { useEffect, useState } from "react";
import {
  getTranscript,
  openInEditor,
  useBoardStore,
} from "../store/boardStore";
import { useTheme, t } from "../theme";
import type { Turn, TranscriptPage } from "../types";
import TerminalView from "./Terminal";

type Tab = "terminal" | "history" | "issue" | "pr" | "prompt";

export default function CardDetailView() {
  const { selectedCard, selectCard, renameCard } = useBoardStore();
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

  // Just spawn an interactive WSL shell — it handles PATH/profile naturally
  const shellCommand = ["wsl.exe"];
  // Send the resume command after the shell is ready
  const resumeInput = `claude --resume ${sessionId}\r`;

  const handleStartTerminal = () => {
    setTerminalActive(true);
    setActiveTab("terminal");
  };

  return (
    <div
      className="w-[420px] min-w-[420px] flex flex-col overflow-hidden"
      style={{
        background: c.bgDetail,
        borderLeft: `1px solid ${c.border}`,
      }}
    >
      {/* Header */}
      <div className="px-4 pt-4 pb-3 shrink-0" style={{ borderBottom: `1px solid ${c.border}` }}>
        <div className="flex items-start justify-between gap-2">
          {isEditing ? (
            <input
              autoFocus
              className="flex-1 rounded-lg px-3 py-1.5 text-[14px] outline-none"
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
              className="flex-1 text-[15px] font-semibold leading-snug cursor-text hover:opacity-80 transition-opacity"
              style={{ color: c.textPrimary }}
              onClick={() => { setEditName(card.displayTitle); setIsEditing(true); }}
              title="Click to rename this card"
            >
              {card.displayTitle}
            </h2>
          )}
          <button
            onClick={() => selectCard(null)}
            className="btn-icon mt-0.5 shrink-0"
            style={{ color: c.textMuted }}
            title="Close detail panel"
          >
            <svg className="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M6 18 18 6M6 6l12 12" />
            </svg>
          </button>
        </div>

        {/* Meta badges */}
        <div className="flex flex-wrap gap-1.5 mt-2.5">
          {card.projectName && <span className="badge-hover text-[12px] cursor-default" style={{ color: c.textMuted }} title={projectPath ?? ""}>{card.projectName}</span>}
          {branch && <span className="badge-hover text-[12px] text-[#4f8ef7] bg-[#4f8ef7]/10 px-2 py-0.5 rounded cursor-default" title={`Branch: ${branch}`}>{branch}</span>}
          {pr && <span className="badge-hover text-[12px] text-[#3fb950] bg-[#3fb950]/10 px-2 py-0.5 rounded cursor-default" title={pr.title ?? `Pull Request #${pr.number}`}>PR #{pr.number}</span>}
          {issue && <span className="badge-hover text-[12px] text-[#d29922] bg-[#d29922]/10 px-2 py-0.5 rounded cursor-default" title={issue.title ?? `Issue #${issue.number}`}>#{issue.number}</span>}
        </div>

        {/* Action buttons */}
        <div className="flex gap-2 mt-3">
          {sessionId && (
            <button
              onClick={handleStartTerminal}
              className="btn-action flex-1 flex items-center justify-center gap-2 py-2 rounded-lg bg-[#4f8ef7] text-white text-[13px] font-semibold"
              title={terminalActive ? "Switch to terminal view" : "Resume this Claude session in an embedded terminal"}
            >
              <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M6.75 7.5l3 2.25-3 2.25m4.5 0h3m-9 8.25h13.5A2.25 2.25 0 0021 18V6a2.25 2.25 0 00-2.25-2.25H5.25A2.25 2.25 0 003 6v12a2.25 2.25 0 002.25 2.25z" />
              </svg>
              {terminalActive ? "Terminal" : "Resume in Terminal"}
            </button>
          )}
          {projectPath && (
            <button
              onClick={() => openInEditor(projectPath)}
              className="btn-secondary flex-1 flex items-center justify-center gap-2 py-2 rounded-lg text-[13px]"
              style={{ border: `1px solid ${c.border}`, color: c.textSecondary }}
              title={`Open in Cursor: ${projectPath}`}
            >
              <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                <path strokeLinecap="round" strokeLinejoin="round" d="m10 20-7-7 7-7M17 20l7-7-7-7" />
              </svg>
              Open in Cursor
            </button>
          )}
        </div>
      </div>

      {/* Tabs */}
      <div className="flex shrink-0" style={{ borderBottom: `1px solid ${c.border}` }}>
        {(["terminal", "history", "issue", "pr", "prompt"] as Tab[]).map((tab) => {
          const disabled =
            (tab === "terminal" && !sessionId) ||
            (tab === "issue" && !issue) ||
            (tab === "pr" && !pr) ||
            (tab === "prompt" && !card.link.promptBody) ||
            (tab === "history" && !sessionId);
          return (
            <button
              key={tab}
              disabled={disabled}
              onClick={() => setActiveTab(tab)}
              className="tab-item flex-1 py-2.5 text-[12px] font-medium capitalize"
              style={{
                color: activeTab === tab ? "#4f8ef7" : disabled ? c.textDim : c.textMuted,
                borderBottom: activeTab === tab ? "2px solid #4f8ef7" : "2px solid transparent",
                cursor: disabled ? "not-allowed" : "pointer",
              }}
              title={disabled ? `No ${tab} data available` : `View ${tab}`}
            >
              {tab}
            </button>
          );
        })}
      </div>

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
            <div className="flex flex-col items-center justify-center flex-1 gap-3 p-6">
              <svg className="w-10 h-10" style={{ color: c.textDim }} fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M6.75 7.5l3 2.25-3 2.25m4.5 0h3m-9 8.25h13.5A2.25 2.25 0 0021 18V6a2.25 2.25 0 00-2.25-2.25H5.25A2.25 2.25 0 003 6v12a2.25 2.25 0 002.25 2.25z" />
              </svg>
              <p className="text-[13px]" style={{ color: c.textMuted }}>
                Click "Resume in Terminal" to start an interactive session
              </p>
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
          <div className="overflow-y-auto flex-1 p-4">
            <pre
              className="text-[13px] whitespace-pre-wrap break-words leading-relaxed font-mono rounded-lg p-3"
              style={{
                color: c.textSecondary,
                background: c.bgAccent("0.02"),
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

function HistoryTab({ turns, transcriptPage, loading, onLoadMore }: {
  turns: Turn[]; transcriptPage: TranscriptPage | null; loading: boolean; onLoadMore: () => void;
}) {
  const { theme } = useTheme();
  const c = t(theme);

  if (loading && turns.length === 0) {
    return (
      <div className="flex items-center justify-center p-8">
        <div className="flex items-center gap-2">
          <div className="w-4 h-4 border-2 border-[#4f8ef7] border-t-transparent rounded-full animate-spin" />
          <span className="text-[13px]" style={{ color: c.textMuted }}>Loading...</span>
        </div>
      </div>
    );
  }

  if (turns.length === 0) {
    return (
      <div className="flex items-center justify-center p-8 text-[13px]" style={{ color: c.textDim }}>
        No history yet
      </div>
    );
  }

  return (
    <div className="flex flex-col">
      {turns.map((turn) => <TurnItem key={turn.index} turn={turn} />)}
      {transcriptPage?.hasMore && (
        <button
          onClick={onLoadMore}
          disabled={loading}
          className="btn-secondary m-3 py-2 rounded-lg text-[12px] disabled:opacity-50"
          style={{ border: `1px solid ${c.border}`, color: c.textMuted }}
          title="Load older conversation turns"
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
    <div className="px-4 py-3" style={{ borderBottom: `1px solid ${c.bgAccent("0.03")}` }}>
      <div className="flex items-center gap-1.5 mb-1">
        <span className={`text-[11px] font-bold uppercase ${isUser ? "text-[#4f8ef7]" : "text-[#3fb950]"}`}>
          {isUser ? "You" : "Claude"}
        </span>
        {turn.timestamp && (
          <span className="text-[11px]" style={{ color: c.textDim }}>
            {new Date(turn.timestamp).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}
          </span>
        )}
      </div>
      <p className="text-[13px] leading-relaxed line-clamp-4" style={{ color: c.textSecondary }}>
        {turn.textPreview || "(tool use)"}
      </p>
    </div>
  );
}

function ContentTab({ title, body, url }: { title: string; body?: string; url?: string }) {
  const { theme } = useTheme();
  const c = t(theme);
  return (
    <div className="p-4 flex flex-col gap-3">
      <div className="flex items-start justify-between gap-2">
        <h3 className="text-[14px] font-semibold leading-snug" style={{ color: c.textPrimary }}>{title}</h3>
        {url && (
          <a href={url} target="_blank" rel="noreferrer" className="text-[#4f8ef7] shrink-0">
            <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M10 6H6a2 2 0 0 0-2 2v10a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-4M14 4h6m0 0v6m0-6L10 14" />
            </svg>
          </a>
        )}
      </div>
      {body ? (
        <pre className="text-[13px] whitespace-pre-wrap break-words leading-relaxed font-sans" style={{ color: c.textSecondary }}>
          {body}
        </pre>
      ) : (
        <p className="text-[13px]" style={{ color: c.textDim }}>No description</p>
      )}
    </div>
  );
}
