import { useEffect, useState, type ReactNode } from "react";
import { getSettings, saveSettings, useBoardStore } from "../store/boardStore";
import type { Settings } from "../types";

export default function SettingsView() {
  const { setSettingsOpen } = useBoardStore();
  const [settings, setSettings] = useState<Settings | null>(null);
  const [saving, setSaving] = useState(false);
  const [saved, setSaved] = useState(false);
  const [activeSection, setActiveSection] = useState<"projects" | "general" | "github" | "notifications">("general");
  const [newProjectPath, setNewProjectPath] = useState("");

  useEffect(() => {
    getSettings().then(setSettings).catch(console.error);
  }, []);

  const handleSave = async () => {
    if (!settings) return;
    setSaving(true);
    try {
      await saveSettings(settings);
      setSaved(true);
      setTimeout(() => setSaved(false), 2000);
    } catch (e) {
      console.error(e);
    } finally {
      setSaving(false);
    }
  };

  if (!settings) {
    return (
      <div className="flex-1 flex items-center justify-center text-zinc-500 text-sm">
        Loading settings...
      </div>
    );
  }

  return (
    <div className="flex-1 flex flex-col overflow-hidden">
      {/* Header */}
      <div className="flex items-center justify-between px-6 py-4 border-b border-[#2a2a32] shrink-0">
        <h1 className="text-base font-semibold text-zinc-200">Settings</h1>
        <div className="flex items-center gap-2">
          {saved && (
            <span className="text-xs text-[#3fb950]">Saved</span>
          )}
          <button
            onClick={handleSave}
            disabled={saving}
            className="px-3 py-1.5 rounded-lg bg-[#4f8ef7] hover:bg-[#5b97fa] disabled:opacity-50 text-white text-xs font-medium transition-colors"
          >
            {saving ? "Saving..." : "Save"}
          </button>
          <button
            onClick={() => setSettingsOpen(false)}
            className="text-zinc-500 hover:text-zinc-300 ml-1"
          >
            <svg className="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M6 18 18 6M6 6l12 12" />
            </svg>
          </button>
        </div>
      </div>

      <div className="flex flex-1 overflow-hidden">
        {/* Sidebar */}
        <nav className="w-44 border-r border-[#2a2a32] py-3 shrink-0">
          {(["general", "projects", "github", "notifications"] as const).map(
            (section) => (
              <button
                key={section}
                onClick={() => setActiveSection(section)}
                className={`w-full text-left px-4 py-2 text-sm capitalize transition-colors ${
                  activeSection === section
                    ? "text-zinc-200 bg-[#1c1c21]"
                    : "text-zinc-500 hover:text-zinc-300"
                }`}
              >
                {section}
              </button>
            )
          )}
        </nav>

        {/* Content */}
        <div className="flex-1 overflow-y-auto p-6">
          {activeSection === "general" && (
            <GeneralSection settings={settings} onChange={setSettings} />
          )}
          {activeSection === "projects" && (
            <ProjectsSection
              settings={settings}
              onChange={setSettings}
              newPath={newProjectPath}
              setNewPath={setNewProjectPath}
            />
          )}
          {activeSection === "github" && (
            <GitHubSection settings={settings} onChange={setSettings} />
          )}
          {activeSection === "notifications" && (
            <NotificationsSection settings={settings} onChange={setSettings} />
          )}
        </div>
      </div>
    </div>
  );
}

