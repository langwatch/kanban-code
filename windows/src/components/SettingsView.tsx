import { useEffect, useState, type ReactNode } from "react";
import { open } from "@tauri-apps/plugin-dialog";
import { getSettings, saveSettings, useBoardStore } from "../store/boardStore";
import { useTheme, t } from "../theme";
import type { Settings } from "../types";

type ThemeTokens = ReturnType<typeof t>;

function inputStyle(c: ThemeTokens): React.CSSProperties {
  return {
    background: c.bgAccent("0.03"),
    border: `1px solid ${c.border}`,
    color: c.textPrimary,
  };
}

export default function SettingsView() {
  const { setSettingsOpen } = useBoardStore();
  const { theme } = useTheme();
  const c = t(theme);
  const [settings, setSettings] = useState<Settings | null>(null);
  const [saving, setSaving] = useState(false);
  const [saved, setSaved] = useState(false);
  const [activeSection, setActiveSection] = useState<"projects" | "general" | "github" | "notifications">("general");

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
      <div className="flex-1 flex items-center justify-center">
        <div className="flex items-center gap-2">
          <div className="w-3 h-3 border-[1.5px] border-[#4f8ef7] border-t-transparent rounded-full animate-spin" />
          <span className="text-sm" style={{ color: c.textMuted }}>Loading settings...</span>
        </div>
      </div>
    );
  }

  const sections = ["general", "projects", "github", "notifications"] as const;
  const sectionIcons: Record<string, string> = {
    general: "M10.343 3.94c.09-.542.56-.94 1.11-.94h1.093c.55 0 1.02.398 1.11.94l.149.894c.07.424.384.764.78.93.398.164.855.142 1.205-.108l.737-.527a1.125 1.125 0 0 1 1.45.12l.773.774c.39.389.44 1.002.12 1.45l-.527.737c-.25.35-.272.806-.107 1.204.165.397.505.71.93.78l.893.15c.543.09.94.56.94 1.109v1.094c0 .55-.397 1.02-.94 1.11l-.893.149c-.425.07-.765.383-.93.78-.165.398-.143.854.107 1.204l.527.738c.32.447.269 1.06-.12 1.45l-.774.773a1.125 1.125 0 0 1-1.449.12l-.738-.527c-.35-.25-.806-.272-1.203-.107-.397.165-.71.505-.781.929l-.149.894c-.09.542-.56.94-1.11.94h-1.094c-.55 0-1.019-.398-1.11-.94l-.148-.894c-.071-.424-.384-.764-.781-.93-.398-.164-.854-.142-1.204.108l-.738.527c-.447.32-1.06.269-1.45-.12l-.773-.774a1.125 1.125 0 0 1-.12-1.45l.527-.737c.25-.35.273-.806.108-1.204-.165-.397-.505-.71-.93-.78l-.894-.15c-.542-.09-.94-.56-.94-1.109v-1.094c0-.55.398-1.02.94-1.11l.894-.149c.424-.07.765-.383.93-.78.165-.398.143-.854-.107-1.204l-.527-.738a1.125 1.125 0 0 1 .12-1.45l.773-.773a1.125 1.125 0 0 1 1.45-.12l.737.527c.35.25.807.272 1.204.107.397-.165.71-.505.78-.929l.15-.894Z M15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z",
    projects: "M2.25 12.75V12A2.25 2.25 0 0 1 4.5 9.75h15A2.25 2.25 0 0 1 21.75 12v.75m-8.69-6.44-2.12-2.12a1.5 1.5 0 0 0-1.061-.44H4.5A2.25 2.25 0 0 0 2.25 6v12a2.25 2.25 0 0 0 2.25 2.25h15A2.25 2.25 0 0 0 21.75 18V9a2.25 2.25 0 0 0-2.25-2.25h-5.379a1.5 1.5 0 0 1-1.06-.44Z",
    github: "M10 6H6a2 2 0 0 0-2 2v10a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-4M14 4h6m0 0v6m0-6L10 14",
    notifications: "M14.857 17.082a23.848 23.848 0 0 0 5.454-1.31A8.967 8.967 0 0 1 18 9.75V9A6 6 0 0 0 6 9v.75a8.967 8.967 0 0 1-2.312 6.022c1.733.64 3.56 1.085 5.455 1.31m5.714 0a24.255 24.255 0 0 1-5.714 0m5.714 0a3 3 0 1 1-5.714 0",
  };

  return (
    <div
      className="flex-1 flex flex-col overflow-hidden"
      style={{ background: c.bg, color: c.text }}
    >
      <div
        className="flex items-center justify-between px-6 py-4 shrink-0"
        style={{ borderBottom: `1px solid ${c.border}` }}
      >
        <div className="flex items-center gap-3">
          <button
            onClick={() => setSettingsOpen(false)}
            className="transition-colors"
            style={{ color: c.textMuted }}
            onMouseEnter={(e) => { e.currentTarget.style.color = c.textPrimary; }}
            onMouseLeave={(e) => { e.currentTarget.style.color = c.textMuted; }}
            title="Back to board"
          >
            <svg className="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M10.5 19.5 3 12m0 0 7.5-7.5M3 12h18" />
            </svg>
          </button>
          <h1 className="text-base font-semibold" style={{ color: c.textPrimary }}>Settings</h1>
        </div>
        <div className="flex items-center gap-2">
          {saved && (
            <span className="text-xs text-[#3fb950] animate-fade-in">Saved</span>
          )}
          <button
            onClick={handleSave}
            disabled={saving}
            className="px-4 py-1.5 rounded-xl bg-[#4f8ef7]/90 hover:bg-[#4f8ef7] disabled:opacity-50 text-white text-xs font-medium transition-all shadow-lg shadow-[#4f8ef7]/15"
          >
            {saving ? "Saving..." : "Save"}
          </button>
          <button
            onClick={() => setSettingsOpen(false)}
            className="ml-1 transition-colors"
            style={{ color: c.textMuted }}
            onMouseEnter={(e) => { e.currentTarget.style.color = c.textPrimary; }}
            onMouseLeave={(e) => { e.currentTarget.style.color = c.textMuted; }}
          >
            <svg className="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M6 18 18 6M6 6l12 12" />
            </svg>
          </button>
        </div>
      </div>

      <div className="flex flex-1 overflow-hidden">
        <nav
          className="w-48 py-3 shrink-0"
          style={{ borderRight: `1px solid ${c.border}` }}
        >
          {sections.map((section) => {
            const active = activeSection === section;
            return (
              <button
                key={section}
                onClick={() => setActiveSection(section)}
                className="w-full text-left px-4 py-2.5 text-sm capitalize transition-all flex items-center gap-2.5"
                style={{
                  color: active ? c.textPrimary : c.textMuted,
                  background: active ? c.hoverBg : "transparent",
                  borderRight: active ? "2px solid #4f8ef7" : "2px solid transparent",
                }}
                onMouseEnter={(e) => {
                  if (!active) { e.currentTarget.style.background = c.hoverBg; e.currentTarget.style.color = c.textSecondary; }
                }}
                onMouseLeave={(e) => {
                  if (!active) { e.currentTarget.style.background = "transparent"; e.currentTarget.style.color = c.textMuted; }
                }}
              >
                <svg className="w-4 h-4 shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
                  <path strokeLinecap="round" strokeLinejoin="round" d={sectionIcons[section]} />
                </svg>
                {section}
              </button>
            );
          })}
        </nav>

        <div className="flex-1 overflow-y-auto p-6">
          {activeSection === "general" && (
            <GeneralSection settings={settings} onChange={setSettings} themeTokens={c} />
          )}
          {activeSection === "projects" && (
            <ProjectsSection settings={settings} onChange={setSettings} themeTokens={c} />
          )}
          {activeSection === "github" && (
            <GitHubSection settings={settings} onChange={setSettings} themeTokens={c} />
          )}
          {activeSection === "notifications" && (
            <NotificationsSection settings={settings} onChange={setSettings} themeTokens={c} />
          )}
        </div>
      </div>
    </div>
  );
}

