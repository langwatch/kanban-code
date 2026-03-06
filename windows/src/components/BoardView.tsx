import {
  DndContext, DragEndEvent, DragOverlay, DragStartEvent,
  PointerSensor, useSensor, useSensors, closestCenter,
  type DropAnimation, defaultDropAnimationSideEffects,
} from "@dnd-kit/core";
import { arrayMove } from "@dnd-kit/sortable";
import { useState } from "react";
import { useBoardStore } from "../store/boardStore";
import { COLUMNS, type CardDto, type KanbanColumn } from "../types";
import { useTheme, t } from "../theme";
import CardView from "./CardView";
import ColumnView from "./ColumnView";

const dropAnimation: DropAnimation = {
  sideEffects: defaultDropAnimationSideEffects({
    styles: { active: { opacity: "0.5" } },
  }),
  duration: 200,
  easing: "cubic-bezier(0.25, 1, 0.5, 1)",
};

export default function BoardView() {
  const { moveCard, reorderCards, isLoading, cards, setNewTaskOpen } = useBoardStore();
  const [draggingCard, setDraggingCard] = useState<CardDto | null>(null);
  const { theme } = useTheme();
  const c = t(theme);

  const sensors = useSensors(
    useSensor(PointerSensor, { activationConstraint: { distance: 5 } })
  );

  const handleDragStart = (event: DragStartEvent) => {
    setDraggingCard(event.active.data.current as CardDto);
  };

  const handleDragEnd = (event: DragEndEvent) => {
    setDraggingCard(null);
    const { active, over } = event;
    if (!over) return;

    const activeCard = active.data.current as CardDto;
    const activeId = active.id as string;
    const overId = over.id as string;

    if (activeId === overId) return;

    // Dropped on a column droppable → cross-column move
    if (COLUMNS.includes(overId as KanbanColumn)) {
      const targetColumn = overId as KanbanColumn;
      if (activeCard.link.column !== targetColumn) {
        moveCard(activeId, targetColumn);
      }
      return;
    }

    // Dropped on another card
    const overCard = over.data.current as CardDto;
    if (!overCard) return;

    if (activeCard.link.column === overCard.link.column) {
      // Same column → reorder
      const column = activeCard.link.column;
      const columnCards = useBoardStore.getState().cardsInColumn(column);
      const oldIndex = columnCards.findIndex((c) => c.id === activeId);
      const newIndex = columnCards.findIndex((c) => c.id === overId);
      if (oldIndex !== -1 && newIndex !== -1 && oldIndex !== newIndex) {
        const newOrder = arrayMove(
          columnCards.map((c) => c.id),
          oldIndex,
          newIndex
        );
        reorderCards(column, newOrder);
      }
    } else {
      // Cross-column: move to the target card's column
      moveCard(activeId, overCard.link.column);
    }
  };

  const isEmpty = cards.length === 0 && !isLoading;

  return (
    <div className="flex flex-1 overflow-hidden relative">
      <DndContext
        sensors={sensors}
        collisionDetection={closestCenter}
        onDragStart={handleDragStart}
        onDragEnd={handleDragEnd}
      >
        <div className="flex flex-1 gap-1.5 overflow-x-auto p-2">
          {COLUMNS.map((column) => <ColumnView key={column} column={column} />)}
        </div>
        <DragOverlay dropAnimation={dropAnimation}>
          {draggingCard && (
            <div style={{
              opacity: 0.92,
              transform: "scale(1.03) rotate(1.5deg)",
              pointerEvents: "none",
              filter: `drop-shadow(0 12px 24px rgba(0,0,0,0.3))`,
              transition: "transform 0.15s ease",
            }}>
              <CardView card={draggingCard} isDragging />
            </div>
          )}
        </DragOverlay>
      </DndContext>

      {isLoading && (
        <div
          className="absolute top-3 left-1/2 -translate-x-1/2 z-20 px-4 py-1.5 rounded-full animate-fade-in"
          style={{ background: c.bgDialog, border: `1px solid ${c.borderBright}` }}
        >
          <div className="flex items-center gap-2">
            <div className="w-3.5 h-3.5 border-2 border-[#4f8ef7] border-t-transparent rounded-full animate-spin" />
            <span className="text-[12px]" style={{ color: c.textMuted }}>Refreshing...</span>
          </div>
        </div>
      )}

      {isEmpty && (
        <div className="absolute inset-0 flex items-center justify-center">
          <div className="flex flex-col items-center gap-4 animate-fade-in">
            <p className="text-[15px]" style={{ color: c.textSecondary }}>No sessions found</p>
            <p className="text-[13px]" style={{ color: c.textDim }}>
              Create a new task or start a Claude session to get going.
            </p>
            <button
              onClick={() => setNewTaskOpen(true)}
              className="btn-action flex items-center gap-2 px-5 py-2.5 rounded-lg bg-[#4f8ef7] text-white text-[13px] font-semibold mt-2"
              title="Create a new task card"
            >
              <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2.5}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M12 4v16m8-8H4" />
              </svg>
              New Task
            </button>
          </div>
        </div>
      )}
    </div>
  );
}