function GeneralSection({
  settings,
  onChange,
}: {
  settings: Settings;
  onChange: (s: Settings) => void;
}) {
  return (
    <div className="flex flex-col gap-5 max-w-lg">
      <FieldGroup label="Editor command">
        <input
          type="text"
          value={settings.editor}
          onChange={(e) => onChange({ ...settings, editor: e.target.value })}
          placeholder="code"
          className="w-full bg-[#1c1c21] border border-[#2a2a32] focus:border-[#4f8ef7]/50 rounded-lg px-3 py-2 text-sm text-zinc-200 placeholder-zinc-600 outline-none"
        />
        <p className="text-[11px] text-zinc-500 mt-1">
          e.g. <code className="font-mono">code</code>, <code className="font-mono">cursor</code>, <code className="font-mono">nvim</code>
        </p>
      </FieldGroup>

      <FieldGroup label="Session timeout (minutes)">
        <input
          type="number"
          value={settings.sessionTimeout.activeThresholdMinutes}
          onChange={(e) =>
            onChange({
              ...settings,
              sessionTimeout: {
                ...settings.sessionTimeout,
                activeThresholdMinutes: parseInt(e.target.value) || 1440,
              },
            })
          }
          className="w-32 bg-[#1c1c21] border border-[#2a2a32] focus:border-[#4f8ef7]/50 rounded-lg px-3 py-2 text-sm text-zinc-200 outline-none"
        />
      </FieldGroup>

      <FieldGroup label="Prompt template">
        <textarea
          rows={3}
          value={settings.promptTemplate}
          onChange={(e) =>
            onChange({ ...settings, promptTemplate: e.target.value })
          }
          placeholder="Optional default prompt prefix..."
          className="w-full bg-[#1c1c21] border border-[#2a2a32] focus:border-[#4f8ef7]/50 rounded-lg px-3 py-2 text-sm text-zinc-200 placeholder-zinc-600 outline-none resize-none"
        />
      </FieldGroup>
    </div>
  );
}

