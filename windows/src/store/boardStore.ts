import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { create } from "zustand";
import type {
  BoardStateDto,
  CardDto,
  DependencyStatus,
  KanbanColumn,
  QueuedPrompt,
  RemoteHostStatus,
  RemotePrereqs,
  Session,
  Settings,
  SyncStatus,
  TranscriptPage,
} from "../types";

export type BoardViewMode = "board" | "list";

const VIEW_MODE_STORAGE_KEY = "kanban.boardViewMode";

function loadViewMode(): BoardViewMode {
  if (typeof window === "undefined") return "board";
  const raw = window.localStorage.getItem(VIEW_MODE_STORAGE_KEY);
  return raw === "list" ? "list" : "board";
}

interface BoardStore {
  // State
  cards: CardDto[];
  selectedCardId: string | null;
  searchOpen: boolean;
  settingsOpen: boolean;
  newTaskOpen: boolean;
  isLoading: boolean;
  lastRefresh: string | null;
  error: string | null;
  selectedProjectPath: string | null;
  syncStatus: SyncStatus;
  viewMode: BoardViewMode;
  /** Transient UI hint — set by BoardView during DnD to mark the card the
   *  current drag would merge into. Cleared on drag end. */
  mergeTargetId: string | null;

  // Actions
  refresh: () => Promise<void>;
  selectCard: (id: string | null) => void;
  moveCard: (cardId: string, column: KanbanColumn) => Promise<void>;
  reorderCards: (column: KanbanColumn, orderedIds: string[]) => void;
  deleteCard: (cardId: string) => Promise<void>;
  archiveCard: (cardId: string) => Promise<void>;
  renameCard: (cardId: string, name: string) => Promise<void>;
  createCard: (
    prompt: string,
    title: string | null,
    project: string,
    launch?: boolean,
    assistantId?: string
  ) => Promise<string | null>;
  setSearchOpen: (open: boolean) => void;
  setSettingsOpen: (open: boolean) => void;
  setNewTaskOpen: (open: boolean) => void;
  setSelectedProject: (path: string | null) => void;
  setViewMode: (mode: BoardViewMode) => void;
  setMergeTargetId: (id: string | null) => void;
  clearError: () => void;

  // Computed helpers
  cardsInColumn: (column: KanbanColumn) => CardDto[];
  selectedCard: () => CardDto | null;
}

