import { useEffect, useState } from "react";
import { open } from "@tauri-apps/plugin-dialog";
import {
  checkDependencies,
  getSettings,
  saveSettings,
} from "../store/boardStore";
import { useTheme, t } from "../theme";
import type { DependencyStatus, Settings } from "../types";

const TOTAL_STEPS = 5;

type ThemeTokens = ReturnType<typeof t>;

export default function OnboardingWizard({
  onComplete,
}: {
  onComplete: () => void;
}) {
  const { theme } = useTheme();
  const c = t(theme);
  const [step, setStep] = useState(0);
  const [deps, setDeps] = useState<DependencyStatus | null>(null);
  const [checking, setChecking] = useState(false);
  const [settings, setSettings] = useState<Settings | null>(null);

  useEffect(() => {
    refreshDeps();
    getSettings().then(setSettings).catch(console.error);
  }, []);

  const refreshDeps = async () => {
    setChecking(true);
    try {
      const d = await checkDependencies();
      setDeps(d);
    } catch (e) {
      console.error(e);
    } finally {
      setChecking(false);
    }
  };

  const next = () => setStep((s) => Math.min(s + 1, TOTAL_STEPS - 1));
  const back = () => setStep((s) => Math.max(s - 1, 0));

  const finish = async () => {
    if (settings) {
      await saveSettings({ ...settings, hasCompletedOnboarding: true });
    }
    onComplete();
  };

  const addProject = async () => {
    const selected = await open({
      directory: true,
      multiple: false,
      title: "Select project folder",
    });
    if (!selected || typeof selected !== "string" || !settings) return;
    if (settings.projects.find((p) => p.path === selected)) return;
    const updated = {
      ...settings,
      projects: [...settings.projects, { path: selected }],
    };
    setSettings(updated);
    await saveSettings(updated);
  };

  const removeProject = async (path: string) => {
    if (!settings) return;
    const updated = {
      ...settings,
      projects: settings.projects.filter((p) => p.path !== path),
    };
    setSettings(updated);
    await saveSettings(updated);
  };

  return (
    <div
      className="fixed inset-0 z-[100] flex items-center justify-center"
      style={{ background: c.bg }}
    >
      <div
        className="w-[560px] rounded-2xl shadow-2xl flex flex-col overflow-hidden"
        style={{
          background: c.bgDialog,
          border: `1px solid ${c.borderBright}`,
        }}
      >
        <div className="flex items-center justify-center gap-2 pt-6 pb-3">
          {Array.from({ length: TOTAL_STEPS }).map((_, i) => (
            <div
              key={i}
              className="w-2 h-2 rounded-full transition-colors"
              style={{
                background:
                  i === step ? "#4f8ef7" : i < step ? "#3fb950" : c.bgAccent("0.10"),
              }}
            />
          ))}
        </div>

        <div style={{ borderTop: `1px solid ${c.border}` }} />

        <div className="flex-1 min-h-[320px] p-8">
          {step === 0 && <WelcomeStep themeTokens={c} />}
          {step === 1 && (
            <ClaudeCodeStep
              deps={deps}
              checking={checking}
              onRecheck={refreshDeps}
              themeTokens={c}
            />
          )}
          {step === 2 && (
            <DependenciesStep
              deps={deps}
              checking={checking}
              onRecheck={refreshDeps}
              themeTokens={c}
            />
          )}
          {step === 3 && (
            <ProjectStep
              settings={settings}
              onAdd={addProject}
              onRemove={removeProject}
              themeTokens={c}
            />
          )}
          {step === 4 && <CompleteStep deps={deps} settings={settings} themeTokens={c} />}
        </div>

        <div style={{ borderTop: `1px solid ${c.border}` }} />

        <div className="flex items-center justify-between px-6 py-4">
          <div>
            {step > 0 && step < TOTAL_STEPS - 1 && (
              <button
                onClick={back}
                className="px-4 py-2 rounded-lg text-[13px] transition-colors"
                style={{ color: c.textMuted }}
                onMouseEnter={(e) => {
                  e.currentTarget.style.background = c.hoverBg;
                  e.currentTarget.style.color = c.textPrimary;
                }}
                onMouseLeave={(e) => {
                  e.currentTarget.style.background = "";
                  e.currentTarget.style.color = c.textMuted;
                }}
              >
                Back
              </button>
            )}
          </div>
          <div className="flex items-center gap-2">
            {step > 0 && step < TOTAL_STEPS - 1 && (
              <button
                onClick={next}
                className="px-4 py-2 rounded-lg text-[13px] transition-colors"
                style={{ color: c.textMuted }}
                onMouseEnter={(e) => { e.currentTarget.style.color = c.textSecondary; }}
                onMouseLeave={(e) => { e.currentTarget.style.color = c.textMuted; }}
              >
                Skip
              </button>
            )}
            {step < TOTAL_STEPS - 1 ? (
              <button
                onClick={next}
                className="px-5 py-2 rounded-lg bg-[#4f8ef7] hover:bg-[#5b97fa] text-white text-[13px] font-semibold transition-colors"
              >
                {step === 0 ? "Get Started" : "Continue"}
              </button>
            ) : (
              <button
                onClick={finish}
                className="px-5 py-2 rounded-lg bg-[#4f8ef7] hover:bg-[#5b97fa] text-white text-[13px] font-semibold transition-colors"
              >
                Done
              </button>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}

// ── Step 0: Welcome ─────────────────────────────────────────────────────────

function WelcomeStep({ themeTokens: c }: { themeTokens: ThemeTokens }) {
  return (
    <div className="flex flex-col items-center justify-center h-full text-center gap-5">
      <div className="w-16 h-16 rounded-2xl bg-gradient-to-br from-[#4f8ef7] to-[#a371f7] flex items-center justify-center shadow-lg shadow-[#4f8ef7]/20">
        <svg
          className="w-8 h-8 text-white"
          fill="none"
          viewBox="0 0 24 24"
          stroke="currentColor"
          strokeWidth={1.5}
        >
          <path
            strokeLinecap="round"
            strokeLinejoin="round"
            d="M3.75 6A2.25 2.25 0 0 1 6 3.75h2.25A2.25 2.25 0 0 1 10.5 6v2.25a2.25 2.25 0 0 1-2.25 2.25H6a2.25 2.25 0 0 1-2.25-2.25V6ZM3.75 15.75A2.25 2.25 0 0 1 6 13.5h2.25a2.25 2.25 0 0 1 2.25 2.25V18a2.25 2.25 0 0 1-2.25 2.25H6A2.25 2.25 0 0 1 3.75 18v-2.25ZM13.5 6a2.25 2.25 0 0 1 2.25-2.25H18A2.25 2.25 0 0 1 20.25 6v2.25A2.25 2.25 0 0 1 18 10.5h-2.25a2.25 2.25 0 0 1-2.25-2.25V6ZM13.5 15.75a2.25 2.25 0 0 1 2.25-2.25H18a2.25 2.25 0 0 1 2.25 2.25V18A2.25 2.25 0 0 1 18 20.25h-2.25a2.25 2.25 0 0 1-2.25-2.25v-2.25Z"
          />
        </svg>
      </div>
      <div>
        <h2 className="text-xl font-semibold mb-2" style={{ color: c.textPrimary }}>
          Welcome to Kanban Code
        </h2>
        <p className="text-[14px] max-w-[360px] leading-relaxed" style={{ color: c.textMuted }}>
          Let's set up everything you need to manage your Claude Code sessions
          on a visual kanban board.
        </p>
      </div>
    </div>
  );
}

// ── Step 1: Claude Code ─────────────────────────────────────────────────────

function ClaudeCodeStep({
  deps,
  checking,
  onRecheck,
  themeTokens: c,
}: {
  deps: DependencyStatus | null;
  checking: boolean;
  onRecheck: () => void;
  themeTokens: ThemeTokens;
}) {
  const installCmd = "npm install -g @anthropic-ai/claude-code";

  return (
    <div className="flex flex-col gap-5">
      <StepHeader
        themeTokens={c}
        icon={
          <svg className="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
            <path strokeLinecap="round" strokeLinejoin="round" d="m6.75 7.5 3 2.25-3 2.25m4.5 0h3m-9 8.25h13.5A2.25 2.25 0 0 0 21 18V6a2.25 2.25 0 0 0-2.25-2.25H5.25A2.25 2.25 0 0 0 3 6v12a2.25 2.25 0 0 0 2.25 2.25Z" />
          </svg>
        }
        title="Claude Code CLI"
        description="Kanban Code manages sessions from Claude Code. Make sure it's installed globally."
      />

      <StatusRow label="Claude Code" ok={deps?.claudeAvailable ?? false} themeTokens={c} />

      {deps?.claudeAvailable ? (
        <div className="flex items-center gap-2 text-[#3fb950] text-[13px]">
          <CheckIcon />
          Claude Code is installed and ready
        </div>
      ) : (
        <div className="flex flex-col gap-3">
          <p className="text-[12px]" style={{ color: c.textMuted }}>Install Claude Code:</p>
          <CopyableCommand command={installCmd} themeTokens={c} />
          <p className="text-[11px]" style={{ color: c.textDim }}>
            Kanban Code works without it — columns will just be empty until
            sessions are created.
          </p>
          <RecheckButton checking={checking} onRecheck={onRecheck} themeTokens={c} />
        </div>
      )}

      <p className="text-[11px] leading-relaxed" style={{ color: c.textDim }}>
        Using WSL? The embedded terminal defaults to{" "}
        <code className="font-mono" style={{ color: c.textMuted }}>cmd.exe</code>.
        If you installed Claude inside WSL, switch it to{" "}
        <code className="font-mono" style={{ color: c.textMuted }}>wsl.exe</code>
        {" "}in <span style={{ color: c.textSecondary }}>Settings → Terminal shell</span>
        {" "}after onboarding.
      </p>
    </div>
  );
}

// ── Step 2: Dependencies ────────────────────────────────────────────────────

function DependenciesStep({
  deps,
  checking,
  onRecheck,
  themeTokens: c,
}: {
  deps: DependencyStatus | null;
  checking: boolean;
  onRecheck: () => void;
  themeTokens: ThemeTokens;
}) {
  return (
    <div className="flex flex-col gap-5">
      <StepHeader
        themeTokens={c}
        icon={
          <svg className="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
            <path strokeLinecap="round" strokeLinejoin="round" d="m21 7.5-9-5.25L3 7.5m18 0-9 5.25m9-5.25v9l-9 5.25M3 7.5l9 5.25M3 7.5v9l9 5.25m0-9v9" />
          </svg>
        }
        title="Dependencies"
        description="Tools that Kanban Code uses for session management and GitHub integration."
      />

      <div className="flex flex-col gap-2">
        <StatusRow label="Git" ok={deps?.gitAvailable ?? false} themeTokens={c} />
        <StatusRow label="GitHub CLI (gh)" ok={deps?.ghAvailable ?? false} themeTokens={c} />
        {deps?.ghAvailable && !deps?.ghAuthenticated && (
          <div className="ml-6 flex items-center gap-1.5 text-[12px] text-amber-500">
            <svg className="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M12 9v3.75m-9.303 3.376c-.866 1.5.217 3.374 1.948 3.374h14.71c1.73 0 2.813-1.874 1.948-3.374L13.949 3.378c-.866-1.5-3.032-1.5-3.898 0L2.697 16.126ZM12 15.75h.007v.008H12v-.008Z" />
            </svg>
            <span>
              gh is installed but not logged in. Run{" "}
              <code className="font-mono" style={{ color: c.textSecondary }}>gh auth login</code> in
              a terminal.
            </span>
          </div>
        )}
      </div>

      {(!deps?.gitAvailable || !deps?.ghAvailable) && (
        <div className="flex flex-col gap-2">
          <p className="text-[12px]" style={{ color: c.textMuted }}>Install missing tools:</p>
          {!deps?.gitAvailable && (
            <CopyableCommand command="winget install Git.Git" themeTokens={c} />
          )}
          {!deps?.ghAvailable && (
            <CopyableCommand command="winget install GitHub.cli" themeTokens={c} />
          )}
        </div>
      )}

      <RecheckButton checking={checking} onRecheck={onRecheck} themeTokens={c} />
    </div>
  );
}

// ── Step 3: Add Project ─────────────────────────────────────────────────────

function ProjectStep({
  settings,
  onAdd,
  onRemove,
  themeTokens: c,
}: {
  settings: Settings | null;
  onAdd: () => void;
  onRemove: (path: string) => void;
  themeTokens: ThemeTokens;
}) {
  return (
    <div className="flex flex-col gap-5">
      <StepHeader
        themeTokens={c}
        icon={
          <svg className="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
            <path strokeLinecap="round" strokeLinejoin="round" d="M2.25 12.75V12A2.25 2.25 0 0 1 4.5 9.75h15A2.25 2.25 0 0 1 21.75 12v.75m-8.69-6.44-2.12-2.12a1.5 1.5 0 0 0-1.061-.44H4.5A2.25 2.25 0 0 0 2.25 6v12a2.25 2.25 0 0 0 2.25 2.25h15A2.25 2.25 0 0 0 21.75 18V9a2.25 2.25 0 0 0-2.25-2.25h-5.379a1.5 1.5 0 0 1-1.06-.44Z" />
          </svg>
        }
        title="Add a Project"
        description="Select the folder(s) where you use Claude Code. Sessions and git worktrees in these folders will appear on the board."
      />

      <button
        onClick={onAdd}
        className="flex items-center justify-center gap-2 px-4 py-2.5 rounded-xl bg-[#4f8ef7]/90 hover:bg-[#4f8ef7] text-white text-[13px] font-medium transition-all w-fit"
      >
        <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
          <path strokeLinecap="round" strokeLinejoin="round" d="M12 4.5v15m7.5-7.5h-15" />
        </svg>
        Add Project Folder
      </button>

      {settings && settings.projects.length > 0 && (
        <div className="flex flex-col gap-1.5 max-h-[160px] overflow-y-auto">
          {settings.projects.map((p) => (
            <div
              key={p.path}
              className="flex items-center justify-between px-3 py-2.5 rounded-xl"
              style={{ background: c.bgCard, border: `1px solid ${c.borderCard}` }}
            >
              <div className="min-w-0">
                <p className="text-[13px] truncate" style={{ color: c.textSecondary }}>
                  {p.name ?? p.path.split(/[/\\]/).pop() ?? p.path}
                </p>
                <p className="text-[11px] font-mono truncate" style={{ color: c.textMuted }}>
                  {p.path}
                </p>
              </div>
              <button
                onClick={() => onRemove(p.path)}
                className="ml-2 shrink-0 transition-colors"
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
      )}

      {(!settings || settings.projects.length === 0) && (
        <p className="text-[12px]" style={{ color: c.textDim }}>
          No projects added yet. You can always add more later in Settings.
        </p>
      )}
    </div>
  );
}

// ── Step 4: Complete ────────────────────────────────────────────────────────

function CompleteStep({
  deps,
  settings,
  themeTokens: c,
}: {
  deps: DependencyStatus | null;
  settings: Settings | null;
  themeTokens: ThemeTokens;
}) {
  return (
    <div className="flex flex-col gap-5">
      <StepHeader
        themeTokens={c}
        icon={
          <svg className="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
            <path strokeLinecap="round" strokeLinejoin="round" d="M9 12.75 11.25 15 15 9.75M21 12c0 1.268-.63 2.39-1.593 3.068a3.745 3.745 0 0 1-1.043 3.296 3.745 3.745 0 0 1-3.296 1.043A3.745 3.745 0 0 1 12 21c-1.268 0-2.39-.63-3.068-1.593a3.746 3.746 0 0 1-3.296-1.043 3.746 3.746 0 0 1-1.043-3.296A3.745 3.745 0 0 1 3 12c0-1.268.63-2.39 1.593-3.068a3.746 3.746 0 0 1 1.043-3.296 3.746 3.746 0 0 1 3.296-1.043A3.746 3.746 0 0 1 12 3c1.268 0 2.39.63 3.068 1.593a3.746 3.746 0 0 1 3.296 1.043 3.746 3.746 0 0 1 1.043 3.296A3.745 3.745 0 0 1 21 12Z" />
          </svg>
        }
        title="Setup Complete"
        description="Here's a summary of your configuration."
      />

      <div className="flex flex-col gap-2">
        <SummaryRow label="Claude Code" ok={deps?.claudeAvailable ?? false} themeTokens={c} />
        <SummaryRow label="Git" ok={deps?.gitAvailable ?? false} themeTokens={c} />
        <SummaryRow label="GitHub CLI" ok={deps?.ghAuthenticated ?? false} themeTokens={c} />
        <SummaryRow label="Projects" ok={(settings?.projects.length ?? 0) > 0} themeTokens={c} />
      </div>

      <p className="text-[11px] mt-1" style={{ color: c.textDim }}>
        You can always reopen this wizard or change settings later from the
        Settings page.
      </p>
    </div>
  );
}

// ── Shared helpers ──────────────────────────────────────────────────────────

function StepHeader({
  icon,
  title,
  description,
  themeTokens: c,
}: {
  icon: React.ReactNode;
  title: string;
  description: string;
  themeTokens: ThemeTokens;
}) {
  return (
    <div className="flex flex-col gap-2">
      <div className="flex items-center gap-2.5">
        <span className="text-[#4f8ef7]">{icon}</span>
        <h3 className="text-[16px] font-semibold" style={{ color: c.textPrimary }}>{title}</h3>
      </div>
      <p className="text-[13px] leading-relaxed" style={{ color: c.textMuted }}>
        {description}
      </p>
    </div>
  );
}

function StatusRow({ label, ok, themeTokens: c }: { label: string; ok: boolean; themeTokens: ThemeTokens }) {
  return (
    <div className="flex items-center gap-2.5">
      {ok ? (
        <svg className="w-4 h-4 text-[#3fb950]" fill="currentColor" viewBox="0 0 24 24">
          <path fillRule="evenodd" d="M2.25 12c0-5.385 4.365-9.75 9.75-9.75s9.75 4.365 9.75 9.75-4.365 9.75-9.75 9.75S2.25 17.385 2.25 12Zm13.36-1.814a.75.75 0 1 0-1.22-.872l-3.236 4.53L9.53 12.22a.75.75 0 0 0-1.06 1.06l2.25 2.25a.75.75 0 0 0 1.14-.094l3.75-5.25Z" clipRule="evenodd" />
        </svg>
      ) : (
        <div
          className="w-4 h-4 rounded-full"
          style={{ border: `1.5px solid ${c.textDim}` }}
        />
      )}
      <span className="text-[13px]" style={{ color: c.textSecondary }}>{label}</span>
      <span
        className="ml-auto text-[11px]"
        style={{ color: ok ? "#3fb950" : "#d29922" }}
      >
        {ok ? "Ready" : "Not found"}
      </span>
    </div>
  );
}

function SummaryRow({ label, ok, themeTokens: c }: { label: string; ok: boolean; themeTokens: ThemeTokens }) {
  return (
    <div className="flex items-center gap-2.5">
      {ok ? (
        <svg className="w-4 h-4 text-[#3fb950]" fill="currentColor" viewBox="0 0 24 24">
          <path fillRule="evenodd" d="M2.25 12c0-5.385 4.365-9.75 9.75-9.75s9.75 4.365 9.75 9.75-4.365 9.75-9.75 9.75S2.25 17.385 2.25 12Zm13.36-1.814a.75.75 0 1 0-1.22-.872l-3.236 4.53L9.53 12.22a.75.75 0 0 0-1.06 1.06l2.25 2.25a.75.75 0 0 0 1.14-.094l3.75-5.25Z" clipRule="evenodd" />
        </svg>
      ) : (
        <svg className="w-4 h-4 text-amber-500" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
          <path strokeLinecap="round" strokeLinejoin="round" d="M12 9v3.75m9-.75a9 9 0 1 1-18 0 9 9 0 0 1 18 0Zm-9 3.75h.008v.008H12v-.008Z" />
        </svg>
      )}
      <span className="text-[13px]" style={{ color: c.textSecondary }}>{label}</span>
    </div>
  );
}

function CheckIcon() {
  return (
    <svg className="w-4 h-4" fill="currentColor" viewBox="0 0 24 24">
      <path fillRule="evenodd" d="M2.25 12c0-5.385 4.365-9.75 9.75-9.75s9.75 4.365 9.75 9.75-4.365 9.75-9.75 9.75S2.25 17.385 2.25 12Zm13.36-1.814a.75.75 0 1 0-1.22-.872l-3.236 4.53L9.53 12.22a.75.75 0 0 0-1.06 1.06l2.25 2.25a.75.75 0 0 0 1.14-.094l3.75-5.25Z" clipRule="evenodd" />
    </svg>
  );
}

function CopyableCommand({ command, themeTokens: c }: { command: string; themeTokens: ThemeTokens }) {
  const [copied, setCopied] = useState(false);

  const copy = () => {
    navigator.clipboard.writeText(command);
    setCopied(true);
    setTimeout(() => setCopied(false), 1500);
  };

  return (
    <div className="flex items-center gap-2">
      <code
        className="flex-1 rounded-lg px-3 py-2 text-[12px] font-mono select-all"
        style={{
          background: c.bgAccent("0.03"),
          border: `1px solid ${c.border}`,
          color: c.textSecondary,
        }}
      >
        {command}
      </code>
      <button
        onClick={copy}
        className="transition-colors shrink-0"
        style={{ color: c.textMuted }}
        onMouseEnter={(e) => { e.currentTarget.style.color = c.textPrimary; }}
        onMouseLeave={(e) => { e.currentTarget.style.color = c.textMuted; }}
        title="Copy to clipboard"
      >
        {copied ? (
          <svg className="w-4 h-4 text-[#3fb950]" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
            <path strokeLinecap="round" strokeLinejoin="round" d="m4.5 12.75 6 6 9-13.5" />
          </svg>
        ) : (
          <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
            <path strokeLinecap="round" strokeLinejoin="round" d="M15.75 17.25v3.375c0 .621-.504 1.125-1.125 1.125h-9.75a1.125 1.125 0 0 1-1.125-1.125V7.875c0-.621.504-1.125 1.125-1.125H6.75a9.06 9.06 0 0 1 1.5.124m7.5 10.376h3.375c.621 0 1.125-.504 1.125-1.125V11.25c0-4.46-3.243-8.161-7.5-8.876a9.06 9.06 0 0 0-1.5-.124H9.375c-.621 0-1.125.504-1.125 1.125v3.5m7.5 10.375H9.375a1.125 1.125 0 0 1-1.125-1.125v-9.25m12 6.625v-1.875a3.375 3.375 0 0 0-3.375-3.375h-1.5a1.125 1.125 0 0 1-1.125-1.125v-1.5a3.375 3.375 0 0 0-3.375-3.375H9.75" />
          </svg>
        )}
      </button>
    </div>
  );
}

function RecheckButton({
  checking,
  onRecheck,
  themeTokens: c,
}: {
  checking: boolean;
  onRecheck: () => void;
  themeTokens: ThemeTokens;
}) {
  return (
    <button
      onClick={onRecheck}
      disabled={checking}
      className="flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-[12px] transition-colors disabled:opacity-50 w-fit"
      style={{
        background: c.bgAccent("0.04"),
        color: c.textMuted,
      }}
      onMouseEnter={(e) => {
        if (!checking) {
          e.currentTarget.style.background = c.bgAccent("0.08");
          e.currentTarget.style.color = c.textPrimary;
        }
      }}
      onMouseLeave={(e) => {
        if (!checking) {
          e.currentTarget.style.background = c.bgAccent("0.04");
          e.currentTarget.style.color = c.textMuted;
        }
      }}
    >
      {checking && (
        <div
          className="w-3 h-3 border-[1.5px] border-t-transparent rounded-full animate-spin"
          style={{ borderColor: c.textMuted, borderTopColor: "transparent" }}
        />
      )}
      Re-check
    </button>
  );
}
