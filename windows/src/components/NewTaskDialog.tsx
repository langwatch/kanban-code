import { useEffect, useRef, useState } from "react";
import { getSettings, useBoardStore } from "../store/boardStore";
import { useTheme, t } from "../theme";
import { ASSISTANT_DISPLAY, type AssistantId } from "../types";

export default function NewTaskDialog() {
  const { createCard, setNewTaskOpen, selectCard, cards } = useBoardStore();
  const { theme } = useTheme();
  const c = t(theme);
  const [prompt, setPrompt] = useState("");
  const [title, setTitle] = useState("");
  const [project, setProject] = useState("");
  const [launch, setLaunch] = useState(true);
  const [assistantId, setAssistantId] = useState<AssistantId>("claude");
  const [submitting, setSubmitting] = useState(false);
  const [settingsProjects, setSettingsProjects] = useState<string[]>([]);
  const promptRef = useRef<HTMLTextAreaElement>(null);

  const cardProjects = [
    ...new Set(
      cards
        .map((c) => c.link.projectPath ?? c.session?.projectPath)
        .filter(Boolean) as string[]
    ),
  ];

  const projects = [...new Set([...settingsProjects, ...cardProjects])].slice(0, 30);

  useEffect(() => {
    promptRef.current?.focus();
    getSettings()
      .then((s) => {
        const paths = s.projects.map((p) => p.path).filter(Boolean);
        setSettingsProjects(paths);
        if (!project && paths.length > 0) {
          setProject(paths[0]);
        }
      })
      .catch(console.error);
    if (cardProjects.length > 0 && !project) {
      setProject(cardProjects[0]);
    }
  }, []);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!prompt.trim()) return;
    setSubmitting(true);
    try {
      const cardId = await createCard(prompt.trim(), title.trim() || null, project || ".", launch, assistantId);
      setNewTaskOpen(false);
      if (launch && cardId) {
        selectCard(cardId);
      }
    } finally {
      setSubmitting(false);
    }
  };

  const inputStyle: React.CSSProperties = {
    background: c.bgInput,
    border: `1px solid ${c.border}`,
    color: c.textPrimary,
  };

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center animate-fade-in"
      style={{ background: c.bgOverlay }}
      onClick={() => setNewTaskOpen(false)}
    >
      <div
        className="w-[520px] rounded-xl shadow-2xl animate-slide-up"
        style={{
          background: c.bgDialog,
          border: `1px solid ${c.borderBright}`,
        }}
        onClick={(e) => e.stopPropagation()}
      >
        {/* Header */}
        <div
          className="flex items-center justify-between px-5 py-4"
          style={{ borderBottom: `1px solid ${c.border}` }}
        >
          <h2 className="text-[16px] font-semibold" style={{ color: c.textPrimary }}>New Task</h2>
          <button
            onClick={() => setNewTaskOpen(false)}
            className="transition-colors"
            style={{ color: c.textMuted }}
            onMouseEnter={(e) => { e.currentTarget.style.color = c.textPrimary; }}
            onMouseLeave={(e) => { e.currentTarget.style.color = c.textMuted; }}
          >
            <svg className="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M6 18 18 6M6 6l12 12" />
            </svg>
          </button>
        </div>

        <form onSubmit={handleSubmit} className="px-5 py-5 flex flex-col gap-5">
          <div>
            <label className="block text-[13px] font-medium mb-2" style={{ color: c.textSecondary }}>Prompt</label>
            <textarea
              ref={promptRef}
              rows={4}
              placeholder="Describe the task for Claude..."
              value={prompt}
              onChange={(e) => setPrompt(e.target.value)}
              className="w-full rounded-lg px-3.5 py-3 text-[14px] outline-none resize-none transition-colors leading-relaxed"
              style={inputStyle}
            />
          </div>

          <div>
            <label className="block text-[13px] font-medium mb-2" style={{ color: c.textSecondary }}>
              Title <span className="font-normal" style={{ color: c.textDim }}>(optional)</span>
            </label>
            <input
              type="text"
              placeholder="Short title for the board card"
              value={title}
              onChange={(e) => setTitle(e.target.value)}
              className="w-full rounded-lg px-3.5 py-2.5 text-[14px] outline-none transition-colors"
              style={inputStyle}
            />
          </div>

          <div>
            <label className="block text-[13px] font-medium mb-2" style={{ color: c.textSecondary }}>Project</label>
            {projects.length > 0 ? (
              <select
                value={project}
                onChange={(e) => setProject(e.target.value)}
                className="w-full rounded-lg px-3.5 py-2.5 text-[14px] outline-none transition-colors"
                style={inputStyle}
              >
                {projects.map((p) => (
                  <option key={p} value={p}>
                    {p.split(/[/\\]/).pop() ?? p}
                  </option>
                ))}
              </select>
            ) : (
              <input
                type="text"
                placeholder="C:\path\to\project"
                value={project}
                onChange={(e) => setProject(e.target.value)}
                className="w-full rounded-lg px-3.5 py-2.5 text-[14px] outline-none transition-colors"
                style={inputStyle}
              />
            )}
          </div>

          <div>
            <label className="block text-[13px] font-medium mb-2" style={{ color: c.textSecondary }}>
              Assistant
            </label>
            <div
              className="inline-flex items-center rounded-lg p-0.5"
              style={{ background: c.bgAccent("0.05"), border: `1px solid ${c.border}` }}
            >
              {(Object.keys(ASSISTANT_DISPLAY) as AssistantId[]).map((id) => {
                const active = assistantId === id;
                return (
                  <button
                    key={id}
                    type="button"
                    onClick={() => setAssistantId(id)}
                    className="px-3 py-1 rounded-md text-[12px] font-medium transition-colors"
                    style={{
                      background: active ? c.bgCard : "transparent",
                      color: active ? c.textPrimary : c.textMuted,
                      border: active ? `1px solid ${c.borderBright}` : "1px solid transparent",
                    }}
                  >
                    {ASSISTANT_DISPLAY[id]}
                  </button>
                );
              })}
            </div>
            {assistantId === "gemini" && (
              <p className="mt-2 text-[11.5px]" style={{ color: c.textDim }}>
                Gemini support is minimal in this build — the embedded terminal
                will invoke <code>gemini</code> from PATH. Activity detection
                and hooks remain Claude-only.
              </p>
            )}
          </div>

          <label className="flex items-center gap-3 cursor-pointer select-none">
            <input
              type="checkbox"
              checked={launch}
              onChange={(e) => setLaunch(e.target.checked)}
              className="w-4 h-4 rounded accent-[#4f8ef7]"
            />
            <span className="text-[13px]" style={{ color: c.textSecondary }}>Start immediately in terminal</span>
          </label>

          <div className="flex gap-3 pt-1">
            <button
              type="button"
              onClick={() => setNewTaskOpen(false)}
              className="flex-1 py-2.5 rounded-lg text-[13px] transition-colors"
              style={{ border: `1px solid ${c.border}`, color: c.textMuted }}
              onMouseEnter={(e) => { e.currentTarget.style.background = c.hoverBg; e.currentTarget.style.color = c.textPrimary; }}
              onMouseLeave={(e) => { e.currentTarget.style.background = ""; e.currentTarget.style.color = c.textMuted; }}
            >
              Cancel
            </button>
            <button
              type="submit"
              disabled={!prompt.trim() || submitting}
              className="flex-1 py-2.5 rounded-lg bg-[#4f8ef7] hover:bg-[#5b97fa] disabled:opacity-40 text-white text-[13px] font-semibold transition-colors"
            >
              {submitting ? "Creating..." : launch ? "Create & Start" : "Create Task"}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}
