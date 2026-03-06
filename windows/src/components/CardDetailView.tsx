import { useEffect, useState } from "react";
import {
  getTranscript,
  launchSession,
  openInEditor,
  useBoardStore,
} from "../store/boardStore";
import type { Turn, TranscriptPage } from "../types";

type Tab = "history" | "issue" | "pr" | "prompt";

export default function CardDetailView() {
  const { selectedCard, selectCard, renameCard } = useBoardStore();
  const card = selectedCard();

  const [activeTab, setActiveTab] = useState<Tab>("history");
  const [turns, setTurns] = useState<Turn[]>([]);
  const [transcriptPage, setTranscriptPage] = useState<TranscriptPage | null>(null);
  const [loadingTranscript, setLoadingTranscript] = useState(false);
  const [isEditing, setIsEditing] = useState(false);
  const [editName, setEditName] = useState("");

  useEffect(() => {
    if (!card) return;
    setActiveTab("history");
    setTurns([]);
    setTranscriptPage(null);
    if (card.link.sessionLink?.sessionId) {
      loadTranscript(card.link.sessionLink.sessionId, 0, true);
    }
  }, [card?.id]);

  const loadTranscript = async (
    sessionId: string,
    offset: number,
    reset: boolean
  ) => {
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
    if (editName.trim()) {
      renameCard(card.id, editName.trim());
    }
    setIsEditing(false);
  };

  return (
    <div className="w-[380px] min-w-[380px] flex flex-col border-l border-[#2a2a32] bg-[#0f0f12] overflow-hidden">
      {/* Header */}
      <div className="px-4 pt-3 pb-2 border-b border-[#2a2a32] shrink-0">
        <div className="flex items-start justify-between gap-2">
          {isEditing ? (
            <input
              autoFocus
              className="flex-1 bg-[#1c1c21] border border-[#4f8ef7]/40 rounded px-2 py-1 text-sm text-zinc-200 outline-none"
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
              className="flex-1 text-sm font-medium text-zinc-200 leading-snug cursor-text"
              onClick={() => {
                setEditName(card.displayTitle);
                setIsEditing(true);
              }}
              title="Click to rename"
            >
              {card.displayTitle}
            </h2>
          )}
          <button
            onClick={() => selectCard(null)}
            className="text-zinc-500 hover:text-zinc-300 mt-0.5 shrink-0"
          >
            <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M6 18 18 6M6 6l12 12" />
            </svg>
          </button>
        </div>

        {/* Project + branch */}
        <div className="flex flex-wrap gap-1.5 mt-2">
          {card.projectName && (
            <span className="text-[11px] text-zinc-500">{card.projectName}</span>
          )}
          {branch && (
            <span className="text-[11px] text-[#4f8ef7] bg-[#4f8ef7]/10 px-1.5 py-0.5 rounded">
              {branch}
            </span>
          )}
          {pr && (
            <span className="text-[11px] text-[#3fb950] bg-[#3fb950]/10 px-1.5 py-0.5 rounded">
              PR #{pr.number}
            </span>
          )}
          {issue && (
            <span className="text-[11px] text-[#d29922] bg-[#d29922]/10 px-1.5 py-0.5 rounded">
              #{issue.number}
            </span>
          )}
        </div>

        {/* Action buttons */}
        <div className="flex gap-2 mt-3">
          {sessionId && (
            <>
              <button
                onClick={() => launchSession(sessionId)}
                className="flex-1 flex items-center justify-center gap-1.5 py-1.5 rounded-md bg-[#4f8ef7] hover:bg-[#5b97fa] text-white text-xs font-medium transition-colors"
              >
                <svg className="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                  <path strokeLinecap="round" strokeLinejoin="round" d="M5 3 19 12 5 21V3z" />
                </svg>
                Resume
              </button>
            </>
          )}
          {projectPath && (
            <button
              onClick={() => openInEditor(projectPath)}
              className="flex-1 flex items-center justify-center gap-1.5 py-1.5 rounded-md bg-[#1c1c21] hover:bg-[#242429] border border-[#2a2a32] text-zinc-300 text-xs transition-colors"
            >
              <svg className="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                <path strokeLinecap="round" strokeLinejoin="round" d="m10 20-7-7 7-7M17 20l7-7-7-7" />
              </svg>
              Editor
            </button>
          )}
        </div>
      </div>

      {/* Tabs */}
      <div className="flex border-b border-[#2a2a32] shrink-0">
        {(["history", "issue", "pr", "prompt"] as Tab[]).map((tab) => {
          const disabled =
            (tab === "issue" && !issue) ||
            (tab === "pr" && !pr) ||
            (tab === "prompt" && !card.link.promptBody) ||
            (tab === "history" && !sessionId);
          return (
            <button
              key={tab}
              disabled={disabled}
              onClick={() => setActiveTab(tab)}
              className={`flex-1 py-2 text-[11px] font-medium capitalize transition-colors ${
                activeTab === tab
                  ? "text-[#4f8ef7] border-b-2 border-[#4f8ef7]"
                  : disabled
                  ? "text-zinc-700 cursor-not-allowed"
                  : "text-zinc-500 hover:text-zinc-300"
              }`}
            >
              {tab}
            </button>
          );
        })}
      </div>

      {/* Tab content */}
      <div className="flex-1 overflow-y-auto">
        {activeTab === "history" && (
          <HistoryTab
            turns={turns}
            transcriptPage={transcriptPage}
            loading={loadingTranscript}
            onLoadMore={() => {
              if (sessionId && transcriptPage?.hasMore) {
                loadTranscript(sessionId, transcriptPage.nextOffset, false);
              }
            }}
          />
        )}
        {activeTab === "issue" && issue && (
          <ContentTab
            title={issue.title ?? `Issue #${issue.number}`}
            body={issue.body}
            url={issue.url}
          />
        )}
        {activeTab === "pr" && pr && (
          <ContentTab
            title={pr.title ?? `PR #${pr.number}`}
            body={pr.body}
            url={pr.url}
          />
        )}
        {activeTab === "prompt" && card.link.promptBody && (
          <div className="p-4">
            <pre className="text-xs text-zinc-300 whitespace-pre-wrap break-words leading-relaxed font-mono">
              {card.link.promptBody}
            </pre>
          </div>
        )}
      </div>
    </div>
  );
}