function GeneralSection({
  settings,
  onChange,
  themeTokens: c,
}: {
  settings: Settings;
  onChange: (s: Settings) => void;
  themeTokens: ThemeTokens;
}) {
  return (
    <div className="flex flex-col gap-5 max-w-lg">
      <FieldGroup label="Editor command" themeTokens={c}>
        <input
          type="text"
          value={settings.editor}
          onChange={(e) => onChange({ ...settings, editor: e.target.value })}
          placeholder="code"
          className="w-full rounded-xl px-3 py-2.5 text-sm outline-none transition-colors"
          style={inputStyle(c)}
        />
        <p className="text-[11px] mt-1" style={{ color: c.textMuted }}>
          e.g. <Code c={c}>code</Code>, <Code c={c}>cursor</Code>, <Code c={c}>nvim</Code>
        </p>
      </FieldGroup>

      <FieldGroup label="Session timeout (minutes)" themeTokens={c}>
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
          className="w-32 rounded-xl px-3 py-2.5 text-sm outline-none transition-colors"
          style={inputStyle(c)}
        />
      </FieldGroup>

      <FieldGroup label="Terminal font size" themeTokens={c}>
        <div className="flex items-center gap-3">
          <input
            type="range"
            min={8}
            max={24}
            step={1}
            value={settings.terminalFontSize || 15}
            onChange={(e) =>
              onChange({ ...settings, terminalFontSize: parseInt(e.target.value) })
            }
            className="flex-1 accent-[#4f8ef7] h-1.5 rounded-full cursor-pointer"
          />
          <span className="text-sm font-mono w-8 text-right" style={{ color: c.textSecondary }}>
            {settings.terminalFontSize || 15}
          </span>
        </div>
        <p className="text-[11px] mt-1" style={{ color: c.textMuted }}>
          Adjust the font size in embedded terminals (8–24pt). Takes effect on next terminal launch.
        </p>
      </FieldGroup>

      <FieldGroup label="Terminal shell" themeTokens={c}>
        <input
          type="text"
          value={settings.terminalShell || "cmd.exe"}
          onChange={(e) => onChange({ ...settings, terminalShell: e.target.value })}
          placeholder="cmd.exe"
          spellCheck={false}
          className="w-full rounded-xl px-3 py-2.5 text-sm font-mono outline-none transition-colors"
          style={inputStyle(c)}
        />
        <p className="text-[11px] mt-1" style={{ color: c.textMuted }}>
          Command used by the embedded terminal. Default <Code c={c}>cmd.exe</Code> for native Windows. Set to <Code c={c}>wsl.exe</Code> to run Claude inside WSL, or e.g. <Code c={c}>pwsh.exe -NoLogo</Code>. Takes effect on the next terminal launch.
        </p>
      </FieldGroup>

      <FieldGroup label="Prompt template" themeTokens={c}>
        <textarea
          rows={3}
          value={settings.promptTemplate}
          onChange={(e) =>
            onChange({ ...settings, promptTemplate: e.target.value })
          }
          placeholder="Optional default prompt prefix..."
          className="w-full rounded-xl px-3 py-2.5 text-sm outline-none resize-none transition-colors"
          style={inputStyle(c)}
        />
      </FieldGroup>
    </div>
  );
}

