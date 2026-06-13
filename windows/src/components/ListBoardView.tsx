import { useState } from "react";
import { useBoardStore } from "../store/boardStore";
import { COLUMNS, COLUMN_DISPLAY, type CardDto, type KanbanColumn } from "../types";
import { useTheme, t } from "../theme";

const COLLAPSE_STORAGE_KEY = "kanban.listCollapsedColumns";

function loadCollapsed(): Set<KanbanColumn> {
  if (typeof window === "undefined") return new Set();
  const raw = window.localStorage.getItem(COLLAPSE_STORAGE_KEY);
  if (!raw) return new Set();
  try {
    const arr = JSON.parse(raw) as KanbanColumn[];
    return new Set(arr);
  } catch {
    return new Set();
  }
}

function saveCollapsed(s: Set<KanbanColumn>) {
  window.localStorage.setItem(
    COLLAPSE_STORAGE_KEY,
    JSON.stringify(Array.from(s))
  );
}

const COLUMN_ACCENT: Record<KanbanColumn, string> = {
  backlog: "#8b8b8b",
  in_progress: "#3fb950",
  requires_attention: "#d29922",
  in_review: "#4f8ef7",
  done: "#a371f7",
  all_sessions: "#6b7280",
};

export default function ListBoardView() {
  const { cardsInColumn, selectedCardId, selectCard } = useBoardStore();
  const [collapsed, setCollapsed] = useState<Set<KanbanColumn>>(loadCollapsed);
  const { theme } = useTheme();
  const c = t(theme);

  const toggle = (col: KanbanColumn) => {
    setCollapsed((prev) => {
      const next = new Set(prev);
      if (next.has(col)) next.delete(col);
      else next.add(col);
      saveCollapsed(next);
      return next;
    });
  };

  return (
    <div className="flex-1 overflow-y-auto px-3 py-2" style={{ background: c.bg }}>
      {COLUMNS.map((col) => {
        const cards = cardsInColumn(col);
        const isCollapsed = collapsed.has(col);
        return (
          <div key={col} className="mb-3">
            <button
              onClick={() => toggle(col)}
              className="w-full flex items-center gap-2 px-3 py-2 rounded-lg transition-colors"
              style={{
                background: c.bgHeader,
                border: `1px solid ${c.border}`,
                color: c.textPrimary,
              }}
              onMouseEnter={(e) => { e.currentTarget.style.background = c.hoverBg; }}
              onMouseLeave={(e) => { e.currentTarget.style.background = c.bgHeader; }}
            >
              <span
                className="inline-block w-2 h-2 rounded-full"
                style={{ background: COLUMN_ACCENT[col] }}
              />
              <span className="text-[13px] font-semibold">{COLUMN_DISPLAY[col]}</span>
              <span
                className="ml-1 px-1.5 py-0.5 rounded text-[11px] font-medium"
                style={{ background: c.bgAccent("0.08"), color: c.textMuted }}
              >
                {cards.length}
              </span>
              <span className="flex-1" />
              <span
                className="text-[11px] transition-transform"
                style={{
                  color: c.textDim,
                  transform: isCollapsed ? "rotate(0deg)" : "rotate(90deg)",
                }}
              >
                ▶
              </span>
            </button>

            {!isCollapsed && (
              <div className="mt-1.5 flex flex-col gap-1">
                {cards.length === 0 ? (
                  <div
                    className="px-3 py-2 text-[12px] italic"
                    style={{ color: c.textDim }}
                  >
                    No cards
                  </div>
                ) : (
                  cards.map((card) => (
                    <ListCardRow
                      key={card.id}
                      card={card}
                      isSelected={selectedCardId === card.id}
                      onSelect={() =>
                        selectCard(selectedCardId === card.id ? null : card.id)
                      }
                    />
                  ))
                )}
              </div>
            )}
          </div>
        );
      })}
    </div>
  );
}

function ListCardRow({
  card,
  isSelected,
  onSelect,
}: {
  card: CardDto;
  isSelected: boolean;
  onSelect: () => void;
}) {
  const { theme } = useTheme();
  const c = t(theme);
  const branch = card.link.worktreeLink?.branch;
  const pr = card.link.prLinks[0];
  const issue = card.link.issueLink;

  return (
    <div
      onClick={onSelect}
      className="flex items-center gap-2 px-3 py-2 rounded-md cursor-pointer"
      style={{
        background: isSelected ? c.bgCardSelected : c.bgCard,
        border: `1px solid ${isSelected ? c.borderCardSelected : c.borderCard}`,
      }}
      onMouseEnter={(e) => {
        if (!isSelected) e.currentTarget.style.background = c.bgCardHover;
      }}
      onMouseLeave={(e) => {
        if (!isSelected) e.currentTarget.style.background = c.bgCard;
      }}
      title={card.displayTitle}
    >
      {card.showSpinner && (
        <span className="w-3 h-3 border-2 border-[#4f8ef7] border-t-transparent rounded-full animate-spin shrink-0" />
      )}
      <div className="flex flex-col min-w-0 flex-1">
        <span
          className="text-[13px] font-medium truncate"
          style={{ color: c.textPrimary }}
        >
          {card.displayTitle}
        </span>
        <div className="flex items-center gap-2 text-[11px]" style={{ color: c.textMuted }}>
          {card.projectName && <span className="truncate">{card.projectName}</span>}
          {branch && <span className="truncate">⎇ {branch}</span>}
          {pr && <span>PR #{pr.number}</span>}
          {issue && <span>#{issue.number}</span>}
        </div>
      </div>
      <span className="text-[11px] shrink-0" style={{ color: c.textDim }}>
        {card.relativeTime}
      </span>
    </div>
  );
}