function HistoryTab({
  turns,
  transcriptPage,
  loading,
  onLoadMore,
}: {
  turns: Turn[];
  transcriptPage: TranscriptPage | null;
  loading: boolean;
  onLoadMore: () => void;
}) {
  if (loading && turns.length === 0) {
    return (
      <div className="flex items-center justify-center p-8 text-xs text-zinc-500">
        Loading...
      </div>
    );
  }

  if (turns.length === 0) {
    return (
      <div className="flex items-center justify-center p-8 text-xs text-zinc-500">
        No history yet
      </div>
    );
  }

  return (
    <div className="flex flex-col">
      {turns.map((turn) => (
        <TurnItem key={turn.index} turn={turn} />
      ))}
      {transcriptPage?.hasMore && (
        <button
          onClick={onLoadMore}
          disabled={loading}
          className="m-3 py-2 rounded-lg border border-[#2a2a32] text-xs text-zinc-400 hover:text-zinc-200 hover:border-[#3a3a44] transition-colors disabled:opacity-50"
        >
          {loading ? "Loading..." : `Load more (${transcriptPage.totalTurns - turns.length} remaining)`}
        </button>
      )}
    </div>
  );
}

function TurnItem({ turn }: { turn: Turn }) {
  const isUser = turn.role === "user";
  return (
    <div className={`px-3 py-2.5 border-b border-[#1c1c21] ${isUser ? "" : "bg-[#0d0d0f]/40"}`}>
      <div className="flex items-center gap-1.5 mb-1">
        <span
          className={`text-[10px] font-semibold uppercase ${isUser ? "text-[#4f8ef7]" : "text-[#3fb950]"}`}
        >
          {isUser ? "You" : "Claude"}
        </span>
        {turn.timestamp && (
          <span className="text-[10px] text-zinc-600">
            {new Date(turn.timestamp).toLocaleTimeString([], {
              hour: "2-digit",
              minute: "2-digit",
            })}
          </span>
        )}
      </div>
      <p className="text-xs text-zinc-400 leading-relaxed line-clamp-4">
        {turn.textPreview || "(tool use)"}
      </p>
    </div>
  );
}

function ContentTab({
  title,
  body,
  url,
}: {
  title: string;
  body?: string;
  url?: string;
}) {
  return (
    <div className="p-4 flex flex-col gap-3">
      <div className="flex items-start justify-between gap-2">
        <h3 className="text-sm font-medium text-zinc-200 leading-snug">{title}</h3>
        {url && (
          <a
            href={url}
            target="_blank"
            rel="noreferrer"
            className="text-[#4f8ef7] shrink-0"
          >
            <svg className="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M10 6H6a2 2 0 0 0-2 2v10a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-4M14 4h6m0 0v6m0-6L10 14" />
            </svg>
          </a>
        )}
      </div>
      {body ? (
        <pre className="text-xs text-zinc-400 whitespace-pre-wrap break-words leading-relaxed font-sans">
          {body}
        </pre>
      ) : (
        <p className="text-xs text-zinc-600">No description</p>
      )}
    </div>
  );
}
