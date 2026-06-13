import Fuse from "fuse.js";
import { useEffect, useMemo, useRef, useState } from "react";
import { useBoardStore } from "../store/boardStore";
import { useTheme, t } from "../theme";
import type { CardDto } from "../types";

export default function SearchOverlay() {
  const { cards, setSearchOpen, selectCard } = useBoardStore();
  const { theme } = useTheme();
  const c = t(theme);
  const [query, setQuery] = useState("");
  const [selectedIndex, setSelectedIndex] = useState(0);
  const inputRef = useRef<HTMLInputElement>(null);

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

  useEffect(() => { setSelectedIndex(0); }, [query]);

  const handleSelect = (card: CardDto) => {
    selectCard(card.id);
    setSearchOpen(false);
  };

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === "ArrowDown") {
      e.preventDefault();
      setSelectedIndex((i) => Math.min(i + 1, results.length - 1));
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      setSelectedIndex((i) => Math.max(i - 1, 0));
    } else if (e.key === "Enter" && results[selectedIndex]) {
      handleSelect(results[selectedIndex]);
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

        <div className="overflow-y-auto max-h-[380px]">
          {results.length === 0 && query && (
            <div
              className="px-4 py-8 text-center text-[14px]"
              style={{ color: c.textMuted }}
            >
              No results for "{query}"
            </div>
          )}
          {results.map((card, i) => {
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
          <span>↵ select</span>
          <span>ESC close</span>
          {results.length > 0 && <span className="ml-auto">{results.length} results</span>}
        </div>
      </div>
    </div>
  );
}