export const useBoardStore = create<BoardStore>((set, get) => ({
  cards: [],
  selectedCardId: null,
  searchOpen: false,
  settingsOpen: false,
  newTaskOpen: false,
  isLoading: false,
  lastRefresh: null,
  error: null,
  syncStatus: { kind: "disabled", conflictCount: 0 },
  selectedProjectPath: null,
  viewMode: loadViewMode(),
  mergeTargetId: null,

  refresh: async () => {
    set({ isLoading: true, error: null });
    try {
      const dto = await invoke<BoardStateDto>("get_board_state");
      set({
        cards: dto.cards,
        lastRefresh: dto.lastRefresh ?? null,
        isLoading: false,
      });
    } catch (e) {
      set({ error: String(e), isLoading: false });
    }
  },

  selectCard: (id) => set({ selectedCardId: id }),

  moveCard: async (cardId, column) => {
    // Optimistic update
    set((state) => ({
      cards: state.cards.map((c) =>
        c.id === cardId ? { ...c, link: { ...c.link, column } } : c
      ),
    }));
    try {
      await invoke("move_card", { cardId, column });
    } catch (e) {
      set({ error: String(e) });
      get().refresh();
    }
  },

  reorderCards: (_column, orderedIds) => {
    // Optimistically assign sortOrder by index for instant feedback…
    set((state) => ({
      cards: state.cards.map((c) => {
        const idx = orderedIds.indexOf(c.id);
        return idx === -1 ? c : { ...c, link: { ...c.link, sortOrder: idx } };
      }),
    }));
    // …then persist so the order survives refresh/relaunch.
    invoke("reorder_cards", { orderedIds }).catch((e) =>
      set({ error: String(e) })
    );
  },

  deleteCard: async (cardId) => {
    // If the deleted card was selected, slide selection to its column neighbor
    // so the drawer stays useful instead of snapping shut.
    const nextSelectedId = computeNextSelection(get(), cardId);
    set((state) => ({
      cards: state.cards.filter((c) => c.id !== cardId),
      selectedCardId: state.selectedCardId === cardId ? nextSelectedId : state.selectedCardId,
    }));
    try {
      await invoke("delete_card", { cardId });
    } catch (e) {
      set({ error: String(e) });
      get().refresh();
    }
  },

  archiveCard: async (cardId) => {
    // Archive yanks the card out of its current column into all_sessions.
    // Same UX as delete from the user's perspective — keep selection alive.
    const nextSelectedId = computeNextSelection(get(), cardId);
    set((state) => ({
      cards: state.cards.map((c) =>
        c.id === cardId
          ? { ...c, link: { ...c.link, column: "all_sessions" as KanbanColumn, manuallyArchived: true } }
          : c
      ),
      selectedCardId: state.selectedCardId === cardId ? nextSelectedId : state.selectedCardId,
    }));
    try {
      await invoke("archive_card", { cardId });
    } catch (e) {
      set({ error: String(e) });
      get().refresh();
    }
  },

  renameCard: async (cardId, name) => {
    set((state) => ({
      cards: state.cards.map((c) =>
        c.id === cardId ? { ...c, displayTitle: name, link: { ...c.link, name } } : c
      ),
    }));
    try {
      await invoke("rename_card", { cardId, name });
    } catch (e) {
      set({ error: String(e) });
    }
  },

  createCard: async (prompt, title, project, launch = false, assistantId) => {
    try {
      const link = await invoke<{ id: string }>("create_card", {
        prompt,
        title,
        project,
        launch,
        assistantId: assistantId ?? null,
      });
      await get().refresh();
      return link.id;
    } catch (e) {
      set({ error: String(e) });
      return null;
    }
  },

  setSearchOpen: (open) => set({ searchOpen: open }),
  setSettingsOpen: (open) => set({ settingsOpen: open }),
  setNewTaskOpen: (open) => set({ newTaskOpen: open }),
  setSelectedProject: (path) => set({ selectedProjectPath: path }),
  setViewMode: (mode) => {
    if (typeof window !== "undefined") {
      window.localStorage.setItem(VIEW_MODE_STORAGE_KEY, mode);
    }
    set({ viewMode: mode });
  },
  setMergeTargetId: (id) => set({ mergeTargetId: id }),
  clearError: () => set({ error: null }),

  cardsInColumn: (column) => {
    const { cards, selectedProjectPath } = get();
    const filtered = cards
      .filter((c) => c.link.column === column)
      .filter((c) => {
        if (!selectedProjectPath) return true;
        const cardPath = c.link.projectPath ?? c.session?.projectPath;
        if (!cardPath) return false;
        return (
          cardPath === selectedProjectPath ||
          cardPath.startsWith(selectedProjectPath + "/") ||
          cardPath.startsWith(selectedProjectPath + "\\")
        );
      });

    const byTimeDesc = (a: CardDto, b: CardDto) => {
      const ta = a.link.lastActivity ?? a.link.updatedAt;
      const tb = b.link.lastActivity ?? b.link.updatedAt;
      return tb.localeCompare(ta);
    };

    // If any card in this column has a persisted sortOrder, honor the manual
    // order (ascending); cards without one fall to the end, newest first.
    const hasManualOrder = filtered.some((c) => c.link.sortOrder != null);
    if (!hasManualOrder) return filtered.sort(byTimeDesc);

    return filtered.sort((a, b) => {
      const sa = a.link.sortOrder;
      const sb = b.link.sortOrder;
      if (sa != null && sb != null) return sa - sb;
      if (sa != null) return -1;
      if (sb != null) return 1;
      return byTimeDesc(a, b);
    });
  },

  selectedCard: () => {
    const { cards, selectedCardId } = get();
    return cards.find((c) => c.id === selectedCardId) ?? null;
  },
}));

/**
 * After deleting/archiving the card with `removedId`, pick the next card to
 * select. Returns the same-column neighbor (next-newer, falling back to next-
 * older) so the drawer stays useful. `null` if the column will be empty.
 */
function computeNextSelection(
  state: { cards: CardDto[]; selectedCardId: string | null },
  removedId: string
): string | null {
  if (state.selectedCardId !== removedId) return state.selectedCardId;
  const removed = state.cards.find((c) => c.id === removedId);
  if (!removed) return null;
  // Use the same ordered slice the column UI sees, then pick a neighbor.
  const ordered = useBoardStore.getState().cardsInColumn(removed.link.column);
  const idx = ordered.findIndex((c) => c.id === removedId);
  if (idx === -1) return null;
  return ordered[idx + 1]?.id ?? ordered[idx - 1]?.id ?? null;
}

// Subscribe to Tauri backend events
export function initBoardEventListener() {
  listen<BoardStateDto>("board-updated", (event) => {
    useBoardStore.setState({
      cards: event.payload.cards,
      lastRefresh: event.payload.lastRefresh ?? null,
    });
  });
  listen<SyncStatus>("sync_status_event", (event) => {
    useBoardStore.setState({ syncStatus: event.payload });
  });
  listen<RemoteHostStatus>("remote_status_changed", (event) => {
    // Surface as a non-blocking toast via the OS notification path the
    // backend already owns — we just log here so the dev tools show it.
    console.info("remote host status change", event.payload);
  });
}

// Tauri command wrappers
export async function getSettings(): Promise<Settings> {
  return invoke<Settings>("get_settings");
}

export async function saveSettings(settings: Settings): Promise<void> {
  return invoke("save_settings", { settings });
}

export async function getTranscript(
  sessionId: string,
  offset: number
): Promise<TranscriptPage> {
  return invoke<TranscriptPage>("get_transcript", { sessionId, offset });
}

export async function searchSessions(query: string): Promise<Session[]> {
  return invoke<Session[]>("search_sessions", { query });
}

