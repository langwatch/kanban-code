import { useSortable } from "@dnd-kit/sortable";
import { CSS } from "@dnd-kit/utilities";
import { useState } from "react";
import { ask } from "@tauri-apps/plugin-dialog";
import { useBoardStore } from "../store/boardStore";
import { COLUMNS, COLUMN_DISPLAY, type CardDto, type KanbanColumn } from "../types";
import { useTheme, t } from "../theme";

interface Props {
  card: CardDto;
  isDragging?: boolean;
}

export default function CardView({ card, isDragging = false }: Props) {
  const { selectCard, selectedCardId, moveCard, deleteCard, archiveCard, mergeTargetId } = useBoardStore();
  const [contextMenu, setContextMenu] = useState<{ x: number; y: number } | null>(null);
  const { theme } = useTheme();
  const c = t(theme);
  const isMergeTarget = mergeTargetId === card.id && !isDragging;

  const {
    attributes, listeners, setNodeRef, transform, transition, isDragging: isSortDragging,
  } = useSortable({
    id: card.id,
    data: card,
  });

  const style = {
    transform: CSS.Transform.toString(transform),
    transition,
    opacity: isSortDragging ? 0.4 : undefined,
    zIndex: isSortDragging ? 50 : undefined,
  };

  const isSelected = selectedCardId === card.id;
  const hasPR = card.link.prLinks.length > 0;
  const hasIssue = !!card.link.issueLink;
  const hasBranch = !!card.link.worktreeLink?.branch;
  const hasSession = !!card.link.sessionLink;

  const pr = card.link.prLinks[0];
  const prStatus = pr?.status;
  const prStatusColor =
    prStatus === "MERGED" ? "#a371f7"
    : prStatus === "CLOSED" ? "#f85149"
    : "#3fb950";
  // Worst CI conclusion → colored dot next to PR badge. Mirrors
  // gh_cli::worst_check_state ranking server-side.
  const ciState = worstCi(pr?.checkRuns);

  return (
    <>
      <div
        ref={setNodeRef}
        style={{
          ...style,
          background: isSelected ? c.bgCardSelected : c.bgCard,
          border: `1px solid ${isSelected ? c.borderCardSelected : c.borderCard}`,
          // Whole-card orange outline so the user knows the drop will
          // collapse this card into the dragged one. 2px to read on
          // both bg themes without redrawing layout.
          outline: isMergeTarget ? "2px solid #f59e0b" : undefined,
          outlineOffset: isMergeTarget ? "1px" : undefined,
        }}
        {...listeners}
        {...attributes}
        onClick={(e) => { e.stopPropagation(); selectCard(isSelected ? null : card.id); }}
        onContextMenu={(e) => { e.preventDefault(); setContextMenu({ x: e.clientX, y: e.clientY }); }}
        onMouseEnter={(e) => {
          if (!isSelected) {
            e.currentTarget.style.background = c.bgCardHover;
            e.currentTarget.style.borderColor = c.borderBright;
          }
        }}
        onMouseLeave={(e) => {
          if (!isSelected) {
            e.currentTarget.style.background = c.bgCard;
            e.currentTarget.style.borderColor = c.borderCard;
          }
        }}
        className={`card-hover relative rounded-lg px-3 py-2.5 cursor-pointer select-none ${
          isDragging ? "shadow-2xl scale-[1.02]" : ""
        }`}
        title={card.displayTitle}
      >
        {/* Merge badge — floats above the card during a valid merge hover */}
        {isMergeTarget && (
          <div
            className="absolute -top-2.5 left-1/2 -translate-x-1/2 px-2 py-0.5 rounded-full text-[10px] font-bold tracking-wider uppercase z-10 pointer-events-none"
            style={{ background: "#f59e0b", color: "#fff" }}
          >
            Merge
          </div>
        )}

        {/* Spinner */}
        {card.showSpinner && (
          <div className="absolute top-2.5 right-2.5">
            <div className="w-4 h-4 border-2 border-[#4f8ef7] border-t-transparent rounded-full animate-spin" />
          </div>
        )}

        {/* Title */}
        <p className="text-[13px] leading-snug line-clamp-2 pr-5 font-medium" style={{ color: c.textPrimary }}>
          {card.displayTitle}
        </p>

        {/* Project name */}
        {card.projectName && (
          <p className="text-[12px] mt-1 truncate" style={{ color: c.textMuted }}>
            {card.projectName}
          </p>
        )}

        {/* Badges row */}
        <div className="flex flex-wrap items-center gap-1.5 mt-2">
          {hasBranch && <Badge text={card.link.worktreeLink!.branch!} color="#4f8ef7" theme={theme} title={`Branch: ${card.link.worktreeLink!.branch}`} />}
          {hasPR && (
            <span className="inline-flex items-center gap-1">
              <Badge text={`PR #${pr!.number}`} color={prStatusColor} theme={theme} title={pr!.title ?? `PR #${pr!.number}`} />
              {ciState && <CiDot state={ciState} runs={pr!.checkRuns ?? []} />}
            </span>
          )}
          {hasIssue && <Badge text={`#${card.link.issueLink!.number}`} color="#d29922" theme={theme} title={card.link.issueLink!.title ?? `Issue #${card.link.issueLink!.number}`} />}
          {hasSession && !hasBranch && !hasPR && !hasIssue && <Badge text="session" color="#6b7280" theme={theme} title={`Session: ${card.link.sessionLink!.sessionId}`} />}
          <span className="flex-1" />
          <span className="text-[11px]" style={{ color: c.textDim }}>{card.relativeTime}</span>
        </div>
      </div>

      {contextMenu && (
        <ContextMenu
          x={contextMenu.x} y={contextMenu.y} card={card}
          onClose={() => setContextMenu(null)}
          onMove={(col) => { moveCard(card.id, col); setContextMenu(null); }}
          onDelete={async () => {
            setContextMenu(null);
            const title = card.displayTitle || card.link.name || "this card";
            const ok = await ask(
              `Delete "${title}"?\n\nThe Claude session .jsonl on disk is not deleted — you can still find it in All Sessions.`,
              { title: "Delete card", kind: "warning", okLabel: "Delete", cancelLabel: "Cancel" }
            );
            if (ok) deleteCard(card.id);
          }}
          onArchive={() => { archiveCard(card.id); setContextMenu(null); }}
        />
      )}
    </>
  );
}

