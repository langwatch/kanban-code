/**
 * Launch confirmation dialog — last gate before the embedded terminal
 * spawns `claude …`. Mirrors `Sources/KanbanCode/LaunchConfirmationDialog.swift`
 * with the macOS-specific knobs (run-remotely / API services) trimmed for
 * the Windows port. Surfaces:
 *
 *   * Editable prompt (the body the user typed in NewTaskDialog — they may
 *     still want to tweak it just before launch).
 *   * "Dangerously skip permissions" checkbox — passes `--dangerously-skip-permissions`
 *     to claude. Persisted globally so users who opt in stay opted in.
 *   * Optional `KEY=value` env prefix textarea (one var per line).
 *   * Editable command preview — auto-regenerates from the inputs above
 *     until the user manually edits it, at which point edits stick and
 *     the inputs become advisory.
 *
 * Returns the final command + flags via `onLaunch`. The caller is
 * responsible for actually starting the terminal with the resolved
 * command (see CardDetailView's terminal builder).
 */

import { useEffect, useMemo, useRef, useState } from "react";
import { useTheme, t } from "../theme";

export interface LaunchFlags {
  prompt: string;
  worktreeBranch: string;
  dangerouslySkipPermissions: boolean;
  envPrefix: string[]; // each entry "KEY=value"
  /** Non-null when the user manually edited the preview. */
  commandOverride: string | null;
}

interface Props {
  projectPath: string;
  initialPrompt: string;
  /** True when the project is a git repo + the card has no worktree yet. */
  canCreateWorktree: boolean;
  /** Persisted "dangerously skip permissions" from settings. */
  initialSkipPermissions: boolean;
  /**
   * Build the canonical launch command from the current inputs. Used to
   * populate the preview live until the user takes it over.
   */
  buildCommand: (flags: Omit<LaunchFlags, "commandOverride">) => string;
  onLaunch: (flags: LaunchFlags) => void;
  onCancel: () => void;
}

