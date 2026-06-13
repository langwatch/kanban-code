import { useCallback, useEffect, useRef, useState } from "react";
import BoardView from "./components/BoardView";
import ListBoardView from "./components/ListBoardView";
import CardDetailView from "./components/CardDetailView";
import NewTaskDialog from "./components/NewTaskDialog";
import OnboardingWizard from "./components/OnboardingWizard";
import ProjectSwitcher from "./components/ProjectSwitcher";
import SearchOverlay from "./components/SearchOverlay";
import SettingsView from "./components/SettingsView";
import { getSettings, initBoardEventListener, useBoardStore } from "./store/boardStore";
import { useTheme, t } from "./theme";
import { installAppScaleShortcuts } from "./appScale";

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
    selectCard,
    setSearchOpen,
    setNewTaskOpen,
    setSettingsOpen,
    syncStatus,
    viewMode,
    setViewMode,
  } = useBoardStore();

  const [showOnboarding, setShowOnboarding] = useState<boolean | null>(null);

  const { theme, toggle } = useTheme();
  const c = t(theme);
  const rippleRef = useRef<HTMLDivElement>(null);

  const handleThemeToggle = useCallback((e: React.MouseEvent) => {
    const btn = e.currentTarget.getBoundingClientRect();
    const x = btn.left + btn.width / 2;
    const y = btn.top + btn.height / 2;
    const maxRadius = Math.hypot(
      Math.max(x, window.innerWidth - x),
      Math.max(y, window.innerHeight - y)
    );

    const ripple = rippleRef.current;
    if (!ripple) { toggle(); return; }

    const nextBg = theme === "dark" ? "#f5f5f7" : "#0a0a0c";
    ripple.style.left = `${x}px`;
    ripple.style.top = `${y}px`;
    ripple.style.background = nextBg;
    ripple.style.width = "0px";
    ripple.style.height = "0px";
    ripple.style.opacity = "1";
    ripple.style.transform = "translate(-50%, -50%) scale(0)";
    ripple.style.display = "block";

    // Force reflow
    ripple.offsetHeight;

    ripple.style.transition = "transform 0.5s cubic-bezier(0.4, 0, 0.2, 1), opacity 0.5s ease";
    ripple.style.width = `${maxRadius * 2}px`;
    ripple.style.height = `${maxRadius * 2}px`;
    ripple.style.transform = "translate(-50%, -50%) scale(1)";

    setTimeout(() => {
      toggle();
      ripple.style.transition = "opacity 0.15s ease";
      ripple.style.opacity = "0";
      setTimeout(() => { ripple.style.display = "none"; }, 150);
    }, 350);
  }, [theme, toggle]);

  useEffect(() => {
    refresh();
    initBoardEventListener();
    const teardownScale = installAppScaleShortcuts();
    getSettings()
      .then((s) => setShowOnboarding(!s.hasCompletedOnboarding))
      .catch(() => setShowOnboarding(false));
    return teardownScale;
  }, []);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const mod = e.metaKey || e.ctrlKey;
      // Match on physical key location (e.code) AND e.key so non-US
      // keyboard layouts (where "," sits behind shift, etc.) still work.
      const keyLower = e.key.length === 1 ? e.key.toLowerCase() : e.key;

      if (mod && (e.code === "KeyK" || keyLower === "k")) {
        e.preventDefault();
        setSearchOpen(true);
        return;
      }
      if (mod && (e.code === "KeyN" || keyLower === "n")) {
        e.preventDefault();
        setNewTaskOpen(true);
        return;
      }
      // Ctrl+, (or Cmd+,) — toggle settings, mirroring the macOS app.
      // Multiple matches: physical key location, e.key, deprecated keyCode
      // (188 = comma). Any one of them triggers, so we're robust to
      // keyboard layout quirks and platforms that drop e.key under Ctrl.
      if (mod && (e.code === "Comma" || keyLower === "," || e.keyCode === 188)) {
        e.preventDefault();
        const { settingsOpen: open } = useBoardStore.getState();
        setSettingsOpen(!open);
        return;
      }
      if (e.key === "Escape" || e.code === "Escape") {
        // Close in stack order: dialog > settings > drawer. Each branch
        // returns so a single Esc only dismisses the topmost layer.
        const s = useBoardStore.getState();
        if (s.newTaskOpen) { setNewTaskOpen(false); return; }
        if (s.searchOpen) { setSearchOpen(false); return; }
        if (s.settingsOpen) { setSettingsOpen(false); return; }
        if (s.selectedCardId) { selectCard(null); return; }
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [selectCard, setNewTaskOpen, setSearchOpen, setSettingsOpen]);

  return (
    <div className="flex flex-col h-full overflow-hidden" style={{ background: c.bg, color: c.text }}>
      {/* Header */}
      <header
        className="flex items-center justify-between px-4 h-12 shrink-0"
        style={{ background: c.bgHeader, borderBottom: `1px solid ${c.border}` }}
      >
        <div className="flex items-center gap-3">
          <div className="flex items-center gap-2.5">
            <div className="w-3.5 h-3.5 rounded bg-gradient-to-br from-[#4f8ef7] to-[#a371f7]" />
            <span className="text-[15px] font-semibold" style={{ color: c.textPrimary }}>
              Kanban Code
            </span>
          </div>
          <ProjectSwitcher />
        </div>

        <div className="flex items-center gap-2">
          {syncStatus.kind !== "disabled" && (
            <button
              onClick={() => setSettingsOpen(true)}
              title={syncStatus.message ? `Mutagen: ${syncStatus.message}` : `Mutagen: ${syncStatus.kind}`}
              className="flex items-center gap-1.5 px-2.5 py-1 rounded-full text-[11px] transition-colors"
              style={{
                background: syncPillBg(syncStatus.kind),
                color: syncPillFg(syncStatus.kind),
                border: `1px solid ${c.border}`,
              }}
            >
              <span
                className="w-1.5 h-1.5 rounded-full"
                style={{ background: syncPillFg(syncStatus.kind) }}
              />
              {syncPillLabel(syncStatus.kind, syncStatus.conflictCount)}
            </button>
          )}
          {/* Board / List view toggle */}
          <div
            className="flex items-center rounded-lg p-0.5"
            style={{ background: c.bgAccent("0.05"), border: `1px solid ${c.border}` }}
          >
            {(["board", "list"] as const).map((m) => {
              const active = viewMode === m;
              return (
                <button
                  key={m}
                  onClick={() => setViewMode(m)}
                  className="px-2.5 py-1 rounded-md text-[12px] font-medium transition-colors"
                  style={{
                    background: active ? c.bgCard : "transparent",
                    color: active ? c.textPrimary : c.textMuted,
                    border: active ? `1px solid ${c.borderBright}` : "1px solid transparent",
                  }}
                  title={m === "board" ? "Board view" : "List view"}
                >
                  {m === "board" ? "Board" : "List"}
                </button>
              );
            })}
          </div>
          <button
            onClick={() => setSearchOpen(true)}
            className="flex items-center gap-2 px-3 py-1.5 rounded-lg transition-colors"
            style={{ color: c.textMuted }}
            onMouseEnter={(e) => { e.currentTarget.style.background = c.hoverBg; e.currentTarget.style.color = c.textPrimary; }}
            onMouseLeave={(e) => { e.currentTarget.style.background = ""; e.currentTarget.style.color = c.textMuted; }}
          >
            <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
              <path strokeLinecap="round" strokeLinejoin="round" d="m21 21-4.35-4.35M17 11A6 6 0 1 1 5 11a6 6 0 0 1 12 0z" />
            </svg>
            <span className="text-[13px]">Search</span>
            <kbd
              className="px-1.5 py-0.5 rounded text-[11px] font-mono"
              style={{ background: c.bgAccent("0.05"), border: `1px solid ${c.border}`, color: c.textDim }}
            >
              {isMac ? "\u2318K" : "Ctrl+K"}
            </kbd>
          </button>

          {/* Theme toggle */}
          <button
            onClick={handleThemeToggle}
            className="p-2 rounded-lg transition-colors"
            style={{ color: c.textMuted }}
            onMouseEnter={(e) => { e.currentTarget.style.background = c.hoverBg; }}
            onMouseLeave={(e) => { e.currentTarget.style.background = ""; }}
            title={theme === "dark" ? "Switch to light mode" : "Switch to dark mode"}
          >
            {theme === "dark" ? (
              <svg className="w-[18px] h-[18px]" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M12 3v2.25m6.364.386-1.591 1.591M21 12h-2.25m-.386 6.364-1.591-1.591M12 18.75V21m-4.773-4.227-1.591 1.591M5.25 12H3m4.227-4.773L5.636 5.636M15.75 12a3.75 3.75 0 1 1-7.5 0 3.75 3.75 0 0 1 7.5 0Z" />
              </svg>
            ) : (
              <svg className="w-[18px] h-[18px]" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M21.752 15.002A9.72 9.72 0 0 1 18 15.75c-5.385 0-9.75-4.365-9.75-9.75 0-1.33.266-2.597.748-3.752A9.753 9.753 0 0 0 3 11.25C3 16.635 7.365 21 12.75 21a9.753 9.753 0 0 0 9.002-5.998Z" />
              </svg>
            )}
          </button>

          <button
            onClick={() => setSettingsOpen(!settingsOpen)}
            className="p-2 rounded-lg transition-colors"
            style={{
              color: settingsOpen ? c.textPrimary : c.textMuted,
              background: settingsOpen ? c.hoverBg : "",
            }}
            onMouseEnter={(e) => { if (!settingsOpen) e.currentTarget.style.background = c.hoverBg; }}
            onMouseLeave={(e) => { if (!settingsOpen) e.currentTarget.style.background = ""; }}
          >
            <svg className="w-[18px] h-[18px]" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 0 0 2.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 0 0 1.065 2.572c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 0 0-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 0 0-2.572 1.065c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 0 0-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 0 0-1.065-2.572c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 0 0 1.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z" />
              <path strokeLinecap="round" strokeLinejoin="round" d="M15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0z" />
            </svg>
          </button>

          <button
            onClick={() => setNewTaskOpen(true)}
            className="flex items-center gap-1.5 px-3.5 py-1.5 rounded-lg bg-[#4f8ef7] hover:bg-[#5b97fa] text-white text-[13px] font-semibold transition-colors"
          >
            <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2.5}>
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
            {viewMode === "list" ? <ListBoardView /> : <BoardView />}
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
          className="fixed bottom-5 right-5 max-w-sm px-4 py-3 rounded-xl text-[13px] shadow-xl cursor-pointer animate-slide-up"
          style={{
            background: theme === "dark" ? "#2a1215" : "#fef2f2",
            border: `1px solid ${theme === "dark" ? "rgba(248,81,73,0.25)" : "rgba(248,81,73,0.3)"}`,
            color: "#f85149",
          }}
          onClick={clearError}
        >
          {error}
        </div>
      )}

      {/* Theme ripple overlay */}
      <div
        ref={rippleRef}
        style={{
          display: "none",
          position: "fixed",
          borderRadius: "50%",
          pointerEvents: "none",
          zIndex: 9999,
          opacity: 0,
        }}
      />

      {/* Onboarding wizard for first-time users */}
      {showOnboarding && (
        <OnboardingWizard onComplete={() => setShowOnboarding(false)} />
      )}
    </div>
  );
}

function syncPillLabel(kind: string, conflicts: number): string {
  if (kind === "conflicts") return `Conflicts (${conflicts})`;
  return kind.charAt(0).toUpperCase() + kind.slice(1);
}
function syncPillBg(kind: string): string {
  switch (kind) {
    case "watching": return "rgba(63, 185, 80, 0.10)";
    case "scanning":
    case "staging": return "rgba(79, 142, 247, 0.12)";
    case "conflicts": return "rgba(255, 133, 88, 0.14)";
    case "paused": return "rgba(160, 160, 170, 0.10)";
    case "error": return "rgba(255, 85, 85, 0.12)";
    default: return "transparent";
  }
}
function syncPillFg(kind: string): string {
  switch (kind) {
    case "watching": return "#3fb950";
    case "scanning":
    case "staging": return "#4f8ef7";
    case "conflicts": return "#ff8c5a";
    case "paused": return "#a0a0aa";
    case "error": return "#ff5555";
    default: return "#777";
  }
}
