import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { create } from "zustand";
import type {
  BoardStateDto,
  CardDto,
  DependencyStatus,
  KanbanColumn,
  QueuedPrompt,
  Session,
  Settings,
  TranscriptPage,
} from "../types";

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
    launch?: boolean
  ) => Promise<string | null>;
  setSearchOpen: (open: boolean) => void;
  setSettingsOpen: (open: boolean) => void;
  setNewTaskOpen: (open: boolean) => void;
  setSelectedProject: (path: string | null) => void;
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
  selectedProjectPath: null,

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

  createCard: async (prompt, title, project, launch = false) => {
    try {
      const link = await invoke<{ id: string }>("create_card", { prompt, title, project, launch });
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
