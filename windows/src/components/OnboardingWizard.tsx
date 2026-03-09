import { useEffect, useState } from "react";
import { open } from "@tauri-apps/plugin-dialog";
import {
  checkDependencies,
  getSettings,
  saveSettings,
} from "../store/boardStore";
import type { DependencyStatus, Settings } from "../types";

const TOTAL_STEPS = 5;

export default function OnboardingWizard({
  onComplete,
}: {
  onComplete: () => void;
}) {
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
    <div className="fixed inset-0 z-[100] flex items-center justify-center bg-[#0a0a0c]">
      <div className="w-[560px] bg-[#141417] border border-white/10 rounded-2xl shadow-2xl flex flex-col overflow-hidden">
        {/* Step dots */}
        <div className="flex items-center justify-center gap-2 pt-6 pb-3">
          {Array.from({ length: TOTAL_STEPS }).map((_, i) => (
            <div
              key={i}
              className={`w-2 h-2 rounded-full transition-colors ${
                i === step
                  ? "bg-[#4f8ef7]"
                  : i < step
                  ? "bg-[#3fb950]"
                  : "bg-white/10"
              }`}
            />
          ))}
        </div>

        <div className="border-t border-white/[0.06]" />

        {/* Step content */}
        <div className="flex-1 min-h-[320px] p-8">
          {step === 0 && <WelcomeStep />}
          {step === 1 && (
            <ClaudeCodeStep
              deps={deps}
              checking={checking}
              onRecheck={refreshDeps}
            />
          )}
          {step === 2 && (
            <DependenciesStep
              deps={deps}
              checking={checking}
              onRecheck={refreshDeps}
            />
          )}
          {step === 3 && (
            <ProjectStep
              settings={settings}
              onAdd={addProject}
              onRemove={removeProject}
            />
          )}
          {step === 4 && <CompleteStep deps={deps} settings={settings} />}
        </div>

        <div className="border-t border-white/[0.06]" />

        {/* Navigation */}
        <div className="flex items-center justify-between px-6 py-4">
          <div>
            {step > 0 && step < TOTAL_STEPS - 1 && (
              <button
                onClick={back}
                className="px-4 py-2 rounded-lg text-[13px] text-zinc-400 hover:text-zinc-200 hover:bg-white/5 transition-colors"
              >
                Back
              </button>
            )}
          </div>
          <div className="flex items-center gap-2">
            {step > 0 && step < TOTAL_STEPS - 1 && (
              <button
                onClick={next}
                className="px-4 py-2 rounded-lg text-[13px] text-zinc-500 hover:text-zinc-300 transition-colors"
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

function WelcomeStep() {
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
        <h2 className="text-xl font-semibold text-zinc-100 mb-2">
          Welcome to Kanban Code
        </h2>
        <p className="text-[14px] text-zinc-400 max-w-[360px] leading-relaxed">
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
}: {
  deps: DependencyStatus | null;
  checking: boolean;
  onRecheck: () => void;
}) {
  const installCmd = "npm install -g @anthropic-ai/claude-code";

  return (
    <div className="flex flex-col gap-5">
      <StepHeader
        icon={
          <svg
            className="w-5 h-5"
            fill="none"
            viewBox="0 0 24 24"
            stroke="currentColor"
            strokeWidth={1.5}
          >
            <path
              strokeLinecap="round"
              strokeLinejoin="round"
              d="m6.75 7.5 3 2.25-3 2.25m4.5 0h3m-9 8.25h13.5A2.25 2.25 0 0 0 21 18V6a2.25 2.25 0 0 0-2.25-2.25H5.25A2.25 2.25 0 0 0 3 6v12a2.25 2.25 0 0 0 2.25 2.25Z"
            />
          </svg>
        }
        title="Claude Code CLI"
        description="Kanban Code manages sessions from Claude Code. Make sure it's installed globally."
      />

      <StatusRow
        label="Claude Code"
        ok={deps?.claudeAvailable ?? false}
      />

      {deps?.claudeAvailable ? (
        <div className="flex items-center gap-2 text-[#3fb950] text-[13px]">
          <CheckIcon />
          Claude Code is installed and ready
        </div>
      ) : (
        <div className="flex flex-col gap-3">
          <p className="text-[12px] text-zinc-500">Install Claude Code:</p>
          <CopyableCommand command={installCmd} />
          <p className="text-[11px] text-zinc-600">
            Kanban Code works without it — columns will just be empty until
            sessions are created.
          </p>
          <RecheckButton checking={checking} onRecheck={onRecheck} />
        </div>
      )}
    </div>
  );
}

// ── Step 2: Dependencies ────────────────────────────────────────────────────

function DependenciesStep({
  deps,
  checking,
  onRecheck,
}: {
  deps: DependencyStatus | null;
  checking: boolean;
  onRecheck: () => void;
}) {
  return (
    <div className="flex flex-col gap-5">
      <StepHeader
        icon={
          <svg
            className="w-5 h-5"
            fill="none"
            viewBox="0 0 24 24"
            stroke="currentColor"
            strokeWidth={1.5}
          >
            <path
              strokeLinecap="round"
              strokeLinejoin="round"
              d="m21 7.5-9-5.25L3 7.5m18 0-9 5.25m9-5.25v9l-9 5.25M3 7.5l9 5.25M3 7.5v9l9 5.25m0-9v9"
            />
          </svg>
        }
        title="Dependencies"
        description="Tools that Kanban Code uses for session management and GitHub integration."
      />

      <div className="flex flex-col gap-2">
        <StatusRow label="Git" ok={deps?.gitAvailable ?? false} />
        <StatusRow label="GitHub CLI (gh)" ok={deps?.ghAvailable ?? false} />
        {deps?.ghAvailable && !deps?.ghAuthenticated && (
          <div className="ml-6 flex items-center gap-1.5 text-[12px] text-amber-400">
            <svg
              className="w-3.5 h-3.5"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
              strokeWidth={2}
            >
              <path
                strokeLinecap="round"
                strokeLinejoin="round"
                d="M12 9v3.75m-9.303 3.376c-.866 1.5.217 3.374 1.948 3.374h14.71c1.73 0 2.813-1.874 1.948-3.374L13.949 3.378c-.866-1.5-3.032-1.5-3.898 0L2.697 16.126ZM12 15.75h.007v.008H12v-.008Z"
              />
            </svg>
            <span>
              gh is installed but not logged in. Run{" "}
              <code className="font-mono text-zinc-300">gh auth login</code> in
              a terminal.
            </span>
          </div>
        )}
      </div>

      {(!deps?.gitAvailable || !deps?.ghAvailable) && (
        <div className="flex flex-col gap-2">
          <p className="text-[12px] text-zinc-500">
            Install missing tools:
          </p>
          {!deps?.gitAvailable && (
            <CopyableCommand command="winget install Git.Git" />
          )}
          {!deps?.ghAvailable && (
            <CopyableCommand command="winget install GitHub.cli" />
          )}
        </div>
      )}

      <RecheckButton checking={checking} onRecheck={onRecheck} />
    </div>
  );
}

// ── Step 3: Add Project ─────────────────────────────────────────────────────

function ProjectStep({
  settings,
  onAdd,
  onRemove,
}: {
  settings: Settings | null;
  onAdd: () => void;
  onRemove: (path: string) => void;
}) {
  return (
    <div className="flex flex-col gap-5">
      <StepHeader
        icon={
          <svg
            className="w-5 h-5"
            fill="none"
            viewBox="0 0 24 24"
            stroke="currentColor"
            strokeWidth={1.5}
          >
            <path
              strokeLinecap="round"
              strokeLinejoin="round"
              d="M2.25 12.75V12A2.25 2.25 0 0 1 4.5 9.75h15A2.25 2.25 0 0 1 21.75 12v.75m-8.69-6.44-2.12-2.12a1.5 1.5 0 0 0-1.061-.44H4.5A2.25 2.25 0 0 0 2.25 6v12a2.25 2.25 0 0 0 2.25 2.25h15A2.25 2.25 0 0 0 21.75 18V9a2.25 2.25 0 0 0-2.25-2.25h-5.379a1.5 1.5 0 0 1-1.06-.44Z"
            />
          </svg>
        }
        title="Add a Project"
        description="Select the folder(s) where you use Claude Code. Sessions and git worktrees in these folders will appear on the board."
      />

      <button
        onClick={onAdd}
        className="flex items-center justify-center gap-2 px-4 py-2.5 rounded-xl bg-[#4f8ef7]/90 hover:bg-[#4f8ef7] text-white text-[13px] font-medium transition-all w-fit"
      >
        <svg
          className="w-4 h-4"
          fill="none"
          viewBox="0 0 24 24"
          stroke="currentColor"
          strokeWidth={2}
        >
          <path
            strokeLinecap="round"
            strokeLinejoin="round"
            d="M12 4.5v15m7.5-7.5h-15"
          />
        </svg>
        Add Project Folder
      </button>

      {settings && settings.projects.length > 0 && (
        <div className="flex flex-col gap-1.5 max-h-[160px] overflow-y-auto">
          {settings.projects.map((p) => (
            <div
              key={p.path}
              className="flex items-center justify-between px-3 py-2.5 bg-white/[0.03] border border-white/[0.06] rounded-xl"
            >
              <div className="min-w-0">
                <p className="text-[13px] text-zinc-300 truncate">
                  {p.name ?? p.path.split(/[/\\]/).pop() ?? p.path}
                </p>
                <p className="text-[11px] text-zinc-600 font-mono truncate">
                  {p.path}
                </p>
              </div>
              <button
                onClick={() => onRemove(p.path)}
                className="text-zinc-600 hover:text-[#f85149] transition-colors ml-2 shrink-0"
              >
                <svg
                  className="w-4 h-4"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke="currentColor"
                  strokeWidth={2}
                >
                  <path
                    strokeLinecap="round"
                    strokeLinejoin="round"
                    d="M6 18 18 6M6 6l12 12"
                  />
                </svg>
              </button>
            </div>
          ))}
        </div>
      )}

      {(!settings || settings.projects.length === 0) && (
        <p className="text-[12px] text-zinc-600">
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
}: {
  deps: DependencyStatus | null;
  settings: Settings | null;
}) {
  return (
    <div className="flex flex-col gap-5">
      <StepHeader
        icon={
          <svg
            className="w-5 h-5"
            fill="none"
            viewBox="0 0 24 24"
            stroke="currentColor"
            strokeWidth={1.5}
          >
            <path
              strokeLinecap="round"
              strokeLinejoin="round"
              d="M9 12.75 11.25 15 15 9.75M21 12c0 1.268-.63 2.39-1.593 3.068a3.745 3.745 0 0 1-1.043 3.296 3.745 3.745 0 0 1-3.296 1.043A3.745 3.745 0 0 1 12 21c-1.268 0-2.39-.63-3.068-1.593a3.746 3.746 0 0 1-3.296-1.043 3.746 3.746 0 0 1-1.043-3.296A3.745 3.745 0 0 1 3 12c0-1.268.63-2.39 1.593-3.068a3.746 3.746 0 0 1 1.043-3.296 3.746 3.746 0 0 1 3.296-1.043A3.746 3.746 0 0 1 12 3c1.268 0 2.39.63 3.068 1.593a3.746 3.746 0 0 1 3.296 1.043 3.746 3.746 0 0 1 1.043 3.296A3.745 3.745 0 0 1 21 12Z"
            />
          </svg>
        }
        title="Setup Complete"
        description="Here's a summary of your configuration."
      />

      <div className="flex flex-col gap-2">
        <SummaryRow label="Claude Code" ok={deps?.claudeAvailable ?? false} />
        <SummaryRow label="Git" ok={deps?.gitAvailable ?? false} />
        <SummaryRow label="GitHub CLI" ok={deps?.ghAuthenticated ?? false} />
        <SummaryRow
          label="Projects"
          ok={(settings?.projects.length ?? 0) > 0}
        />
      </div>

      <p className="text-[11px] text-zinc-600 mt-1">
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
}: {
  icon: React.ReactNode;
  title: string;
  description: string;
}) {
  return (
    <div className="flex flex-col gap-2">
      <div className="flex items-center gap-2.5">
        <span className="text-[#4f8ef7]">{icon}</span>
        <h3 className="text-[16px] font-semibold text-zinc-100">{title}</h3>
      </div>
      <p className="text-[13px] text-zinc-400 leading-relaxed">
        {description}
      </p>
    </div>
  );
}

function StatusRow({ label, ok }: { label: string; ok: boolean }) {
  return (
    <div className="flex items-center gap-2.5">
      {ok ? (
        <svg
          className="w-4 h-4 text-[#3fb950]"
          fill="currentColor"
          viewBox="0 0 24 24"
        >
          <path
            fillRule="evenodd"
            d="M2.25 12c0-5.385 4.365-9.75 9.75-9.75s9.75 4.365 9.75 9.75-4.365 9.75-9.75 9.75S2.25 17.385 2.25 12Zm13.36-1.814a.75.75 0 1 0-1.22-.872l-3.236 4.53L9.53 12.22a.75.75 0 0 0-1.06 1.06l2.25 2.25a.75.75 0 0 0 1.14-.094l3.75-5.25Z"
            clipRule="evenodd"
          />
        </svg>
      ) : (
        <div className="w-4 h-4 rounded-full border-[1.5px] border-zinc-600" />
      )}
      <span className="text-[13px] text-zinc-300">{label}</span>
      <span
        className={`ml-auto text-[11px] ${
          ok ? "text-[#3fb950]" : "text-amber-400"
        }`}
      >
        {ok ? "Ready" : "Not found"}
      </span>
    </div>
  );
}

function SummaryRow({ label, ok }: { label: string; ok: boolean }) {
  return (
    <div className="flex items-center gap-2.5">
      {ok ? (
        <svg
          className="w-4 h-4 text-[#3fb950]"
          fill="currentColor"
          viewBox="0 0 24 24"
        >
          <path
            fillRule="evenodd"
            d="M2.25 12c0-5.385 4.365-9.75 9.75-9.75s9.75 4.365 9.75 9.75-4.365 9.75-9.75 9.75S2.25 17.385 2.25 12Zm13.36-1.814a.75.75 0 1 0-1.22-.872l-3.236 4.53L9.53 12.22a.75.75 0 0 0-1.06 1.06l2.25 2.25a.75.75 0 0 0 1.14-.094l3.75-5.25Z"
            clipRule="evenodd"
          />
        </svg>
      ) : (
        <svg
          className="w-4 h-4 text-amber-400"
          fill="none"
          viewBox="0 0 24 24"
          stroke="currentColor"
          strokeWidth={1.5}
        >
          <path
            strokeLinecap="round"
            strokeLinejoin="round"
            d="M12 9v3.75m9-.75a9 9 0 1 1-18 0 9 9 0 0 1 18 0Zm-9 3.75h.008v.008H12v-.008Z"
          />
        </svg>
      )}
      <span className="text-[13px] text-zinc-300">{label}</span>
    </div>
  );
}

function CheckIcon() {
  return (
    <svg
      className="w-4 h-4"
      fill="currentColor"
      viewBox="0 0 24 24"
    >
      <path
        fillRule="evenodd"
        d="M2.25 12c0-5.385 4.365-9.75 9.75-9.75s9.75 4.365 9.75 9.75-4.365 9.75-9.75 9.75S2.25 17.385 2.25 12Zm13.36-1.814a.75.75 0 1 0-1.22-.872l-3.236 4.53L9.53 12.22a.75.75 0 0 0-1.06 1.06l2.25 2.25a.75.75 0 0 0 1.14-.094l3.75-5.25Z"
        clipRule="evenodd"
      />
    </svg>
  );
}

function CopyableCommand({ command }: { command: string }) {
  const [copied, setCopied] = useState(false);

  const copy = () => {
    navigator.clipboard.writeText(command);
    setCopied(true);
    setTimeout(() => setCopied(false), 1500);
  };

  return (
    <div className="flex items-center gap-2">
      <code className="flex-1 bg-white/[0.03] border border-white/[0.08] rounded-lg px-3 py-2 text-[12px] font-mono text-zinc-300 select-all">
        {command}
      </code>
      <button
        onClick={copy}
        className="text-zinc-500 hover:text-zinc-300 transition-colors shrink-0"
        title="Copy to clipboard"
      >
        {copied ? (
          <svg
            className="w-4 h-4 text-[#3fb950]"
            fill="none"
            viewBox="0 0 24 24"
            stroke="currentColor"
            strokeWidth={2}
          >
            <path
              strokeLinecap="round"
              strokeLinejoin="round"
              d="m4.5 12.75 6 6 9-13.5"
            />
          </svg>
        ) : (
          <svg
            className="w-4 h-4"
            fill="none"
            viewBox="0 0 24 24"
            stroke="currentColor"
            strokeWidth={1.5}
          >
            <path
              strokeLinecap="round"
              strokeLinejoin="round"
              d="M15.75 17.25v3.375c0 .621-.504 1.125-1.125 1.125h-9.75a1.125 1.125 0 0 1-1.125-1.125V7.875c0-.621.504-1.125 1.125-1.125H6.75a9.06 9.06 0 0 1 1.5.124m7.5 10.376h3.375c.621 0 1.125-.504 1.125-1.125V11.25c0-4.46-3.243-8.161-7.5-8.876a9.06 9.06 0 0 0-1.5-.124H9.375c-.621 0-1.125.504-1.125 1.125v3.5m7.5 10.375H9.375a1.125 1.125 0 0 1-1.125-1.125v-9.25m12 6.625v-1.875a3.375 3.375 0 0 0-3.375-3.375h-1.5a1.125 1.125 0 0 1-1.125-1.125v-1.5a3.375 3.375 0 0 0-3.375-3.375H9.75"
            />
          </svg>
        )}
      </button>
    </div>
  );
}

function RecheckButton({
  checking,
  onRecheck,
}: {
  checking: boolean;
  onRecheck: () => void;
}) {
  return (
    <button
      onClick={onRecheck}
      disabled={checking}
      className="flex items-center gap-1.5 px-3 py-1.5 rounded-lg bg-white/[0.04] hover:bg-white/[0.08] text-zinc-400 hover:text-zinc-200 text-[12px] transition-colors disabled:opacity-50 w-fit"
    >
      {checking && (
        <div className="w-3 h-3 border-[1.5px] border-zinc-400 border-t-transparent rounded-full animate-spin" />
      )}
      Re-check
    </button>
  );
}