export async function launchSession(sessionId: string): Promise<void> {
  return invoke("launch_session", { sessionId });
}

export async function openInEditor(
  path: string,
  editor?: string
): Promise<void> {
  return invoke("open_in_editor", { path, editor: editor ?? null });
}

export async function addQueuedPrompt(
  cardId: string,
  body: string,
  sendAutomatically: boolean
): Promise<QueuedPrompt> {
  return invoke<QueuedPrompt>("add_queued_prompt", { cardId, body, sendAutomatically });
}

export async function updateQueuedPrompt(
  cardId: string,
  promptId: string,
  body: string,
  sendAutomatically: boolean
): Promise<void> {
  return invoke("update_queued_prompt", { cardId, promptId, body, sendAutomatically });
}

export async function removeQueuedPrompt(
  cardId: string,
  promptId: string
): Promise<void> {
  return invoke("remove_queued_prompt", { cardId, promptId });
}

export async function checkDependencies(): Promise<DependencyStatus> {
  return invoke<DependencyStatus>("check_dependencies");
}

export async function searchTranscript(
  sessionId: string,
  query: string
): Promise<number[]> {
  return invoke<number[]>("search_transcript", { sessionId, query });
}

export async function resolveGithubBaseUrl(projectPath: string): Promise<string | null> {
  return invoke<string | null>("resolve_github_base_url", { projectPath });
}

export async function openGithubPr(projectPath: string, number: number): Promise<void> {
  return invoke("open_github_pr", { projectPath, number });
}

export async function openGithubIssue(projectPath: string, number: number): Promise<void> {
  return invoke("open_github_issue", { projectPath, number });
}

export async function mergePr(projectPath: string, number: number): Promise<string> {
  return invoke<string>("merge_pr", { projectPath, number });
}

export interface WorktreeInfo {
  path: string;
  branch?: string;
  isMain: boolean;
}

export async function listWorktrees(repoRoot: string): Promise<WorktreeInfo[]> {
  return invoke<WorktreeInfo[]>("list_worktrees", { repoRoot });
}

export async function createWorktree(repoRoot: string, name: string): Promise<WorktreeInfo> {
  return invoke<WorktreeInfo>("create_worktree", { repoRoot, name });
}

export async function moveCardToProject(
  cardId: string,
  targetProjectPath: string
): Promise<void> {
  return invoke("move_card_to_project", { cardId, targetProjectPath });
}

export async function mergeCards(
  sourceCardId: string,
  targetCardId: string
): Promise<void> {
  return invoke("merge_cards", { sourceCardId, targetCardId });
}

/** Pure client-side preview of merge_ops.rs::merge_blocked, so the DnD
 *  overlay only promises a merge the backend will accept. Keep in sync. */
export function canMergeCards(source: CardDto, target: CardDto): boolean {
  if (source.id === target.id) return false;
  if (source.link.isLaunching || target.link.isLaunching) return false;
  if (source.link.sessionLink && target.link.sessionLink) return false;
  const sWt = source.link.worktreeLink;
  const tWt = target.link.worktreeLink;
  if (sWt && tWt && sWt.path !== tWt.path) return false;
  const sIss = source.link.issueLink;
  const tIss = target.link.issueLink;
  if (sIss && tIss && sIss.number !== tIss.number) return false;
  return true;
}

export async function removeWorktree(
  path: string,
  repoRoot: string | null,
  force: boolean
): Promise<void> {
  return invoke("remove_worktree", { path, repoRoot, force });
}

/** Duplicate a session .jsonl with a fresh UUID, returning the new session id. */
export async function forkSession(sessionPath: string, targetDir?: string): Promise<string> {
  return invoke<string>("fork_session", { sessionPath, targetDir: targetDir ?? null });
}

/** Project paths discovered from existing session data, deduped + sorted. */
export async function discoverProjects(): Promise<string[]> {
  return invoke<string[]>("discover_projects");
}

/** Truncate a session .jsonl to keep only the first `turnCount` user/assistant turns. */
export async function truncateSession(sessionPath: string, turnCount: number): Promise<void> {
  return invoke("truncate_session", { sessionPath, turnCount });
}

// ── Remote / sync (Phase 5) ──────────────────────────────────────────────────

export async function remotePrereqs(): Promise<RemotePrereqs> {
  return invoke<RemotePrereqs>("remote_prereqs");
}

export async function remoteDeployShell(): Promise<void> {
  return invoke("remote_deploy_shell");
}

export async function mutagenStatus(): Promise<SyncStatus> {
  return invoke<SyncStatus>("mutagen_status");
}

export async function mutagenRawStatus(): Promise<string> {
  return invoke<string>("mutagen_raw_status");
}

export async function mutagenStart(): Promise<void> {
  return invoke("mutagen_start");
}

export async function mutagenStop(): Promise<void> {
  return invoke("mutagen_stop");
}

export async function mutagenReset(): Promise<void> {
  return invoke("mutagen_reset");
}

export async function mutagenFlush(): Promise<void> {
  return invoke("mutagen_flush");
}