export default function LaunchConfirmationDialog({
  projectPath,
  initialPrompt,
  canCreateWorktree,
  initialSkipPermissions,
  buildCommand,
  onLaunch,
  onCancel,
}: Props) {
  const { theme } = useTheme();
  const c = t(theme);

  const [prompt, setPrompt] = useState(initialPrompt);
  const [worktreeBranch, setWorktreeBranch] = useState("");
  const [skipPermissions, setSkipPermissions] = useState(initialSkipPermissions);
  const [envText, setEnvText] = useState("");
  const [commandText, setCommandText] = useState("");
  // Once the user types into the command box, freeze it — input changes
  // no longer overwrite. Reset by editing the command back to match preview.
  const commandEdited = useRef(false);

  const envPrefix = useMemo(
    () =>
      envText
        .split("\n")
        .map((l) => l.trim())
        .filter((l) => l.length > 0 && /^[A-Z_][A-Z0-9_]*=/i.test(l)),
    [envText],
  );

  const previewCommand = useMemo(
    () =>
      buildCommand({
        prompt,
        worktreeBranch: canCreateWorktree ? worktreeBranch : "",
        dangerouslySkipPermissions: skipPermissions,
        envPrefix,
      }),
    [buildCommand, prompt, worktreeBranch, skipPermissions, envPrefix, canCreateWorktree],
  );

  useEffect(() => {
    if (!commandEdited.current) setCommandText(previewCommand);
  }, [previewCommand]);

  const onCommandChange = (v: string) => {
    setCommandText(v);
    // If the user edits BACK to exactly the preview, un-freeze so further
    // input changes resume driving it.
    commandEdited.current = v !== previewCommand;
  };

  const canLaunch = prompt.trim().length > 0 && commandText.trim().length > 0;

  const submit = () => {
    if (!canLaunch) return;
    onLaunch({
      prompt: prompt.trim(),
      worktreeBranch: worktreeBranch.trim(),
      dangerouslySkipPermissions: skipPermissions,
      envPrefix,
      commandOverride: commandEdited.current ? commandText : null,
    });
  };

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center"
      style={{ background: "rgba(0,0,0,0.55)" }}
      onClick={onCancel}
    >
      <div
        className="w-[640px] max-h-[88vh] overflow-auto rounded-lg shadow-2xl p-5 flex flex-col gap-4"
        style={{ background: c.bgDialog, border: `1px solid ${c.border}`, color: c.textPrimary }}
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-center justify-between">
          <h2 className="text-[15px] font-semibold">Launch Claude</h2>
          <button
            onClick={onCancel}
            className="text-xs opacity-60 hover:opacity-100"
            style={{ color: c.textMuted }}
          >
            Cancel
          </button>
        </div>

        <div className="text-[11px] flex items-center gap-2" style={{ color: c.textMuted }}>
          <svg className="w-3.5 h-3.5" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2}>
            <path strokeLinecap="round" strokeLinejoin="round" d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z" />
          </svg>
          <span className="truncate" title={projectPath}>{projectPath}</span>
        </div>

        <label className="flex flex-col gap-1 text-[12px]">
          <span style={{ color: c.textSecondary }}>Prompt</span>
          <textarea
            value={prompt}
            onChange={(e) => setPrompt(e.target.value)}
            rows={4}
            className="rounded px-2 py-1.5 text-[12px] font-mono resize-y"
            style={{ background: c.bgInput, border: `1px solid ${c.border}`, color: c.textPrimary }}
            autoFocus
          />
        </label>

        {canCreateWorktree && (
          <label className="flex flex-col gap-1 text-[12px]">
            <span style={{ color: c.textSecondary }}>Worktree branch (optional)</span>
            <input
              value={worktreeBranch}
              onChange={(e) => setWorktreeBranch(e.target.value)}
              placeholder="e.g. feat/ksuid"
              className="rounded px-2 py-1.5 text-[12px] font-mono"
              style={{ background: c.bgInput, border: `1px solid ${c.border}`, color: c.textPrimary }}
            />
          </label>
        )}

        <label className="flex items-center gap-2 text-[12px] cursor-pointer">
          <input
            type="checkbox"
            checked={skipPermissions}
            onChange={(e) => setSkipPermissions(e.target.checked)}
          />
          <span style={{ color: c.textSecondary }}>
            Dangerously skip permissions
          </span>
          <span className="text-[11px]" style={{ color: c.textMuted }}>
            (passes <code>--dangerously-skip-permissions</code>)
          </span>
        </label>

        <label className="flex flex-col gap-1 text-[12px]">
          <span style={{ color: c.textSecondary }}>
            Env prefix <span className="text-[11px]" style={{ color: c.textMuted }}>(one KEY=value per line)</span>
          </span>
          <textarea
            value={envText}
            onChange={(e) => setEnvText(e.target.value)}
            rows={2}
            placeholder="ANTHROPIC_API_KEY=sk-..."
            className="rounded px-2 py-1.5 text-[12px] font-mono resize-y"
            style={{ background: c.bgInput, border: `1px solid ${c.border}`, color: c.textPrimary }}
          />
        </label>

        <label className="flex flex-col gap-1 text-[12px]">
          <span style={{ color: c.textSecondary }}>
            Command preview
            {commandEdited.current && (
              <span className="text-[11px] ml-2" style={{ color: "#d29922" }}>
                edited — overrides flags above
              </span>
            )}
          </span>
          <textarea
            value={commandText}
            onChange={(e) => onCommandChange(e.target.value)}
            rows={4}
            className="rounded px-2 py-1.5 text-[12px] font-mono resize-y"
            style={{ background: c.bgInput, border: `1px solid ${c.border}`, color: c.textPrimary }}
          />
        </label>

        <div className="flex justify-end gap-2 mt-2">
          <button
            onClick={onCancel}
            className="rounded px-3 py-1.5 text-[12px] font-medium"
            style={{ background: c.bgInput, color: c.textSecondary, border: `1px solid ${c.border}` }}
          >
            Cancel
          </button>
          <button
            onClick={submit}
            disabled={!canLaunch}
            className="rounded px-4 py-1.5 text-[12px] font-medium"
            style={{
              background: canLaunch ? "#4f8ef7" : c.bgInput,
              color: canLaunch ? "white" : c.textMuted,
              cursor: canLaunch ? "pointer" : "not-allowed",
            }}
          >
            Launch
          </button>
        </div>
      </div>
    </div>
  );
}
