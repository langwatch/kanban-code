import {
  DndContext,
  DragEndEvent,
  DragOverlay,
  DragStartEvent,
  PointerSensor,
  useSensor,
  useSensors,
} from "@dnd-kit/core";
import { useState } from "react";
import { useBoardStore } from "../store/boardStore";
import { COLUMNS, type CardDto, type KanbanColumn } from "../types";
import CardView from "./CardView";
import ColumnView from "./ColumnView";

export default function BoardView() {
  const { moveCard, isLoading } = useBoardStore();
  const [draggingCard, setDraggingCard] = useState<CardDto | null>(null);

  const sensors = useSensors(
    useSensor(PointerSensor, {
      activationConstraint: { distance: 4 },
    })
  );

  const handleDragStart = (event: DragStartEvent) => {
    const card = event.active.data.current as CardDto;
    setDraggingCard(card);
  };

  const handleDragEnd = (event: DragEndEvent) => {
    setDraggingCard(null);
    const { active, over } = event;
    if (!over) return;

    const cardId = active.id as string;
    const targetColumn = over.id as KanbanColumn;
    const card = active.data.current as CardDto;

    if (card.link.column !== targetColumn) {
      moveCard(cardId, targetColumn);
    }
  };

  return (
    <div className="flex flex-1 overflow-hidden">
      <DndContext
        sensors={sensors}
        onDragStart={handleDragStart}
        onDragEnd={handleDragEnd}
      >
        <div className="flex flex-1 gap-0 overflow-x-auto p-3">
          {COLUMNS.map((column) => (
            <ColumnView key={column} column={column} />
          ))}
        </div>

        <DragOverlay>
          {draggingCard && (
            <div className="rotate-1 opacity-90 pointer-events-none">
              <CardView card={draggingCard} isDragging />
            </div>
          )}
        </DragOverlay>
      </DndContext>

      {isLoading && (
        <div className="fixed top-12 left-1/2 -translate-x-1/2 text-xs text-zinc-500 bg-[#141417] px-3 py-1 rounded-full border border-[#2a2a32]">
          Refreshing...
        </div>
      )}
    </div>
  );
}