function ProjectsSection({
  settings,
  onChange,
  newPath,
  setNewPath,
}: {
  settings: Settings;
  onChange: (s: Settings) => void;
  newPath: string;
  setNewPath: (p: string) => void;
}) {
  const addProject = () => {
    if (!newPath.trim()) return;
    if (settings.projects.find((p) => p.path === newPath.trim())) return;
    onChange({
      ...settings,
      projects: [...settings.projects, { path: newPath.trim() }],
    });
    setNewPath("");
  };

  const removeProject = (path: string) => {
    onChange({
      ...settings,
      projects: settings.projects.filter((p) => p.path !== path),
    });
  };

  return (
    <div className="flex flex-col gap-4 max-w-lg">
      <div className="flex gap-2">
        <input
          type="text"
          value={newPath}
          onChange={(e) => setNewPath(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && addProject()}
          placeholder="/path/to/project"
          className="flex-1 bg-[#1c1c21] border border-[#2a2a32] focus:border-[#4f8ef7]/50 rounded-lg px-3 py-2 text-sm text-zinc-200 placeholder-zinc-600 outline-none"
        />
        <button
          onClick={addProject}
          className="px-3 py-2 rounded-lg bg-[#4f8ef7] hover:bg-[#5b97fa] text-white text-xs font-medium transition-colors"
        >
          Add
        </button>
      </div>

      {settings.projects.length === 0 && (
        <p className="text-sm text-zinc-500">No projects configured yet.</p>
      )}

      <div className="flex flex-col gap-1.5">
        {settings.projects.map((p) => (
          <div
            key={p.path}
            className="flex items-center justify-between px-3 py-2.5 bg-[#1c1c21] border border-[#2a2a32] rounded-lg"
          >
            <div>
              <p className="text-sm text-zinc-300">
                {p.name ?? p.path.split("/").pop() ?? p.path}
              </p>
              <p className="text-xs text-zinc-500 font-mono">{p.path}</p>
            </div>
            <button
              onClick={() => removeProject(p.path)}
              className="text-zinc-600 hover:text-[#f85149] transition-colors ml-3"
            >
              <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M6 18 18 6M6 6l12 12" />
              </svg>
            </button>
          </div>
        ))}
      </div>
    </div>
  );
}

function GitHubSection({
  settings,
  onChange,
}: {
  settings: Settings;
  onChange: (s: Settings) => void;
}) {
  return (
    <div className="flex flex-col gap-5 max-w-lg">
      <FieldGroup label="Default issue filter">
        <input
          type="text"
          value={settings.github.defaultFilter}
          onChange={(e) =>
            onChange({
              ...settings,
              github: { ...settings.github, defaultFilter: e.target.value },
            })
          }
          placeholder="assignee:@me is:open"
          className="w-full bg-[#1c1c21] border border-[#2a2a32] focus:border-[#4f8ef7]/50 rounded-lg px-3 py-2 text-sm text-zinc-200 placeholder-zinc-600 outline-none"
        />
      </FieldGroup>
      <FieldGroup label="Poll interval (seconds)">
        <input
          type="number"
          value={settings.github.pollIntervalSeconds}
          onChange={(e) =>
            onChange({
              ...settings,
              github: {
                ...settings.github,
                pollIntervalSeconds: parseInt(e.target.value) || 60,
              },
            })
          }
          className="w-32 bg-[#1c1c21] border border-[#2a2a32] focus:border-[#4f8ef7]/50 rounded-lg px-3 py-2 text-sm text-zinc-200 outline-none"
        />
      </FieldGroup>
      <FieldGroup label="Merge command">
        <input
          type="text"
          value={settings.github.mergeCommand}
          onChange={(e) =>
            onChange({
              ...settings,
              github: { ...settings.github, mergeCommand: e.target.value },
            })
          }
          className="w-full bg-[#1c1c21] border border-[#2a2a32] focus:border-[#4f8ef7]/50 rounded-lg px-3 py-2 text-sm text-zinc-200 font-mono outline-none"
        />
      </FieldGroup>
    </div>
  );
}

function NotificationsSection({
  settings,
  onChange,
}: {
  settings: Settings;
  onChange: (s: Settings) => void;
}) {
  return (
    <div className="flex flex-col gap-5 max-w-lg">
      <Toggle
        checked={settings.notifications.notificationsEnabled}
        onChange={(v) =>
          onChange({
            ...settings,
            notifications: { ...settings.notifications, notificationsEnabled: v },
          })
        }
        label="Enable OS notifications"
        description="Show a system notification when Claude finishes a turn and needs your input"
      />

      <Toggle
        checked={settings.notifications.pushoverEnabled}
        onChange={(v) =>
          onChange({
            ...settings,
            notifications: { ...settings.notifications, pushoverEnabled: v },
          })
        }
        label="Enable Pushover notifications"
      />

      {settings.notifications.pushoverEnabled && (
        <>
          <FieldGroup label="Pushover token (optional — macOS app feature)">
            <input
              type="password"
              value={settings.notifications.pushoverToken ?? ""}
              onChange={(e) =>
                onChange({
                  ...settings,
                  notifications: {
                    ...settings.notifications,
                    pushoverToken: e.target.value || undefined,
                  },
                })
              }
              className="w-full bg-[#1c1c21] border border-[#2a2a32] focus:border-[#4f8ef7]/50 rounded-lg px-3 py-2 text-sm text-zinc-200 placeholder-zinc-600 outline-none font-mono"
            />
          </FieldGroup>
          <FieldGroup label="Pushover user key">
            <input
              type="password"
              value={settings.notifications.pushoverUserKey ?? ""}
              onChange={(e) =>
                onChange({
                  ...settings,
                  notifications: {
                    ...settings.notifications,
                    pushoverUserKey: e.target.value || undefined,
                  },
                })
              }
              className="w-full bg-[#1c1c21] border border-[#2a2a32] focus:border-[#4f8ef7]/50 rounded-lg px-3 py-2 text-sm text-zinc-200 placeholder-zinc-600 outline-none font-mono"
            />
          </FieldGroup>
        </>
      )}
    </div>
  );
}

function Toggle({
  checked,
  onChange,
  label,
  description,
}: {
  checked: boolean;
  onChange: (v: boolean) => void;
  label: string;
  description?: string;
}) {
  return (
    <div className="flex items-start gap-3">
      <label className="relative inline-flex cursor-pointer mt-0.5 shrink-0">
        <input
          type="checkbox"
          checked={checked}
          onChange={(e) => onChange(e.target.checked)}
          className="sr-only"
        />
        <div
          className={`w-9 h-5 rounded-full transition-colors ${
            checked ? "bg-[#4f8ef7]" : "bg-[#2a2a32]"
          }`}
        >
          <div
            className={`w-4 h-4 bg-white rounded-full shadow mt-0.5 transition-transform ${
              checked ? "translate-x-4" : "translate-x-0.5"
            }`}
          />
        </div>
      </label>
      <div>
        <span className="text-sm text-zinc-300">{label}</span>
        {description && (
          <p className="text-[11px] text-zinc-500 mt-0.5">{description}</p>
        )}
      </div>
    </div>
  );
}

function FieldGroup({
  label,
  children,
}: {
  label: string;
  children: ReactNode;
}) {
  return (
    <div>
      <label className="block text-xs font-medium text-zinc-400 mb-1.5">
        {label}
      </label>
      {children}
    </div>
  );
}