function ProjectsSection({
  settings,
  onChange,
  themeTokens: c,
}: {
  settings: Settings;
  onChange: (s: Settings) => void;
  themeTokens: ThemeTokens;
}) {
  const addProjectViaDialog = async () => {
    const selected = await open({ directory: true, multiple: false, title: "Select project folder" });
    if (!selected || typeof selected !== "string") return;
    if (settings.projects.find((p) => p.path === selected)) return;
    onChange({
      ...settings,
      projects: [...settings.projects, { path: selected }],
    });
  };

  const removeProject = (path: string) => {
    onChange({
      ...settings,
      projects: settings.projects.filter((p) => p.path !== path),
    });
  };

  return (
    <div className="flex flex-col gap-4 max-w-lg">
      <button
        onClick={addProjectViaDialog}
        className="flex items-center justify-center gap-2 px-4 py-2.5 rounded-xl bg-[#4f8ef7]/90 hover:bg-[#4f8ef7] text-white text-xs font-medium transition-all shadow-lg shadow-[#4f8ef7]/15"
      >
        <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
          <path strokeLinecap="round" strokeLinejoin="round" d="M12 4.5v15m7.5-7.5h-15" />
        </svg>
        Add Project Folder
      </button>

      {settings.projects.length === 0 && (
        <div className="text-center py-8">
          <svg className="w-8 h-8 mx-auto mb-2" style={{ color: c.textDim }} fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1}>
            <path strokeLinecap="round" strokeLinejoin="round" d="M2.25 12.75V12A2.25 2.25 0 0 1 4.5 9.75h15A2.25 2.25 0 0 1 21.75 12v.75m-8.69-6.44-2.12-2.12a1.5 1.5 0 0 0-1.061-.44H4.5A2.25 2.25 0 0 0 2.25 6v12a2.25 2.25 0 0 0 2.25 2.25h15A2.25 2.25 0 0 0 21.75 18V9a2.25 2.25 0 0 0-2.25-2.25h-5.379a1.5 1.5 0 0 1-1.06-.44Z" />
          </svg>
          <p className="text-sm" style={{ color: c.textMuted }}>No projects configured yet.</p>
        </div>
      )}

      <div className="flex flex-col gap-1.5">
        {settings.projects.map((p) => (
          <div
            key={p.path}
            className="flex items-center justify-between px-3 py-3 rounded-xl"
            style={{ background: c.bgCard, border: `1px solid ${c.borderCard}` }}
          >
            <div>
              <p className="text-sm" style={{ color: c.textSecondary }}>
                {p.name ?? p.path.split(/[/\\]/).pop() ?? p.path}
              </p>
              <p className="text-[11px] font-mono" style={{ color: c.textMuted }}>{p.path}</p>
            </div>
            <button
              onClick={() => removeProject(p.path)}
              className="ml-3 transition-colors"
              style={{ color: c.textDim }}
              onMouseEnter={(e) => { e.currentTarget.style.color = "#f85149"; }}
              onMouseLeave={(e) => { e.currentTarget.style.color = c.textDim; }}
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
  themeTokens: c,
}: {
  settings: Settings;
  onChange: (s: Settings) => void;
  themeTokens: ThemeTokens;
}) {
  return (
    <div className="flex flex-col gap-5 max-w-lg">
      <FieldGroup label="Default issue filter" themeTokens={c}>
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
          className="w-full rounded-xl px-3 py-2.5 text-sm outline-none transition-colors"
          style={inputStyle(c)}
        />
      </FieldGroup>
      <FieldGroup label="Poll interval (seconds)" themeTokens={c}>
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
          className="w-32 rounded-xl px-3 py-2.5 text-sm outline-none transition-colors"
          style={inputStyle(c)}
        />
      </FieldGroup>
      <FieldGroup label="Merge command" themeTokens={c}>
        <input
          type="text"
          value={settings.github.mergeCommand}
          onChange={(e) =>
            onChange({
              ...settings,
              github: { ...settings.github, mergeCommand: e.target.value },
            })
          }
          className="w-full rounded-xl px-3 py-2.5 text-sm font-mono outline-none transition-colors"
          style={inputStyle(c)}
        />
      </FieldGroup>
    </div>
  );
}

function NotificationsSection({
  settings,
  onChange,
  themeTokens: c,
}: {
  settings: Settings;
  onChange: (s: Settings) => void;
  themeTokens: ThemeTokens;
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
        themeTokens={c}
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
        themeTokens={c}
      />

      {settings.notifications.pushoverEnabled && (
        <>
          <FieldGroup label="Pushover token (optional)" themeTokens={c}>
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
              className="w-full rounded-xl px-3 py-2.5 text-sm font-mono outline-none transition-colors"
              style={inputStyle(c)}
            />
          </FieldGroup>
          <FieldGroup label="Pushover user key" themeTokens={c}>
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
              className="w-full rounded-xl px-3 py-2.5 text-sm font-mono outline-none transition-colors"
              style={inputStyle(c)}
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
  themeTokens: c,
}: {
  checked: boolean;
  onChange: (v: boolean) => void;
  label: string;
  description?: string;
  themeTokens: ThemeTokens;
}) {
  return (
    <div className="flex items-start gap-3 group">
      <label className="relative inline-flex cursor-pointer mt-0.5 shrink-0">
        <input
          type="checkbox"
          checked={checked}
          onChange={(e) => onChange(e.target.checked)}
          className="sr-only"
        />
        <div
          className="w-9 h-5 rounded-full transition-colors"
          style={{ background: checked ? "#4f8ef7" : c.bgAccent("0.10") }}
        >
          <div
            className={`w-4 h-4 bg-white rounded-full shadow mt-0.5 transition-transform ${
              checked ? "translate-x-4" : "translate-x-0.5"
            }`}
          />
        </div>
      </label>
      <div>
        <span className="text-sm transition-colors" style={{ color: c.textSecondary }}>{label}</span>
        {description && (
          <p className="text-[11px] mt-0.5" style={{ color: c.textMuted }}>{description}</p>
        )}
      </div>
    </div>
  );
}

function FieldGroup({
  label,
  children,
  themeTokens: c,
}: {
  label: string;
  children: ReactNode;
  themeTokens: ThemeTokens;
}) {
  return (
    <div>
      <label
        className="block text-[11px] font-medium mb-1.5 uppercase tracking-wider"
        style={{ color: c.textSecondary }}
      >
        {label}
      </label>
      {children}
    </div>
  );
}

function Code({ children, c }: { children: ReactNode; c: ThemeTokens }) {
  return (
    <code className="font-mono" style={{ color: c.textSecondary }}>
      {children}
    </code>
  );
}
