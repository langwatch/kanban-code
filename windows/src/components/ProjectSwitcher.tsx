import { useEffect, useMemo, useRef, useState } from "react";
import { getSettings, useBoardStore } from "../store/boardStore";
import { useTheme, t } from "../theme";
import type { Project } from "../types";

export default function ProjectSwitcher() {
  const { cards, selectedProjectPath, setSelectedProject } = useBoardStore();
  const { theme } = useTheme();
  const c = t(theme);

  const [open, setOpen] = useState(false);
  const [projects, setProjects] = useState<Project[]>([]);
  const buttonRef = useRef<HTMLButtonElement>(null);
  const menuRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    getSettings()
      .then((s) => setProjects(s.projects))
      .catch(() => {});
  }, []);

  useEffect(() => {
    if (!open) return;
    const onDown = (e: MouseEvent) => {
      const target = e.target as Node;
      if (buttonRef.current?.contains(target)) return;
      if (menuRef.current?.contains(target)) return;
      setOpen(false);
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setOpen(false);
    };
    window.addEventListener("mousedown", onDown);
    window.addEventListener("keydown", onKey);
    return () => {
      window.removeEventListener("mousedown", onDown);
      window.removeEventListener("keydown", onKey);
    };
  }, [open]);

  const countsByPath = useMemo(() => {
    const m = new Map<string, number>();
    for (const card of cards) {
      const p = card.link.projectPath ?? card.session?.projectPath;
      if (!p) continue;
      m.set(p, (m.get(p) ?? 0) + 1);
    }
    return m;
  }, [cards]);

  const projectCount = (proj: Project): number => {
    let n = 0;
    countsByPath.forEach((v, key) => {
      if (
        key === proj.path ||
        key.startsWith(proj.path + "/") ||
        key.startsWith(proj.path + "\\")
      ) {
        n += v;
      }
    });
    return n;
  };

  const selectedProject = projects.find((p) => p.path === selectedProjectPath);
  const label =
    selectedProject?.name ??
    (selectedProject ? selectedProject.path.split(/[/\\]/).pop() ?? selectedProject.path : "All Projects");
  const labelCount = selectedProject ? projectCount(selectedProject) : cards.length;

  const handleSelect = (path: string | null) => {
    setSelectedProject(path);
    setOpen(false);
  };

  return (
    <div className="relative">
      <button
        ref={buttonRef}
        onClick={() => setOpen((o) => !o)}
        className="flex items-center gap-1.5 px-2.5 py-1 rounded-lg transition-colors"
        style={{
          color: c.textPrimary,
          background: open ? c.hoverBg : "transparent",
          border: `1px solid ${open ? c.borderBright : c.border}`,
        }}
        onMouseEnter={(e) => {
          if (!open) e.currentTarget.style.background = c.hoverBg;
        }}
        onMouseLeave={(e) => {
          if (!open) e.currentTarget.style.background = "transparent";
        }}
        title="Filter cards by project"
      >
        <svg
          className="w-3.5 h-3.5"
          style={{ color: c.textMuted }}
          fill="none"
          viewBox="0 0 24 24"
          stroke="currentColor"
          strokeWidth={1.8}
        >
          <path
            strokeLinecap="round"
            strokeLinejoin="round"
            d="M2.25 12.75V12A2.25 2.25 0 0 1 4.5 9.75h15A2.25 2.25 0 0 1 21.75 12v.75m-8.69-6.44-2.12-2.12a1.5 1.5 0 0 0-1.061-.44H4.5A2.25 2.25 0 0 0 2.25 6v12a2.25 2.25 0 0 0 2.25 2.25h15A2.25 2.25 0 0 0 21.75 18V9a2.25 2.25 0 0 0-2.25-2.25h-5.379a1.5 1.5 0 0 1-1.06-.44Z"
          />
        </svg>
        <span className="text-[13px] font-medium max-w-[180px] truncate">{label}</span>
        <span
          className="text-[11px] px-1.5 rounded-full"
          style={{ background: c.bgAccent("0.08"), color: c.textMuted }}
        >
          {labelCount}
        </span>
        <svg
          className={`w-3 h-3 transition-transform ${open ? "rotate-180" : ""}`}
          style={{ color: c.textMuted }}
          fill="none"
          viewBox="0 0 24 24"
          stroke="currentColor"
          strokeWidth={2}
        >
          <path strokeLinecap="round" strokeLinejoin="round" d="m19.5 8.25-7.5 7.5-7.5-7.5" />
        </svg>
      </button>

      {open && (
        <div
          ref={menuRef}
          className="absolute left-0 top-full mt-1.5 min-w-[240px] max-w-[360px] z-50 rounded-xl py-1 shadow-2xl animate-fade-in"
          style={{
            background: c.bgDialog,
            border: `1px solid ${c.borderBright}`,
            boxShadow:
              theme === "dark"
                ? "0 10px 30px rgba(0,0,0,0.55)"
                : "0 10px 30px rgba(0,0,0,0.15)",
          }}
        >
          <MenuRow
            label="All Projects"
            count={cards.length}
            selected={selectedProjectPath === null}
            onClick={() => handleSelect(null)}
            theme={c}
          />
          {projects.length > 0 && (
            <div
              className="my-1 mx-2 h-px"
              style={{ background: c.border }}
            />
          )}
          {projects.length === 0 && (
            <div
              className="px-3 py-2 text-[12px]"
              style={{ color: c.textDim }}
            >
              No projects configured yet. Add one in Settings.
            </div>
          )}
          {projects.map((p) => {
            const name = p.name ?? p.path.split(/[/\\]/).pop() ?? p.path;
            return (
              <MenuRow
                key={p.path}
                label={name}
                subtitle={p.path}
                count={projectCount(p)}
                selected={selectedProjectPath === p.path}
                onClick={() => handleSelect(p.path)}
                theme={c}
              />
            );
          })}
        </div>
      )}
    </div>
  );
}

function MenuRow({
  label,
  subtitle,
  count,
  selected,
  onClick,
  theme: c,
}: {
  label: string;
  subtitle?: string;
  count: number;
  selected: boolean;
  onClick: () => void;
  theme: ReturnType<typeof t>;
}) {
  return (
    <button
      onClick={onClick}
      className="w-full flex items-center gap-2.5 px-3 py-1.5 text-left transition-colors"
      style={{
        background: selected ? c.bgCardSelected : "transparent",
      }}
      onMouseEnter={(e) => {
        if (!selected) e.currentTarget.style.background = c.hoverBg;
      }}
      onMouseLeave={(e) => {
        if (!selected) e.currentTarget.style.background = "transparent";
      }}
    >
      <span
        className="w-3.5 h-3.5 flex-shrink-0 flex items-center justify-center"
        style={{ color: selected ? "#4f8ef7" : "transparent" }}
      >
        <svg fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2.5}>
          <path strokeLinecap="round" strokeLinejoin="round" d="m4.5 12.75 6 6 9-13.5" />
        </svg>
      </span>
      <span className="flex-1 min-w-0">
        <span
          className="block text-[13px] truncate"
          style={{ color: c.textPrimary, fontWeight: selected ? 600 : 400 }}
        >
          {label}
        </span>
        {subtitle && (
          <span
            className="block text-[10.5px] font-mono truncate"
            style={{ color: c.textDim }}
          >
            {subtitle}
          </span>
        )}
      </span>
      <span
        className="text-[11px] px-1.5 rounded-full flex-shrink-0"
        style={{ background: c.bgAccent("0.06"), color: c.textMuted }}
      >
        {count}
      </span>
    </button>
  );
}
