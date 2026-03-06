import { useEffect, useRef, useState } from "react";
import { useBoardStore } from "../store/boardStore";

export default function NewTaskDialog() {
  const { createCard, setNewTaskOpen, cards } = useBoardStore();
  const [prompt, setPrompt] = useState("");
  const [title, setTitle] = useState("");
  const [project, setProject] = useState("");
  const [launch, setLaunch] = useState(true);
  const [submitting, setSubmitting] = useState(false);
  const promptRef = useRef<HTMLTextAreaElement>(null);

  // Collect unique project paths from existing cards
  const projects = [...new Set(
    cards
      .map((c) => c.link.projectPath ?? c.session?.projectPath)
      .filter(Boolean) as string[]
  )].slice(0, 20);

  useEffect(() => {
    promptRef.current?.focus();
    if (projects.length > 0 && !project) {
      setProject(projects[0]);
    }
  }, []);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!prompt.trim()) return;
    setSubmitting(true);
    try {
      await createCard(
        prompt.trim(),
        title.trim() || null,
        project || ".",
        launch
      );
      setNewTaskOpen(false);
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center"
      onClick={() => setNewTaskOpen(false)}
    >
      <div
        className="w-[480px] bg-[#141417] border border-[#3a3a44] rounded-xl shadow-2xl"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="px-5 py-4 border-b border-[#2a2a32]">
          <h2 className="text-sm font-semibold text-zinc-200">New Task</h2>
        </div>

        <form onSubmit={handleSubmit} className="px-5 py-4 flex flex-col gap-4">
          <div>
            <label className="block text-xs font-medium text-zinc-400 mb-1.5">
              Prompt
            </label>
            <textarea
              ref={promptRef}
              rows={4}
              placeholder="Describe the task for Claude..."
              value={prompt}
              onChange={(e) => setPrompt(e.target.value)}
              className="w-full bg-[#1c1c21] border border-[#2a2a32] focus:border-[#4f8ef7]/50 rounded-lg px-3 py-2 text-sm text-zinc-200 placeholder-zinc-600 outline-none resize-none transition-colors leading-relaxed"
            />
          </div>

          <div>
            <label className="block text-xs font-medium text-zinc-400 mb-1.5">
              Title <span className="text-zinc-600">(optional)</span>
            </label>
            <input
              type="text"
              placeholder="Short title for the board card"
              value={title}
              onChange={(e) => setTitle(e.target.value)}
              className="w-full bg-[#1c1c21] border border-[#2a2a32] focus:border-[#4f8ef7]/50 rounded-lg px-3 py-2 text-sm text-zinc-200 placeholder-zinc-600 outline-none transition-colors"
            />
          </div>

          <div>
            <label className="block text-xs font-medium text-zinc-400 mb-1.5">
              Project
            </label>
            {projects.length > 0 ? (
              <select
                value={project}
                onChange={(e) => setProject(e.target.value)}
                className="w-full bg-[#1c1c21] border border-[#2a2a32] focus:border-[#4f8ef7]/50 rounded-lg px-3 py-2 text-sm text-zinc-200 outline-none transition-colors"
              >
                {projects.map((p) => (
                  <option key={p} value={p}>
                    {p.split("/").pop() ?? p}
                  </option>
                ))}
              </select>
            ) : (
              <input
                type="text"
                placeholder="/path/to/project"
                value={project}
                onChange={(e) => setProject(e.target.value)}
                className="w-full bg-[#1c1c21] border border-[#2a2a32] focus:border-[#4f8ef7]/50 rounded-lg px-3 py-2 text-sm text-zinc-200 placeholder-zinc-600 outline-none transition-colors"
              />
            )}
          </div>

          <label className="flex items-center gap-2 cursor-pointer select-none">
            <input
              type="checkbox"
              checked={launch}
              onChange={(e) => setLaunch(e.target.checked)}
              className="w-3.5 h-3.5 rounded accent-[#4f8ef7]"
            />
            <span className="text-xs text-zinc-400">Start immediately in terminal</span>
          </label>

          <div className="flex gap-2 pt-1">
            <button
              type="button"
              onClick={() => setNewTaskOpen(false)}
              className="flex-1 py-2 rounded-lg border border-[#2a2a32] text-xs text-zinc-400 hover:text-zinc-200 hover:border-[#3a3a44] transition-colors"
            >
              Cancel
            </button>
            <button
              type="submit"
              disabled={!prompt.trim() || submitting}
              className="flex-1 py-2 rounded-lg bg-[#4f8ef7] hover:bg-[#5b97fa] disabled:opacity-40 text-white text-xs font-medium transition-colors"
            >
              {submitting ? "Creating..." : launch ? "Create & Start" : "Create Task"}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}
