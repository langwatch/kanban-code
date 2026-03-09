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
  columnOrder: Record<string, string[]>;

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
  columnOrder: {},

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

  reorderCards: (column, orderedIds) => {
    set((state) => ({
      columnOrder: { ...state.columnOrder, [column]: orderedIds },
    }));
  },

  deleteCard: async (cardId) => {
    set((state) => ({
      cards: state.cards.filter((c) => c.id !== cardId),
      selectedCardId: state.selectedCardId === cardId ? null : state.selectedCardId,
    }));
    try {
      await invoke("delete_card", { cardId });
    } catch (e) {
      set({ error: String(e) });
      get().refresh();
    }
  },

  archiveCard: async (cardId) => {
    set((state) => ({
      cards: state.cards.map((c) =>
        c.id === cardId
          ? { ...c, link: { ...c.link, column: "all_sessions" as KanbanColumn, manuallyArchived: true } }
          : c
      ),
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
    const { cards, selectedProjectPath, columnOrder } = get();
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

    const order = columnOrder[column];
    if (order && order.length > 0) {
      const orderMap = new Map(order.map((id, idx) => [id, idx]));
      return filtered.sort((a, b) => {
        const ia = orderMap.get(a.id);
        const ib = orderMap.get(b.id);
        // Cards with stored order come first, in their stored positions
        if (ia !== undefined && ib !== undefined) return ia - ib;
        if (ia !== undefined) return -1;
        if (ib !== undefined) return 1;
        // Fallback: newest first
        const ta = a.link.lastActivity ?? a.link.updatedAt;
        const tb = b.link.lastActivity ?? b.link.updatedAt;
        return tb.localeCompare(ta);
      });
    }

    return filtered.sort((a, b) => {
      const ta = a.link.lastActivity ?? a.link.updatedAt;
      const tb = b.link.lastActivity ?? b.link.updatedAt;
      return tb.localeCompare(ta);
    });
  },

  selectedCard: () => {
    const { cards, selectedCardId } = get();
    return cards.find((c) => c.id === selectedCardId) ?? null;
  },
}));

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
