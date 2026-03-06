import Fuse from "fuse.js";
import { useEffect, useMemo, useRef, useState } from "react";
import { useBoardStore } from "../store/boardStore";
import type { CardDto } from "../types";

export default function SearchOverlay() {
  const { cards, setSearchOpen, selectCard } = useBoardStore();
  const [query, setQuery] = useState("");
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    inputRef.current?.focus();
  }, []);

  const fuse = useMemo(
    () =>
      new Fuse(cards, {
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

  const handleSelect = (card: CardDto) => {
    selectCard(card.id);
    setSearchOpen(false);
  };

  return (
    <div
      className="fixed inset-0 z-50 flex items-start justify-center pt-[15vh]"
      onClick={() => setSearchOpen(false)}
    >
      <div
        className="w-[560px] bg-[#141417] border border-[#3a3a44] rounded-xl shadow-2xl overflow-hidden"
        onClick={(e) => e.stopPropagation()}
      >
        {/* Search input */}
        <div className="flex items-center gap-2 px-4 py-3 border-b border-[#2a2a32]">
          <svg
            className="w-4 h-4 text-zinc-500 shrink-0"
            fill="none"
            viewBox="0 0 24 24"
            stroke="currentColor"
            strokeWidth={2}
          >
            <path
              strokeLinecap="round"
              strokeLinejoin="round"
              d="m21 21-4.35-4.35M17 11A6 6 0 1 1 5 11a6 6 0 0 1 12 0z"
            />
          </svg>
          <input
            ref={inputRef}
            type="text"
            placeholder="Search sessions, tasks, projects..."
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            className="flex-1 bg-transparent text-sm text-zinc-200 placeholder-zinc-600 outline-none"
          />
          <kbd className="text-[10px] text-zinc-600 bg-[#1c1c21] border border-[#2a2a32] px-1.5 py-0.5 rounded">
            ESC
          </kbd>
        </div>

        {/* Results */}
        <div className="overflow-y-auto max-h-[400px]">
          {results.length === 0 && query && (
            <div className="px-4 py-6 text-center text-sm text-zinc-500">
              No results for "{query}"
            </div>
          )}
          {results.map((card) => (
            <SearchResultItem
              key={card.id}
              card={card}
              onSelect={() => handleSelect(card)}
            />
          ))}
        </div>

        {/* Footer */}
        <div className="px-4 py-2 border-t border-[#1c1c21] flex items-center gap-3 text-[10px] text-zinc-600">
          <span>↵ select</span>
          <span>ESC close</span>
          {results.length > 0 && <span>{results.length} results</span>}
        </div>
      </div>
    </div>
  );
}

function SearchResultItem({
  card,
  onSelect,
}: {
  card: CardDto;
  onSelect: () => void;
}) {
  const branch = card.link.worktreeLink?.branch;
  const pr = card.link.prLinks[0];

  return (
    <button
      onClick={onSelect}
      className="w-full text-left flex items-start gap-3 px-4 py-2.5 hover:bg-[#1c1c21] transition-colors border-b border-[#1c1c21] last:border-0"
    >
      <div className="flex-1 min-w-0">
        <p className="text-sm text-zinc-200 truncate">{card.displayTitle}</p>
        <div className="flex items-center gap-2 mt-0.5">
          {card.projectName && (
            <span className="text-[11px] text-zinc-500">{card.projectName}</span>
          )}
          {branch && (
            <span className="text-[11px] text-[#4f8ef7]">{branch}</span>
          )}
          {pr && (
            <span className="text-[11px] text-[#3fb950]">PR #{pr.number}</span>
          )}
        </div>
      </div>
      <span className="text-[10px] text-zinc-600 shrink-0 mt-0.5">
        {card.relativeTime}
      </span>
    </button>
  );
}
