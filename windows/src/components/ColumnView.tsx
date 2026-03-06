import { useDroppable } from "@dnd-kit/core";
import { SortableContext, verticalListSortingStrategy } from "@dnd-kit/sortable";
import { useBoardStore } from "../store/boardStore";
import { COLUMN_DISPLAY, type KanbanColumn } from "../types";
import { useTheme, t } from "../theme";
import CardView from "./CardView";

const COLUMN_ACCENT: Record<KanbanColumn, string> = {
  backlog: "#6b7280",
  in_progress: "#4f8ef7",
  requires_attention: "#d29922",
  in_review: "#a371f7",
  done: "#3fb950",
  all_sessions: "#6b7280",
};

export default function ColumnView({ column }: { column: KanbanColumn }) {
  const { cardsInColumn } = useBoardStore();
  const cards = cardsInColumn(column);
  const { setNodeRef, isOver } = useDroppable({ id: column });
  const { theme } = useTheme();
  const c = t(theme);
  const accent = COLUMN_ACCENT[column];

  return (
    <div
      className="flex flex-col min-w-0 flex-1 rounded-xl overflow-hidden"
      style={{
        background: isOver ? c.bgColumnHover(accent) : c.bgColumn,
        border: `1px solid ${isOver ? accent + "30" : c.border}`,
        transition: "background 0.2s ease, border-color 0.25s ease",
      }}
    >
      {/* Header */}
      <div className="flex items-center justify-between px-3 py-2.5 shrink-0">
        <div className="flex items-center gap-2">
          <div
            className="w-2.5 h-2.5 rounded-full transition-transform"
            style={{
              background: accent,
              transform: isOver ? "scale(1.3)" : "scale(1)",
            }}
          />
          <span className="text-[13px] font-semibold" style={{ color: c.textPrimary }}>
            {COLUMN_DISPLAY[column]}
          </span>
        </div>
        <span
          className="text-[11px] font-medium px-2 py-0.5 rounded-full"
          style={{ background: accent + "18", color: accent }}
        >
          {cards.length}
        </span>
      </div>

      {/* Cards */}
      <div
        ref={setNodeRef}
        className="flex flex-col gap-2 overflow-y-auto px-2 pt-1 pb-2 flex-1 min-h-[60px]"
      >
        <SortableContext items={cards.map((c) => c.id)} strategy={verticalListSortingStrategy}>
          {cards.map((card) => (
            <CardView key={card.id} card={card} />
          ))}
        </SortableContext>

        {cards.length === 0 && (
          <div
            className="flex items-center justify-center flex-1 min-h-[80px] rounded-lg transition-colors"
            style={{
              background: isOver ? accent + "08" : "transparent",
              border: isOver ? `2px dashed ${accent}40` : "2px dashed transparent",
            }}
          >
            <span className="text-[12px]" style={{ color: isOver ? accent : c.textDim }}>
              {isOver ? "Drop here" : "No cards"}
            </span>
          </div>
        )}
      </div>
    </div>
  );
}
