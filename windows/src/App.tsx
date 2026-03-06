import { useEffect } from "react";
import BoardView from "./components/BoardView";
import CardDetailView from "./components/CardDetailView";
import NewTaskDialog from "./components/NewTaskDialog";
import SearchOverlay from "./components/SearchOverlay";
import SettingsView from "./components/SettingsView";
import { initBoardEventListener, useBoardStore } from "./store/boardStore";

// Detect macOS for keyboard shortcut display
const isMac =
  typeof navigator !== "undefined" &&
  /mac/i.test(navigator.platform || navigator.userAgent);

export default function App() {
  const {
    selectedCardId,
    searchOpen,
    settingsOpen,
    newTaskOpen,
    error,
    clearError,
    refresh,
    setSearchOpen,
    setNewTaskOpen,
    setSettingsOpen,
  } = useBoardStore();

  useEffect(() => {
    refresh();
    initBoardEventListener();
  }, []);

  // Global keyboard shortcuts
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key === "k") {
        e.preventDefault();
        setSearchOpen(true);
      }
      if ((e.metaKey || e.ctrlKey) && e.key === "n") {
        e.preventDefault();
        setNewTaskOpen(true);
      }
      if (e.key === "Escape") {
        setSearchOpen(false);
        setNewTaskOpen(false);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  return (
    <div className="flex flex-col h-full bg-[#0d0d0f] text-zinc-100 overflow-hidden">
      {/* Header */}
      <header className="flex items-center justify-between px-4 h-11 border-b border-[#2a2a32] shrink-0 select-none">
        <div className="flex items-center gap-2">
          <span className="text-sm font-semibold text-zinc-200">Kanban Code</span>
        </div>
        <div className="flex items-center gap-2">
          <button
            onClick={() => setSearchOpen(true)}
            className="flex items-center gap-1.5 px-2.5 py-1 rounded-md text-zinc-400 hover:text-zinc-200 hover:bg-[#1c1c21] text-xs transition-colors"
          >
            <svg className="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
              <path strokeLinecap="round" strokeLinejoin="round" d="m21 21-4.35-4.35M17 11A6 6 0 1 1 5 11a6 6 0 0 1 12 0z" />
            </svg>
            <span>Search</span>
            <kbd className="ml-1 px-1 py-0.5 rounded bg-[#2a2a32] text-[10px] text-zinc-500">{isMac ? "⌘K" : "Ctrl+K"}</kbd>
          </button>
          <button
            onClick={() => setSettingsOpen(!settingsOpen)}
            className={`flex items-center gap-1.5 px-2.5 py-1 rounded-md text-xs transition-colors ${
              settingsOpen ? "text-zinc-200 bg-[#1c1c21]" : "text-zinc-400 hover:text-zinc-200 hover:bg-[#1c1c21]"
            }`}
          >
            <svg className="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 0 0 2.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 0 0 1.065 2.572c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 0 0-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 0 0-2.572 1.065c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 0 0-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 0 0-1.065-2.572c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 0 0 1.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z" />
              <path strokeLinecap="round" strokeLinejoin="round" d="M15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0z" />
            </svg>
          </button>
          <button
            onClick={() => setNewTaskOpen(true)}
            className="flex items-center gap-1 px-2.5 py-1 rounded-md bg-[#4f8ef7] hover:bg-[#5b97fa] text-white text-xs font-medium transition-colors"
          >
            <svg className="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2.5}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M12 4v16m8-8H4" />
            </svg>
            New Task
          </button>
        </div>
      </header>

      {/* Main content */}
      <div className="flex flex-1 overflow-hidden">
        {settingsOpen ? (
          <SettingsView />
        ) : (
          <>
            <BoardView />
            {selectedCardId && <CardDetailView />}
          </>
        )}
      </div>

      {/* Overlays */}
      {searchOpen && <SearchOverlay />}
      {newTaskOpen && <NewTaskDialog />}

      {/* Error toast */}
      {error && (
        <div
          className="fixed bottom-4 right-4 max-w-sm bg-[#3d1a1a] border border-[#f85149]/30 text-[#f85149] px-4 py-3 rounded-lg text-sm shadow-lg cursor-pointer"
          onClick={clearError}
        >
          {error}
        </div>
      )}
    </div>
  );
}
