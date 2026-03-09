import { createContext, useContext, useEffect, useState, type ReactNode } from "react";

export type Theme = "dark" | "light";

const ThemeContext = createContext<{ theme: Theme; toggle: () => void }>({
  theme: "dark",
  toggle: () => {},
});

export function ThemeProvider({ children }: { children: ReactNode }) {
  const [theme, setTheme] = useState<Theme>(() => {
    return (localStorage.getItem("kanban-theme") as Theme) || "dark";
  });

  useEffect(() => {
    localStorage.setItem("kanban-theme", theme);
    document.documentElement.setAttribute("data-theme", theme);
  }, [theme]);

  const toggle = () => setTheme((t) => (t === "dark" ? "light" : "dark"));

  return (
    <ThemeContext.Provider value={{ theme, toggle }}>
      {children}
    </ThemeContext.Provider>
  );
}

export function useTheme() {
  return useContext(ThemeContext);
}

// Color tokens that vary by theme
export function t(theme: Theme) {
  const dark = theme === "dark";
  return {
    // Backgrounds
    bg: dark ? "#0a0a0c" : "#f5f5f7",
    bgHeader: dark ? "#0e0e11" : "#ffffff",
    bgColumn: dark ? "rgba(255,255,255,0.015)" : "rgba(0,0,0,0.025)",
    bgColumnHover: (accent: string) => dark ? `${accent}0a` : `${accent}08`,
    bgCard: dark ? "rgba(255,255,255,0.03)" : "#ffffff",
    bgCardHover: dark ? "rgba(255,255,255,0.05)" : "rgba(0,0,0,0.02)",
    bgCardSelected: dark ? "rgba(79,142,247,0.1)" : "rgba(79,142,247,0.08)",
    bgDetail: dark ? "#0d0d10" : "#fafafa",
    bgDialog: dark ? "#141417" : "#ffffff",
    bgInput: dark ? "#0a0a0c" : "#f0f0f3",
    bgOverlay: dark ? "rgba(0,0,0,0.55)" : "rgba(0,0,0,0.3)",
    bgContext: dark ? "#1a1a1f" : "#ffffff",
    bgBadge: (color: string) => dark ? color + "18" : color + "15",
    bgAccent: (opacity: string) => dark ? `rgba(255,255,255,${opacity})` : `rgba(0,0,0,${opacity})`,

    // Borders — GitHub-style thin white lines in dark mode
    border: dark ? "rgba(255,255,255,0.12)" : "rgba(0,0,0,0.08)",
    borderBright: dark ? "rgba(255,255,255,0.16)" : "rgba(0,0,0,0.12)",
    borderCard: dark ? "rgba(255,255,255,0.10)" : "rgba(0,0,0,0.06)",
    borderCardSelected: dark ? "rgba(79,142,247,0.35)" : "rgba(79,142,247,0.35)",

    // Text
    text: dark ? "#e4e4e7" : "#1a1a1a",
    textPrimary: dark ? "#e4e4e7" : "#111111",
    textSecondary: dark ? "#a1a1aa" : "#555555",
    textMuted: dark ? "#71717a" : "#888888",
    textDim: dark ? "#52525b" : "#aaaaaa",
    textInverse: dark ? "#0a0a0c" : "#ffffff",

    // Hover states
    hoverBg: dark ? "rgba(255,255,255,0.05)" : "rgba(0,0,0,0.04)",
  };
}
