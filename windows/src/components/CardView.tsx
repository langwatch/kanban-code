import { useDraggable } from "@dnd-kit/core";
import { CSS } from "@dnd-kit/utilities";
import { useState } from "react";
import { useBoardStore } from "../store/boardStore";
import { COLUMNS, COLUMN_DISPLAY, type CardDto, type KanbanColumn } from "../types";

interface Props {
  card: CardDto;
  isDragging?: boolean;
}

export default function CardView({ card, isDragging = false }: Props) {
  const { selectCard, selectedCardId, moveCard, deleteCard, archiveCard } =
    useBoardStore();
  const [contextMenu, setContextMenu] = useState<{ x: number; y: number } | null>(
    null
  );

  const { attributes, listeners, setNodeRef, transform } = useDraggable({
    id: card.id,
    data: card,
  });

  const style = transform
    ? { transform: CSS.Translate.toString(transform) }
    : undefined;

  const isSelected = selectedCardId === card.id;
  const hasSession = !!card.link.sessionLink;
  const hasPR = card.link.prLinks.length > 0;
  const hasIssue = !!card.link.issueLink;
  const hasBranch = !!card.link.worktreeLink?.branch;

  const prStatus = card.link.prLinks[0]?.status;
  const prStatusColor =
    prStatus === "MERGED"
      ? "#a371f7"
      : prStatus === "CLOSED"
      ? "#f85149"
      : "#3fb950";

  const handleContextMenu = (e: React.MouseEvent) => {
    e.preventDefault();
    setContextMenu({ x: e.clientX, y: e.clientY });
  };

  const closeContextMenu = () => setContextMenu(null);

  return (
    <>
      <div
        ref={setNodeRef}
        style={style}
        {...listeners}
        {...attributes}
        onClick={(e) => {
          e.stopPropagation();
          selectCard(isSelected ? null : card.id);
        }}
        onContextMenu={handleContextMenu}
        className={`
          relative rounded-lg px-3 py-2.5 cursor-pointer select-none transition-all
          ${isDragging ? "shadow-2xl" : ""}
          ${
            isSelected
              ? "bg-[#1a2236] border border-[#4f8ef7]/40"
              : "bg-[#1c1c21] border border-[#2a2a32] hover:border-[#3a3a44] hover:bg-[#212128]"
          }
        `}
      >
        {/* Spinner for active work */}
        {card.showSpinner && (
          <div className="absolute top-2 right-2">
            <div className="w-3 h-3 border border-[#4f8ef7] border-t-transparent rounded-full animate-spin" />
          </div>
        )}

        {/* Title */}
        <p className="text-[12px] text-zinc-200 leading-snug line-clamp-2 pr-5">
          {card.displayTitle}
        </p>

        {/* Project name */}
        {card.projectName && (
          <p className="text-[11px] text-zinc-500 mt-0.5 truncate">
            {card.projectName}
          </p>
        )}

        {/* Badges */}
        <div className="flex flex-wrap gap-1 mt-2">
          {hasBranch && (
            <Badge text={card.link.worktreeLink!.branch!} color="#4f8ef7" />
          )}
          {hasPR && (
            <Badge
              text={`#${card.link.prLinks[0].number}`}
              color={prStatusColor}
            />
          )}
          {hasIssue && (
            <Badge text={`#${card.link.issueLink!.number}`} color="#d29922" />
          )}
          {hasSession && !hasBranch && (
            <Badge text="session" color="#6b7280" />
          )}
        </div>

        {/* Relative time */}
        <p className="text-[10px] text-zinc-600 mt-1.5">{card.relativeTime}</p>
      </div>

      {/* Context menu */}
      {contextMenu && (
        <ContextMenu
          x={contextMenu.x}
          y={contextMenu.y}
          card={card}
          onClose={closeContextMenu}
          onMove={(col) => {
            moveCard(card.id, col);
            closeContextMenu();
          }}
          onDelete={() => {
            deleteCard(card.id);
            closeContextMenu();
          }}
          onArchive={() => {
            archiveCard(card.id);
            closeContextMenu();
          }}
        />
      )}
    </>
  );
}

function Badge({ text, color }: { text: string; color: string }) {
  return (
    <span
      className="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium"
      style={{ background: color + "22", color }}
    >
      {text}
    </span>
  );
}

function ContextMenu({
  x,
  y,
  card,
  onClose,
  onMove,
  onDelete,
  onArchive,
}: {
  x: number;
  y: number;
  card: CardDto;
  onClose: () => void;
  onMove: (col: KanbanColumn) => void;
  onDelete: () => void;
  onArchive: () => void;
}) {
  const moveTargets = COLUMNS.filter((c) => c !== card.link.column);

  return (
    <>
      <div className="fixed inset-0 z-40" onClick={onClose} />
      <div
        className="fixed z-50 bg-[#1c1c21] border border-[#3a3a44] rounded-lg shadow-2xl py-1 min-w-[160px]"
        style={{ left: x, top: y }}
      >
        <div className="px-3 py-1.5 text-[10px] text-zinc-500 font-semibold uppercase tracking-wider">
          Move to
        </div>
        {moveTargets.map((col) => (
          <button
            key={col}
            onClick={() => onMove(col)}
            className="w-full text-left px-3 py-1.5 text-xs text-zinc-300 hover:bg-[#2a2a32] transition-colors"
          >
            {COLUMN_DISPLAY[col]}
          </button>
        ))}
        <div className="border-t border-[#2a2a32] my-1" />
        <button
          onClick={onArchive}
          className="w-full text-left px-3 py-1.5 text-xs text-zinc-400 hover:bg-[#2a2a32] transition-colors"
        >
          Archive
        </button>
        <button
          onClick={onDelete}
          className="w-full text-left px-3 py-1.5 text-xs text-[#f85149] hover:bg-[#2a2a32] transition-colors"
        >
          Delete
        </button>
      </div>
    </>
  );
}
