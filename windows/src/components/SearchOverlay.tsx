import Fuse from "fuse.js";
import { useEffect, useMemo, useRef, useState } from "react";
import { searchSessions, useBoardStore } from "../store/boardStore";
import { useTheme, t } from "../theme";
import type { CardDto, Session } from "../types";

export default function SearchOverlay() {
  const { cards, setSearchOpen, selectCard } = useBoardStore();
  const { theme } = useTheme();
  const c = t(theme);
  const [query, setQuery] = useState("");
  const [selectedIndex, setSelectedIndex] = useState(0);
  const inputRef = useRef<HTMLInputElement>(null);
  // Deep search state — populated by Enter / button; cleared as the user types.
  const [deepResults, setDeepResults] = useState<Session[] | null>(null);
  const [deepLoading, setDeepLoading] = useState(false);

  useEffect(() => { inputRef.current?.focus(); }, []);

  const fuse = useMemo(
    () => new Fuse(cards, {
      keys: [
        { name: "displayTitle", weight: 0.5 },
        { name: "link.promptBody", weight: 0.3 },
        { name: "projectName", weight: 0.1 },
        { name: "link.sessionLink.sessionId", weight: 0.1 },
      ],
      threshold: 0.4,
      includeScore: true,
    }),
    [cards]
  );

  const results: CardDto[] = useMemo(() => {
    if (!query.trim()) {
      return [...cards]
        .sort((a, b) => {
          const ta = a.link.lastActivity ?? a.link.updatedAt;
          const tb = b.link.lastActivity ?? b.link.updatedAt;
          return tb.localeCompare(ta);
        })
        .slice(0, 15);
    }
    return fuse.search(query).map((r) => r.item).slice(0, 15);
  }, [query, fuse, cards]);

  useEffect(() => { setSelectedIndex(0); setDeepResults(null); }, [query]);

  const handleSelect = (card: CardDto) => {
    selectCard(card.id);
    setSearchOpen(false);
  };

  const handleSelectSession = (session: Session) => {
    // Prefer the existing card if a session is already represented on the
    // board; otherwise fall through to selecting the (likely) all-sessions
    // card by id. cards is keyed by Link.id, not session id, so we match on
    // sessionLink.sessionId.
    const card = cards.find((c) => c.link.sessionLink?.sessionId === session.id);
    if (card) {
      selectCard(card.id);
    }
    setSearchOpen(false);
  };

  const runDeepSearch = async () => {
    const q = query.trim();
    if (!q || deepLoading) return;
    setDeepLoading(true);
    try {
      const hits = await searchSessions(q);
      setDeepResults(hits);
      setSelectedIndex(0);
    } catch {
      setDeepResults([]);
    } finally {
      setDeepLoading(false);
    }
  };

  const handleKeyDown = (e: React.KeyboardEvent) => {
    const list = deepResults ?? results;
    if (e.key === "ArrowDown") {
      e.preventDefault();
      setSelectedIndex((i) => Math.min(i + 1, list.length - 1));
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      setSelectedIndex((i) => Math.max(i - 1, 0));
    } else if (e.key === "Enter") {
      // First Enter: deep search. Second Enter (or Enter with deep results
      // already showing): select the current row.
      if (!deepResults && query.trim()) {
        e.preventDefault();
        runDeepSearch();
        return;
      }
      if (deepResults) {
        const session = deepResults[selectedIndex];
        if (session) handleSelectSession(session);
      } else if (results[selectedIndex]) {
        handleSelect(results[selectedIndex]);
      }
    }
  };

  return (
    <div
      className="fixed inset-0 z-50 flex items-start justify-center pt-[15vh] animate-fade-in"
      style={{ background: c.bgOverlay }}
      onClick={() => setSearchOpen(false)}
    >
      <div
        className="w-[520px] rounded-xl shadow-2xl overflow-hidden animate-slide-up"
        style={{
          background: c.bgDialog,
          border: `1px solid ${c.borderBright}`,
        }}
        onClick={(e) => e.stopPropagation()}
        onKeyDown={handleKeyDown}
      >
        <div
          className="flex items-center gap-3 px-4 py-3"
          style={{ borderBottom: `1px solid ${c.border}` }}
        >
          <svg
            className="w-5 h-5 shrink-0"
            style={{ color: c.textMuted }}
            fill="none"
            viewBox="0 0 24 24"
            stroke="currentColor"
            strokeWidth={2}
          >
            <path strokeLinecap="round" strokeLinejoin="round" d="m21 21-4.35-4.35M17 11A6 6 0 1 1 5 11a6 6 0 0 1 12 0z" />
          </svg>
          <input
            ref={inputRef}
            type="text"
            placeholder="Search sessions, tasks, projects..."
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            className="flex-1 bg-transparent text-[14px] outline-none"
            style={{ color: c.textPrimary }}
          />
          <kbd
            className="text-[11px] px-1.5 py-0.5 rounded font-mono"
            style={{
              background: c.bgAccent("0.05"),
              border: `1px solid ${c.border}`,
              color: c.textDim,
            }}
          >
            ESC
          </kbd>
        </div>

        {deepResults !== null && (
          <div
            className="px-4 py-1.5 flex items-center gap-2 text-[11px]"
            style={{ background: c.bgAccent("0.03"), borderBottom: `1px solid ${c.border}`, color: c.textMuted }}
          >
            <svg className="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
              <path strokeLinecap="round" strokeLinejoin="round" d="m21 21-4.35-4.35M17 11A6 6 0 1 1 5 11a6 6 0 0 1 12 0z" />
            </svg>
            <span>Deep transcript search · BM25 ranked by relevance</span>
            <button
              onClick={() => setDeepResults(null)}
              className="ml-auto px-1.5 rounded hover:underline"
              style={{ color: c.textSecondary }}
            >
              clear
            </button>
          </div>
        )}

        <div className="overflow-y-auto max-h-[380px]">
          {deepLoading && (
            <div className="px-4 py-8 text-center flex items-center justify-center gap-2" style={{ color: c.textMuted }}>
              <div className="w-3 h-3 border border-[#4f8ef7] border-t-transparent rounded-full animate-spin" />
              <span className="text-[13px]">Scanning all sessions…</span>
            </div>
          )}

          {!deepLoading && deepResults !== null && deepResults.length === 0 && (
            <div className="px-4 py-8 text-center text-[14px]" style={{ color: c.textMuted }}>
              No transcript matches for "{query}"
            </div>
          )}

          {!deepLoading && deepResults !== null && deepResults.map((session, i) => {
            const isHighlighted = i === selectedIndex;
            const matchingCard = cards.find((c) => c.link.sessionLink?.sessionId === session.id);
            return (
              <button
                key={session.id}
                onClick={() => handleSelectSession(session)}
                className="w-full text-left flex items-start gap-3 px-4 py-3 transition-colors"
                style={{
                  background: isHighlighted ? c.bgCardSelected : "transparent",
                  borderBottom: i === deepResults.length - 1 ? "none" : `1px solid ${c.border}`,
                }}
                onMouseEnter={(e) => { if (!isHighlighted) e.currentTarget.style.background = c.hoverBg; }}
                onMouseLeave={(e) => { if (!isHighlighted) e.currentTarget.style.background = "transparent"; }}
              >
                <div className="flex-1 min-w-0">
                  <p className="text-[14px] truncate" style={{ color: c.textPrimary }}>
                    {matchingCard?.displayTitle ?? session.firstPrompt ?? session.id}
                  </p>
                  <div className="flex items-center gap-2 mt-0.5">
                    {session.projectPath && (
                      <span className="text-[12px] truncate" style={{ color: c.textMuted }}>
                        {session.projectPath.split(/[/\\]/).pop() ?? session.projectPath}
                      </span>
                    )}
                    {session.gitBranch && (
                      <span className="text-[12px] text-[#4f8ef7]">{session.gitBranch}</span>
                    )}
                    <span className="text-[11px] font-mono" style={{ color: c.textDim }}>
                      {session.messageCount} msg
                    </span>
                  </div>
                </div>
              </button>
            );
          })}

          {deepResults === null && results.length === 0 && query && (
            <div className="px-4 py-8 text-center text-[14px]" style={{ color: c.textMuted }}>
              No board matches for "{query}". Press <kbd className="px-1 rounded font-mono text-[10px]" style={{ background: c.bgAccent("0.06"), color: c.textSecondary }}>Enter</kbd> to search transcripts.
            </div>
          )}

          {deepResults === null && results.map((card, i) => {
            const isHighlighted = i === selectedIndex;
            return (
              <button
                key={card.id}
                onClick={() => handleSelect(card)}
                className="w-full text-left flex items-start gap-3 px-4 py-3 transition-colors"
                style={{
                  background: isHighlighted ? c.bgCardSelected : "transparent",
                  borderBottom: i === results.length - 1 ? "none" : `1px solid ${c.border}`,
                }}
                onMouseEnter={(e) => {
                  if (!isHighlighted) e.currentTarget.style.background = c.hoverBg;
                }}
                onMouseLeave={(e) => {
                  if (!isHighlighted) e.currentTarget.style.background = "transparent";
                }}
              >
                <div className="flex-1 min-w-0">
                  <p className="text-[14px] truncate" style={{ color: c.textPrimary }}>{card.displayTitle}</p>
                  <div className="flex items-center gap-2 mt-0.5">
                    {card.projectName && (
                      <span className="text-[12px]" style={{ color: c.textMuted }}>{card.projectName}</span>
                    )}
                    {card.link.worktreeLink?.branch && (
                      <span className="text-[12px] text-[#4f8ef7]">{card.link.worktreeLink.branch}</span>
                    )}
                    {card.link.prLinks[0] && (
                      <span className="text-[12px] text-[#3fb950]">PR #{card.link.prLinks[0].number}</span>
                    )}
                  </div>
                </div>
                <span className="text-[11px] shrink-0 mt-0.5" style={{ color: c.textDim }}>{card.relativeTime}</span>
              </button>
            );
          })}
        </div>

        <div
          className="px-4 py-2 flex items-center gap-4 text-[11px]"
          style={{ borderTop: `1px solid ${c.border}`, color: c.textDim }}
        >
          <span>↑↓ navigate</span>
          <span>↵ {deepResults ? "select" : query.trim() ? "deep search" : "select"}</span>
          <span>ESC close</span>
          {(deepResults ?? results).length > 0 && (
            <span className="ml-auto">{(deepResults ?? results).length} results</span>
          )}
        </div>
      </div>
    </div>
  );
}
