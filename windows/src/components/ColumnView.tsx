import { useDroppable } from "@dnd-kit/core";
import { SortableContext, verticalListSortingStrategy } from "@dnd-kit/sortable";
import { useBoardStore } from "../store/boardStore";
import { COLUMN_DISPLAY, type KanbanColumn } from "../types";
import CardView from "./CardView";

const COLUMN_ACCENT: Record<KanbanColumn, string> = {
  backlog: "#6b7280",
  in_progress: "#4f8ef7",
  requires_attention: "#d29922",
  in_review: "#a371f7",
  done: "#3fb950",
  all_sessions: "#6b7280",
};

interface Props {
  column: KanbanColumn;
}

export default function ColumnView({ column }: Props) {
  const { cardsInColumn } = useBoardStore();
  const cards = cardsInColumn(column);

  const { setNodeRef, isOver } = useDroppable({ id: column });

  const accent = COLUMN_ACCENT[column];

  return (
    <div
      className={`flex flex-col w-[260px] min-w-[260px] mx-1.5 rounded-xl overflow-hidden transition-colors ${
        isOver ? "bg-[#1c1c25]" : "bg-[#141417]"
      }`}
      style={{ border: `1px solid ${isOver ? accent + "44" : "#2a2a32"}` }}
    >
      {/* Column header */}
      <div className="flex items-center justify-between px-3 py-2.5 shrink-0">
        <div className="flex items-center gap-2">
          <div
            className="w-2 h-2 rounded-full"
            style={{ background: accent }}
          />
          <span className="text-xs font-semibold text-zinc-300">
            {COLUMN_DISPLAY[column]}
          </span>
        </div>
        <span className="text-[11px] text-zinc-500 bg-[#242429] px-1.5 py-0.5 rounded-full">
          {cards.length}
        </span>
      </div>

      {/* Cards */}
      <div
        ref={setNodeRef}
        className="flex flex-col gap-1.5 overflow-y-auto px-2 pb-3 flex-1 min-h-[60px]"
      >
        <SortableContext
          items={cards.map((c) => c.id)}
          strategy={verticalListSortingStrategy}
        >
          {cards.map((card) => (
            <CardView key={card.id} card={card} />
          ))}
        </SortableContext>

        {cards.length === 0 && (
          <div className="flex items-center justify-center flex-1 min-h-[80px]">
            <span className="text-[11px] text-zinc-600">Drop here</span>
          </div>
        )}
      </div>
    </div>
  );
}
