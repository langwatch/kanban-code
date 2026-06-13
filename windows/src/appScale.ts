import { useEffect, useState } from "react";

const STORAGE_KEY = "kanban.appScale";
const MIN = 0.7;
const MAX = 1.8;
const STEP = 0.1;
const DEFAULT = 1.0;

const listeners = new Set<(s: number) => void>();
let current = loadScale();

function loadScale(): number {
  if (typeof window === "undefined") return DEFAULT;
  const raw = window.localStorage.getItem(STORAGE_KEY);
  const n = raw ? parseFloat(raw) : DEFAULT;
  return clamp(Number.isFinite(n) ? n : DEFAULT);
}

function clamp(n: number): number {
  return Math.min(MAX, Math.max(MIN, Math.round(n * 100) / 100));
}

function persist(s: number) {
  current = s;
  window.localStorage.setItem(STORAGE_KEY, String(s));
  // Chromium-based webviews honor `zoom` on the root element. Match the
  // macOS AppScale behavior (everything grows together, no layout reflow
  // beyond what the zoom causes naturally).
  document.documentElement.style.zoom = String(s);
  listeners.forEach((fn) => fn(s));
}

export function getAppScale(): number {
  return current;
}

export function setAppScale(s: number) {
  persist(clamp(s));
}

export function bumpAppScale(delta: number) {
  persist(clamp(current + delta));
}

export function resetAppScale() {
  persist(DEFAULT);
}

export function useAppScale(): number {
  const [s, setS] = useState(current);
  useEffect(() => {
    const fn = (next: number) => setS(next);
    listeners.add(fn);
    return () => {
      listeners.delete(fn);
    };
  }, []);
  return s;
}

/// Install Ctrl/Cmd +/-/0 keyboard handlers app-wide. Returns a teardown.
export function installAppScaleShortcuts(): () => void {
  // Apply once at startup so a refreshed page restores the persisted zoom.
  persist(current);

  const onKey = (e: KeyboardEvent) => {
    const mod = e.metaKey || e.ctrlKey;
    if (!mod) return;
    // Equal / Plus / NumpadAdd → zoom in. "=" sits on the same key as "+"
    // on US layouts; checking both physical code and e.key keeps non-US
    // layouts working.
    if (e.code === "Equal" || e.code === "NumpadAdd" || e.key === "+" || e.key === "=") {
      e.preventDefault();
      bumpAppScale(STEP);
      return;
    }
    if (e.code === "Minus" || e.code === "NumpadSubtract" || e.key === "-" || e.key === "_") {
      e.preventDefault();
      bumpAppScale(-STEP);
      return;
    }
    if (e.code === "Digit0" || e.code === "Numpad0" || e.key === "0") {
      e.preventDefault();
      resetAppScale();
      return;
    }
  };
  window.addEventListener("keydown", onKey);
  return () => window.removeEventListener("keydown", onKey);
}