type CiState = "FAILURE" | "PENDING" | "NEUTRAL" | "SUCCESS";

function worstCi(runs?: { name: string; conclusion?: string }[]): CiState | null {
  if (!runs || runs.length === 0) return null;
  const rank = (s: string) => {
    if (["FAILURE", "CANCELLED", "TIMED_OUT", "STARTUP_FAILURE", "ACTION_REQUIRED"].includes(s)) return 4;
    if (["PENDING", "QUEUED", "IN_PROGRESS"].includes(s)) return 3;
    if (["NEUTRAL", "SKIPPED", "STALE"].includes(s)) return 2;
    if (s === "SUCCESS") return 1;
    return 0;
  };
  let worst: CiState = "SUCCESS";
  for (const r of runs) {
    const c = r.conclusion ?? "PENDING";
    if (rank(c) <= rank(worst === "FAILURE" ? "FAILURE" : worst === "PENDING" ? "PENDING" : worst === "NEUTRAL" ? "NEUTRAL" : "SUCCESS")) {
      continue;
    }
    worst =
      rank(c) === 4 ? "FAILURE"
      : rank(c) === 3 ? "PENDING"
      : rank(c) === 2 ? "NEUTRAL"
      : "SUCCESS";
  }
  return worst;
}

function CiDot({ state, runs }: { state: CiState; runs: { name: string; conclusion?: string }[] }) {
  const color =
    state === "FAILURE" ? "#f85149"
    : state === "PENDING" ? "#d29922"
    : state === "NEUTRAL" ? "#8b8b8b"
    : "#3fb950";
  const title = runs.map((r) => `${r.name}: ${r.conclusion ?? "pending"}`).join("\n");
  return (
    <span
      className="inline-block w-2 h-2 rounded-full"
      style={{
        background: color,
        boxShadow: state === "PENDING" ? "0 0 0 2px rgba(210,153,34,0.25)" : undefined,
      }}
      title={`CI: ${state.toLowerCase()}\n${title}`}
    />
  );
}

function Badge({ text, color, theme, title }: { text: string; color: string; theme: string; title?: string }) {
  return (
    <span
      className="badge-hover inline-flex items-center px-1.5 py-0.5 rounded text-[11px] font-medium truncate max-w-[120px] cursor-default"
      style={{ background: color + (theme === "dark" ? "18" : "15"), color }}
      title={title}
    >
      {text}
    </span>
  );
}

function ContextMenu({
  x, y, card, onClose, onMove, onDelete, onArchive,
}: {
  x: number; y: number; card: CardDto; onClose: () => void;
  onMove: (col: KanbanColumn) => void; onDelete: () => void; onArchive: () => void;
}) {
  const { theme } = useTheme();
  const c = t(theme);
  const moveTargets = COLUMNS.filter((col) => col !== card.link.column);

  return (
    <>
      <div className="fixed inset-0 z-40" onClick={onClose} />
      <div
        className="fixed z-50 rounded-lg shadow-2xl py-1 min-w-[180px] animate-fade-in"
        style={{ left: x, top: y, background: c.bgContext, border: `1px solid ${c.borderBright}` }}
      >
        <div className="px-3 py-1.5 text-[11px] font-semibold uppercase tracking-wider" style={{ color: c.textDim }}>
          Move to
        </div>
        {moveTargets.map((col) => (
          <button
            key={col}
            onClick={() => onMove(col)}
            className="w-full text-left px-3 py-2 text-[13px] transition-colors"
            style={{ color: c.textSecondary }}
            onMouseEnter={(e) => { e.currentTarget.style.background = c.hoverBg; }}
            onMouseLeave={(e) => { e.currentTarget.style.background = ""; }}
          >
            {COLUMN_DISPLAY[col]}
          </button>
        ))}
        <div style={{ borderTop: `1px solid ${c.border}`, margin: "4px 0" }} />
        <button
          onClick={onArchive}
          className="w-full text-left px-3 py-2 text-[13px] transition-colors"
          style={{ color: c.textMuted }}
          onMouseEnter={(e) => { e.currentTarget.style.background = c.hoverBg; }}
          onMouseLeave={(e) => { e.currentTarget.style.background = ""; }}
        >
          Archive
        </button>
        <button
          onClick={onDelete}
          className="w-full text-left px-3 py-2 text-[13px] text-[#f85149] transition-colors"
          onMouseEnter={(e) => { e.currentTarget.style.background = "rgba(248,81,73,0.08)"; }}
          onMouseLeave={(e) => { e.currentTarget.style.background = ""; }}
        >
          Delete
        </button>
      </div>
    </>
  );
}
