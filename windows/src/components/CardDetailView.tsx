import { forwardRef, useEffect, useState, useRef, useCallback } from "react";
import { ask } from "@tauri-apps/plugin-dialog";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import {
  getTranscript,
  getSettings,
  openInEditor,
  useBoardStore,
  addQueuedPrompt,
  updateQueuedPrompt,
  removeQueuedPrompt,
  searchTranscript,
  mergePr,
  openGithubPr,
  openGithubIssue,
  removeWorktree,
  forkSession,
  truncateSession,
  moveCardToProject,
} from "../store/boardStore";
import { ASSISTANT_CLI, type Project, type AssistantId } from "../types";
import { useTheme, t } from "../theme";
import type { Turn, TranscriptPage, QueuedPrompt } from "../types";
import TerminalView from "./Terminal";
import QueuedPromptDialog from "./QueuedPromptDialog";
import QueuedPromptsBar from "./QueuedPromptsBar";
import LaunchConfirmationDialog, { type LaunchFlags } from "./LaunchConfirmationDialog";

type Tab = "terminal" | "history" | "issue" | "pr" | "prompt";

const TAB_LABELS: Record<Tab, string> = {
  terminal: "Terminal",
  history: "History",
  issue: "Issue",
  pr: "PR",
  prompt: "Prompt",
};

export default function CardDetailView() {
  const { selectedCard, selectCard, renameCard, deleteCard } = useBoardStore();
  const card = selectedCard();
  const { theme } = useTheme();
  const c = t(theme);

  const [activeTab, setActiveTab] = useState<Tab>("terminal");
  const [turns, setTurns] = useState<Turn[]>([]);
  const [transcriptPage, setTranscriptPage] = useState<TranscriptPage | null>(null);
  const [loadingTranscript, setLoadingTranscript] = useState(false);
  const [isEditing, setIsEditing] = useState(false);
  const [editName, setEditName] = useState("");
  const [terminalActive, setTerminalActive] = useState(false);
  const [drawerWidth, setDrawerWidth] = useState(480);
  const isResizing = useRef(false);

  // Queued prompts state
  const [showQueueDialog, setShowQueueDialog] = useState(false);
  const [editingPrompt, setEditingPrompt] = useState<QueuedPrompt | null>(null);
  const [queuedPrompts, setQueuedPrompts] = useState<QueuedPrompt[]>([]);
  const terminalWriteRef = useRef<((text: string) => void) | null>(null);

  // Settings
  const [terminalFontSize, setTerminalFontSize] = useState(15);
  const [terminalShell, setTerminalShell] = useState<string>("cmd.exe");
  // Whether `tmux -V` succeeds in the user's WSL environment. When true AND
  // the chosen shell is a Unix shell, terminals are wrapped in
  // `tmux new-session -A -s <ksuid>` so closing the drawer detaches (the
  // tmux server keeps Claude running) and reopening reattaches with the
  // pane scrollback intact. When false, the legacy one-shot PTY is used.
  const [tmuxAvailable, setTmuxAvailable] = useState(false);

  // Launch confirmation: when a fresh-launch card opens its terminal tab, we
  // show LaunchConfirmationDialog first so the user can tweak the prompt,
  // toggle --dangerously-skip-permissions, prepend env vars, or hand-edit the
  // command. Resolved flags drive the inner-command builder below. Resumes
  // bypass the dialog (no command to choose — `claude --resume <id>`).
  const [showLaunchDialog, setShowLaunchDialog] = useState(false);
  const [launchFlags, setLaunchFlags] = useState<LaunchFlags | null>(null);

  // Multi-tab state: each tab is a tmux window inside the card's session.
  // Window 1 is the "Claude" tab created by Step 2's session-wrap; extra
  // windows are bare shells the user adds with the "+" button (e.g. for
  // git/ls work alongside Claude). Indexes match tmux's 1-based window ids.
  type TmuxWindow = { index: number; name: string; active: boolean };
  const [terminalTabs, setTerminalTabs] = useState<TmuxWindow[]>([]);
  const [activeTermTab, setActiveTermTab] = useState<number>(1);
  const [availableProjects, setAvailableProjects] = useState<Project[]>([]);

  // Copy / "more" menu
  const [moreMenuOpen, setMoreMenuOpen] = useState(false);
  const [copiedLabel, setCopiedLabel] = useState<string | null>(null);
  const copyTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const moreButtonRef = useRef<HTMLButtonElement>(null);
  const moreMenuRef = useRef<HTMLDivElement>(null);

  // Search state
  const [searchText, setSearchText] = useState("");
  const [searchMatches, setSearchMatches] = useState<number[]>([]);
  const [currentMatchIdx, setCurrentMatchIdx] = useState(0);
  const [isSearching, setIsSearching] = useState(false);
  const searchDebounce = useRef<ReturnType<typeof setTimeout> | null>(null);

  const handleMouseDown = useCallback((e: React.MouseEvent) => {
    e.preventDefault();
    isResizing.current = true;
    const startX = e.clientX;
    const startWidth = drawerWidth;

    const onMouseMove = (e: MouseEvent) => {
      if (!isResizing.current) return;
      const delta = startX - e.clientX;
      setDrawerWidth(Math.min(Math.max(startWidth + delta, 340), 960));
    };

    const onMouseUp = () => {
      isResizing.current = false;
      document.removeEventListener("mousemove", onMouseMove);
      document.removeEventListener("mouseup", onMouseUp);
      document.body.style.cursor = "";
      document.body.style.userSelect = "";
    };

    document.body.style.cursor = "col-resize";
    document.body.style.userSelect = "none";
    document.addEventListener("mousemove", onMouseMove);
    document.addEventListener("mouseup", onMouseUp);
  }, [drawerWidth]);

  // Load terminal font size + shell from settings
  useEffect(() => {
    getSettings()
      .then((s) => {
        setTerminalFontSize(s.terminalFontSize || 15);
        setTerminalShell((s.terminalShell && s.terminalShell.trim()) || "cmd.exe");
        setAvailableProjects(s.projects ?? []);
      })
      .catch(() => {});
    invoke<boolean>("tmux_available")
      .then((v) => setTmuxAvailable(!!v))
      .catch(() => setTmuxAvailable(false));
  }, []);

  // Reset state when card changes
  useEffect(() => {
    if (!card) return;
    const hasTerminal = !!card.link.sessionLink?.sessionId || !!card.link.promptBody;
    setActiveTab(hasTerminal ? "terminal" : "history");
    setTurns([]);
    setTranscriptPage(null);
    setTerminalActive(false);
    setQueuedPrompts(card.link.queuedPrompts ?? []);
    setSearchText("");
    setSearchMatches([]);
    setCurrentMatchIdx(0);
    if (card.link.sessionLink?.sessionId) {
      loadTranscript(card.link.sessionLink.sessionId, 0, true);
    }
  }, [card?.id]);

  // Sync queued prompts when card data updates
  useEffect(() => {
    if (card) {
      setQueuedPrompts(card.link.queuedPrompts ?? []);
    }
  }, [card?.link.updatedAt]);

  const loadTranscript = async (sessionId: string, offset: number, reset: boolean) => {
    setLoadingTranscript(true);
    try {
      const page = await getTranscript(sessionId, offset);
      setTranscriptPage(page);
      setTurns((prev) => (reset ? page.turns : [...prev, ...page.turns]));
    } catch {
      // silent
    } finally {
      setLoadingTranscript(false);
    }
  };

  // Search debounce
  useEffect(() => {
    if (!card?.link.sessionLink?.sessionId) return;
    if (searchDebounce.current) clearTimeout(searchDebounce.current);

    if (searchText.trim().length < 2) {
      setSearchMatches([]);
      setCurrentMatchIdx(0);
      setIsSearching(false);
      return;
    }

    setIsSearching(true);
    searchDebounce.current = setTimeout(async () => {
      try {
        const matches = await searchTranscript(card.link.sessionLink!.sessionId, searchText.trim());
        setSearchMatches(matches);
        setCurrentMatchIdx(0);
      } catch {
        setSearchMatches([]);
      } finally {
        setIsSearching(false);
      }
    }, 300);

    return () => { if (searchDebounce.current) clearTimeout(searchDebounce.current); };
  }, [searchText, card?.link.sessionLink?.sessionId]);

  if (!card) return null;

  const sessionId = card.link.sessionLink?.sessionId;
  const projectPath = card.link.projectPath ?? card.session?.projectPath;
  const branch = card.link.worktreeLink?.branch;
  const pr = card.link.prLinks[0];
  const issue = card.link.issueLink;
  const promptBody = card.link.promptBody;
  const canTerminal = !!sessionId || !!promptBody;

  const handleRename = () => {
    if (editName.trim()) renameCard(card.id, editName.trim());
    setIsEditing(false);
  };

  const handleConfirmDelete = async () => {
    if (!card) return;
    const title = card.displayTitle || card.link.name || "this card";
    const detail = terminalActive
      ? "The open terminal will be stopped. The Claude session .jsonl on disk is not deleted."
      : "The Claude session .jsonl on disk is not deleted — you can still find it in All Sessions.";
    const ok = await ask(`Delete "${title}"?\n\n${detail}`, {
      title: "Delete card",
      kind: "warning",
      okLabel: "Delete",
      cancelLabel: "Cancel",
    });
    if (ok) deleteCard(card.id);
  };

  const handleFork = async () => {
    if (!card) return;
    const sessionPath = card.link.sessionLink?.sessionPath;
    if (!sessionPath) return;
    setMoreMenuOpen(false);
    try {
      const newId = await forkSession(sessionPath);
      // Trigger a board refresh so the new session shows up.
      useBoardStore.getState().refresh();
      useBoardStore.setState({ error: `Forked session → ${newId}` });
    } catch (e) {
      useBoardStore.setState({ error: String(e) });
    }
  };

  const handleCheckpoint = async (turnIndex: number) => {
    if (!card) return;
    const sessionPath = card.link.sessionLink?.sessionPath;
    if (!sessionPath) return;
    // turnIndex is 0-based; truncateSession keeps the first N turns (1-based).
    const turnCount = turnIndex + 1;
    const ok = await ask(
      `Checkpoint session to turn ${turnCount}?\n\nEverything after this turn is removed from the .jsonl. The original is backed up next to it as <session>.jsonl.bkp.`,
      { title: "Checkpoint session", kind: "warning", okLabel: "Checkpoint", cancelLabel: "Cancel" }
    );
    if (!ok) return;
    try {
      await truncateSession(sessionPath, turnCount);
      // Re-read the transcript so the drawer view reflects the new tail.
      loadTranscript(card.link.sessionLink!.sessionId, 0, true);
    } catch (e) {
      useBoardStore.setState({ error: String(e) });
    }
  };

  const handleRemoveWorktree = async () => {
    if (!card) return;
    const wt = card.link.worktreeLink;
    if (!wt || !wt.path) return;
    const ok = await ask(
      `Remove worktree at\n${wt.path}?\n\nRuns "git worktree remove" against your repo. The branch is preserved.`,
      { title: "Remove worktree", kind: "warning", okLabel: "Remove", cancelLabel: "Cancel" }
    );
    if (!ok) return;
    setMoreMenuOpen(false);
    try {
      await removeWorktree(wt.path, card.link.projectPath ?? null, false);
    } catch (e) {
      // Surface the git error via the standard error toast.
      useBoardStore.setState({ error: String(e) });
    }
  };

  const handleCopy = async (label: string, text: string | undefined | null) => {
    if (!text) return;
    try {
      await navigator.clipboard.writeText(text);
      if (copyTimer.current) clearTimeout(copyTimer.current);
      setCopiedLabel(label);
      copyTimer.current = setTimeout(() => setCopiedLabel(null), 1400);
    } catch {
      // clipboard can fail under flaky focus; user can retry
    }
  };

  // Split the user-configurable shell string into [exe, ...args]. Default is
  // cmd.exe so the app is Windows-native out of the box; setting it to
  // "wsl.exe" launches Claude inside WSL instead.
  const baseShell = terminalShell.trim().split(/\s+/).filter(Boolean);
  const shellExe = (baseShell[0] ?? "cmd.exe").toLowerCase();
  const isUnixShell = /(^|[\\/])(wsl|bash|sh|zsh|fish)(\.exe)?$/.test(shellExe);
  // tmux requires a Unix shell AND a working `tmux -V` inside it.
  const useTmux = isUnixShell && tmuxAvailable;

  const assistantId: AssistantId = (card.link.assistantId ?? "claude") as AssistantId;
  const cli = ASSISTANT_CLI[assistantId] ?? "claude";

  // Effective prompt + flags after the launch dialog (if shown). For resumes,
  // the dialog is skipped — launchFlags stays null and the dialog defaults
  // apply (no skip-perm, no env prefix). The same builder also feeds the
  // dialog's live preview so what the user sees is what runs.
  const effectivePrompt = launchFlags?.prompt ?? promptBody ?? "";
  const effectiveSkipPerm = launchFlags?.dangerouslySkipPermissions ?? false;
  const effectiveEnv = launchFlags?.envPrefix ?? [];

  const buildInnerBashCmd = useCallback(
    (
      cwd: string | undefined,
      sid: string | null,
      prompt: string,
      skipPerm: boolean,
      env: string[],
    ) => {
      const envPrefix = env.length > 0 ? env.join(" ") + " " : "";
      const cdCmd = cwd ? `cd ${cwd.replace(/ /g, "\\ ")} && ` : "";
      const skipFlag = skipPerm ? " --dangerously-skip-permissions" : "";
      return sid
        ? `${cdCmd}${envPrefix}${cli} --resume ${sid}${skipFlag}`
        : `${cdCmd}${envPrefix}${cli}${skipFlag} '${prompt.replace(/'/g, "'\\''")}'`;
    },
    [cli],
  );

  const buildInnerCmdShellCmd = useCallback(
    (
      cwd: string | undefined,
      sid: string | null,
      prompt: string,
      skipPerm: boolean,
      env: string[],
    ) => {
      // `set VAR=val&&` chains in cmd.exe; pwsh accepts `$env:VAR='val';`,
      // but cmd is the default — stick with set-style.
      const envPrefix = env.length > 0 ? env.map((kv) => `set ${kv}&& `).join("") : "";
      const cdCmd = cwd ? `cd "${cwd}" && ` : "";
      const skipFlag = skipPerm ? " --dangerously-skip-permissions" : "";
      return sid
        ? `${cdCmd}${envPrefix}${cli} --resume ${sid}${skipFlag}`
        : `${cdCmd}${envPrefix}${cli}${skipFlag} "${prompt.replace(/"/g, '""')}"`;
    },
    [cli],
  );

  // The inner bash command (`cd … && claude …`) — same for tmux + legacy
  // paths. Inside tmux it's the one-shot session-creation command; outside,
  // it's typed by Terminal.tsx after 800ms.
  const innerBashCmd =
    launchFlags?.commandOverride ??
    buildInnerBashCmd(projectPath ?? undefined, sessionId ?? null, effectivePrompt, effectiveSkipPerm, effectiveEnv);

  const innerCmdShellCmd =
    launchFlags?.commandOverride ??
    buildInnerCmdShellCmd(projectPath ?? undefined, sessionId ?? null, effectivePrompt, effectiveSkipPerm, effectiveEnv);

  // Build the actual argv handed to the PTY + the optional post-spawn
  // type-this-after-800ms string.
  //
  // Tmux mode: PTY runs `wsl bash -lc "tmux new-session -A -s '<ksuid>' …"`.
  //   * `-A` makes new-session attach if the named session already exists
  //     and only run the inner shell-command on first create. So a fresh
  //     PTY on reopen reattaches the existing Claude pane intact.
  //   * The inner shell-command is encoded as base64 to side-step quoting:
  //     `bash -lc "$(echo <b64> | base64 -d)"`. Without this, single-quoted
  //     prompt bodies + multi-level quoting (Windows argv → bash → tmux)
  //     would break the moment the user types an apostrophe.
  //   * `; exec bash` keeps the pane alive after Claude exits so the user
  //     can inspect output / re-run claude without the session dying.
  //
  // Legacy mode: existing behavior — spawn the configured shell, then type
  // the cd + claude line after 800ms via Terminal.tsx's `initialInput`.
  const tmuxSession = `kanban-${card.id}`;
  const { shellCommand, terminalInput } = (() => {
    if (useTmux) {
      // Unified wrapper for any tab N:
      //   1. `new-session -A -d` — idempotently create the session and run
      //      the inner cd+claude on first call (only — `-A` skips creation
      //      if it already exists). `-d` returns immediately so the next
      //      tmux call runs.
      //   2. `select-window -t session:N` — make tab N the active window
      //      (silent no-op if it doesn't exist yet).
      //   3. `exec attach-session` — replace the bash shell with the tmux
      //      client so PTY death closes the client cleanly.
      const inner = `${innerBashCmd}; exec bash`;
      const b64 = btoa(unescape(encodeURIComponent(inner)));
      const wrapper =
        `tmux new-session -A -d -s '${tmuxSession}' -- bash -lc "$(echo ${b64} | base64 -d)" 2>/dev/null; ` +
        `tmux select-window -t '${tmuxSession}:${activeTermTab}' 2>/dev/null; ` +
        `exec tmux attach-session -t '${tmuxSession}'`;
      return {
        shellCommand: ["wsl.exe", "--", "bash", "-lc", wrapper],
        terminalInput: "",
      };
    }
    if (isUnixShell) {
      // bash without tmux — fall back to type-after-spawn so non-tmux WSL
      // users still get a working terminal (just no reattach).
      return { shellCommand: baseShell, terminalInput: `${innerBashCmd}\r` };
    }
    // Native Windows shell.
    return { shellCommand: baseShell, terminalInput: `${innerCmdShellCmd}\r` };
  })();

  // Pull the current window list whenever the terminal becomes active in
  // tmux mode. Refreshed manually after add/close — no periodic poll.
  const refreshTmuxTabs = useCallback(async () => {
    if (!useTmux) return;
    try {
      const wins = await invoke<TmuxWindow[]>("tmux_list_windows", {
        session: tmuxSession,
      });
      setTerminalTabs(wins);
    } catch {
      setTerminalTabs([]);
    }
  }, [useTmux, tmuxSession]);

  useEffect(() => {
    if (useTmux && terminalActive) {
      // Slight delay so the session has time to come up on first launch.
      const t = setTimeout(refreshTmuxTabs, 800);
      return () => clearTimeout(t);
    }
  }, [useTmux, terminalActive, refreshTmuxTabs, card.id]);

  const handleAddTermTab = async () => {
    if (!useTmux) return;
    try {
      const idx = await invoke<number>("tmux_new_window", {
        session: tmuxSession,
        cwdWindows: projectPath ?? null,
        command: null,
      });
      setActiveTermTab(idx);
      await refreshTmuxTabs();
    } catch (e) {
      useBoardStore.setState({ error: String(e) });
    }
  };

  // ── Hook-driven queued-prompt auto-send ────────────────────────────────────
  // Mirrors the macOS `BackgroundOrchestrator.autoSendQueuedPrompt` flow:
  // when Claude fires a `Stop` hook event for THIS card's session, wait
  // ~1s, and if the user hasn't typed a new prompt during that window,
  // send the first queued prompt where `sendAutomatically` is true. A
  // 62-second dedup window on each prompt id prevents a flapping Stop
  // event (e.g. a quick second tool call) from double-sending.
  //
  // Refs not state — these change continuously and shouldn't trigger
  // re-renders.
  const lastUserPromptAt = useRef<number>(0);
  const recentlyAutoSent = useRef<Map<string, number>>(new Map());

  useEffect(() => {
    if (!card) return;
    const sessId = card.link.sessionLink?.sessionId;
    if (!sessId) return;
    let cancelled = false;
    let pending: ReturnType<typeof setTimeout> | null = null;
    const unsubP = listen<{
      sessionId: string;
      eventName: string;
      transcriptPath: string | null;
      notificationType: string | null;
      timestamp: string;
    }>("hook-event", (ev) => {
      if (cancelled) return;
      const p = ev.payload;
      if (!p || p.sessionId !== sessId) return;
      if (p.eventName === "UserPromptSubmit") {
        lastUserPromptAt.current = Date.now();
        return;
      }
      if (p.eventName !== "Stop") return;
      const stopAt = Date.now();
      if (pending) clearTimeout(pending);
      pending = setTimeout(() => {
        // User typed in the meantime — back off.
        if (Date.now() - lastUserPromptAt.current < 1100) return;
        // Resolve the freshest queue from the store (closure value would be
        // stale by the time the timer fires).
        const fresh = useBoardStore.getState().cards.find((c) => c.id === card.id)?.link
          .queuedPrompts ?? queuedPrompts;
        const now = Date.now();
        const target = fresh.find(
          (qp) =>
            qp.sendAutomatically &&
            (recentlyAutoSent.current.get(qp.id) ?? 0) + 62_000 < now,
        );
        if (!target || !terminalWriteRef.current) return;
        terminalWriteRef.current(target.body + "\r");
        recentlyAutoSent.current.set(target.id, now);
        // Garbage-collect dedup entries older than 5 minutes.
        for (const [id, at] of recentlyAutoSent.current) {
          if (now - at > 5 * 60_000) recentlyAutoSent.current.delete(id);
        }
        removeQueuedPrompt(card.id, target.id)
          .then(() =>
            setQueuedPrompts((prev) => prev.filter((p) => p.id !== target.id)),
          )
          .catch(() => {});
      }, 1000);
      // suppress "unused" lint
      void stopAt;
    });

    return () => {
      cancelled = true;
      if (pending) clearTimeout(pending);
      unsubP.then((unsub) => unsub()).catch(() => {});
    };
  }, [card?.id, card?.link.sessionLink?.sessionId]);

  const handleCloseTermTab = async (idx: number) => {
    if (!useTmux) return;
    // Don't let the user kill the main Claude tab — it's tied to the
    // session lifecycle and would force a full relaunch.
    if (idx === 1) return;
    try {
      await invoke("tmux_kill_window", {
        target: `${tmuxSession}:${idx}`,
      });
      if (activeTermTab === idx) setActiveTermTab(1);
      await refreshTmuxTabs();
    } catch (e) {
      useBoardStore.setState({ error: String(e) });
    }
  };

  const handleStartTerminal = () => {
    // Resumes — no choices to make, jump straight in.
    if (sessionId) {
      setTerminalActive(true);
      setActiveTab("terminal");
      return;
    }
    // Fresh launch — let the user review the command first.
    setShowLaunchDialog(true);
    setActiveTab("terminal");
  };

  // Auto-open the launch dialog for freshly created tasks so the user sees
  // the command preview before Claude starts churning. They can cancel out.
  useEffect(() => {
    if (!sessionId && promptBody && !terminalActive && !showLaunchDialog && !launchFlags) {
      setShowLaunchDialog(true);
      setActiveTab("terminal");
    }
  }, [card.id]);

  // Queued prompt handlers
  const handleAddPrompt = async (body: string, sendAutomatically: boolean) => {
    try {
      const prompt = await addQueuedPrompt(card.id, body, sendAutomatically);
      setQueuedPrompts((prev) => [...prev, prompt]);
    } catch { /* silent */ }
  };

  const handleUpdatePrompt = async (body: string, sendAutomatically: boolean) => {
    if (!editingPrompt) return;
    try {
      await updateQueuedPrompt(card.id, editingPrompt.id, body, sendAutomatically);
      setQueuedPrompts((prev) =>
        prev.map((p) => p.id === editingPrompt.id ? { ...p, body, sendAutomatically } : p)
      );
    } catch { /* silent */ }
  };

  const handleRemovePrompt = async (promptId: string) => {
    try {
      await removeQueuedPrompt(card.id, promptId);
      setQueuedPrompts((prev) => prev.filter((p) => p.id !== promptId));
    } catch { /* silent */ }
  };

  const handleSendNow = async (promptId: string) => {
    const prompt = queuedPrompts.find((p) => p.id === promptId);
    if (!prompt || !terminalWriteRef.current) return;
    // Write to terminal
    terminalWriteRef.current(prompt.body + "\r");
    // Remove from queue
    handleRemovePrompt(promptId);
  };

  const handleEditPrompt = (prompt: QueuedPrompt) => {
    setEditingPrompt(prompt);
    setShowQueueDialog(true);
  };

  // Search navigation
  const goToMatch = (dir: "prev" | "next") => {
    if (searchMatches.length === 0) return;
    setCurrentMatchIdx((prev) => {
      if (dir === "next") return (prev + 1) % searchMatches.length;
      return (prev - 1 + searchMatches.length) % searchMatches.length;
    });
  };

  // Only show tabs that have data
  const availableTabs: Tab[] = (["terminal", "history", "issue", "pr", "prompt"] as Tab[]).filter((tab) => {
    if (tab === "terminal") return canTerminal;
    if (tab === "history") return !!sessionId;
    if (tab === "issue") return !!issue;
    if (tab === "pr") return !!pr;
    if (tab === "prompt") return !!promptBody;
    return false;
  });

  return (
    <div
      className="flex flex-col h-full overflow-hidden relative animate-slide-in"
      style={{
        width: drawerWidth,
        minWidth: 340,
        maxWidth: 960,
        background: c.bgDetail,
        borderLeft: `1px solid ${c.border}`,
      }}
    >
      {/* Resize handle */}
      <div
        onMouseDown={handleMouseDown}
        className="absolute left-0 top-0 bottom-0 z-10 group"
        style={{ width: 6, cursor: "col-resize" }}
      >
        <div
          className="absolute left-[2px] top-0 bottom-0 w-[2px] rounded-full transition-all duration-150 opacity-0 group-hover:opacity-100 group-active:opacity-100"
          style={{ background: "#4f8ef7" }}
        />
      </div>

      {/* Header */}
      <div className="px-5 pt-5 pb-4 shrink-0">
        {/* Title row */}
        <div className="flex items-start justify-between gap-3">
          {isEditing ? (
            <input
              autoFocus
              className="flex-1 rounded-lg px-3 py-1.5 text-[15px] font-medium outline-none"
              style={{
                background: c.bgInput,
                border: `1px solid rgba(79,142,247,0.4)`,
                color: c.textPrimary,
              }}
              value={editName}
              onChange={(e) => setEditName(e.target.value)}
              onBlur={handleRename}
              onKeyDown={(e) => {
                if (e.key === "Enter") handleRename();
                if (e.key === "Escape") setIsEditing(false);
              }}
            />
          ) : (
            <h2
              className="flex-1 text-[17px] font-semibold leading-snug tracking-[-0.01em] cursor-text"
              style={{ color: c.textPrimary }}
              onClick={() => { setEditName(card.displayTitle); setIsEditing(true); }}
              title="Click to rename"
            >
              {card.displayTitle}
            </h2>
          )}
          <div className="flex items-center gap-1 mt-0.5 shrink-0 relative">
            <button
              ref={moreButtonRef}
              onClick={() => setMoreMenuOpen((o) => !o)}
              className="rounded-md p-1 transition-all duration-150"
              style={{
                color: moreMenuOpen ? c.textPrimary : c.textDim,
                background: moreMenuOpen ? c.hoverBg : "",
              }}
              onMouseEnter={(e) => { if (!moreMenuOpen) { e.currentTarget.style.background = c.hoverBg; e.currentTarget.style.color = c.textSecondary; } }}
              onMouseLeave={(e) => { if (!moreMenuOpen) { e.currentTarget.style.background = ""; e.currentTarget.style.color = c.textDim; } }}
              title="Copy ID, resume command, paths…"
            >
              <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M12 6.75a.75.75 0 1 1 0-1.5.75.75 0 0 1 0 1.5Zm0 6a.75.75 0 1 1 0-1.5.75.75 0 0 1 0 1.5Zm0 6a.75.75 0 1 1 0-1.5.75.75 0 0 1 0 1.5Z" />
              </svg>
            </button>
            <button
              onClick={() => selectCard(null)}
              className="rounded-md p-1 transition-all duration-150"
              style={{ color: c.textDim }}
              onMouseEnter={(e) => { e.currentTarget.style.background = c.hoverBg; e.currentTarget.style.color = c.textSecondary; }}
              onMouseLeave={(e) => { e.currentTarget.style.background = ""; e.currentTarget.style.color = c.textDim; }}
              title="Close"
            >
              <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2.5}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M6 18 18 6M6 6l12 12" />
              </svg>
            </button>
            {moreMenuOpen && (
              <CardMoreMenu
                ref={moreMenuRef}
                anchorRef={moreButtonRef}
                onClose={() => setMoreMenuOpen(false)}
                onCopy={handleCopy}
                cardId={card.id}
                sessionId={sessionId}
                projectPath={projectPath}
                branch={branch}
                prUrl={pr?.url}
                worktreePath={card.link.worktreeLink?.path}
                onRemoveWorktree={handleRemoveWorktree}
                onFork={sessionId ? handleFork : undefined}
                copiedLabel={copiedLabel}
                themeTokens={c}
                cardProjectPath={card.link.projectPath}
                availableProjects={availableProjects}
                onMoveToProject={async (targetPath) => {
                  setMoreMenuOpen(false);
                  try {
                    await moveCardToProject(card.id, targetPath);
                    await useBoardStore.getState().refresh();
                  } catch (e) {
                    useBoardStore.setState({ error: String(e) });
                  }
                }}
              />
            )}
          </div>
        </div>

        {/* Meta row */}
        <div className="flex flex-wrap items-center gap-2 mt-3">
          {card.projectName && (
            <span
              className="text-[12px] font-medium px-2 py-0.5 rounded-md"
              style={{ color: c.textMuted, background: c.bgAccent("0.04") }}
              title={projectPath ?? ""}
            >
              {card.projectName}
            </span>
          )}
          {branch && <MetaBadge label={branch} color="#4f8ef7" theme={theme} title={`Branch: ${branch}`} />}
          {pr && <MetaBadge label={`PR #${pr.number}`} color="#3fb950" theme={theme} title={pr.title ?? ""} />}
          {issue && <MetaBadge label={`#${issue.number}`} color="#d29922" theme={theme} title={issue.title ?? ""} />}
        </div>

        {/* Actions */}
        <div className="flex gap-2.5 mt-4">
          {canTerminal && (
            <button
              onClick={handleStartTerminal}
              className="flex-1 flex items-center justify-center gap-2 h-9 rounded-lg text-[13px] font-semibold transition-all duration-150"
              style={{
                background: "#4f8ef7",
                color: "#fff",
              }}
              onMouseEnter={(e) => { e.currentTarget.style.background = "#5e9aff"; e.currentTarget.style.transform = "translateY(-0.5px)"; }}
              onMouseLeave={(e) => { e.currentTarget.style.background = "#4f8ef7"; e.currentTarget.style.transform = ""; }}
              title={terminalActive ? "Switch to terminal view" : sessionId ? "Resume this session" : "Start Claude session"}
            >
              <svg className="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2.5}>
                <path strokeLinecap="round" strokeLinejoin="round" d="m5.25 4.5 7.5 7.5-7.5 7.5m6-15 7.5 7.5-7.5 7.5" />
              </svg>
              {terminalActive ? "Terminal" : sessionId ? "Resume" : "Start"}
            </button>
          )}
          {canTerminal && terminalActive && (
            <button
              onClick={() => { setEditingPrompt(null); setShowQueueDialog(true); }}
              className="flex items-center justify-center gap-1.5 h-9 px-3 rounded-lg text-[13px] font-medium transition-all duration-150"
              style={{ border: `1px solid ${c.border}`, color: c.textSecondary }}
              onMouseEnter={(e) => { e.currentTarget.style.borderColor = c.borderBright; e.currentTarget.style.background = c.hoverBg; }}
              onMouseLeave={(e) => { e.currentTarget.style.borderColor = c.border; e.currentTarget.style.background = ""; }}
              title="Queue a prompt to send to Claude later"
            >
              <svg className="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M12 4.5v15m7.5-7.5h-15" />
              </svg>
              Queue
            </button>
          )}
          {projectPath && (
            <button
              onClick={() => openInEditor(projectPath)}
              className="flex items-center justify-center gap-2 h-9 px-3 rounded-lg text-[13px] font-medium transition-all duration-150"
              style={{ border: `1px solid ${c.border}`, color: c.textSecondary }}
              onMouseEnter={(e) => { e.currentTarget.style.borderColor = c.borderBright; e.currentTarget.style.background = c.hoverBg; e.currentTarget.style.transform = "translateY(-0.5px)"; }}
              onMouseLeave={(e) => { e.currentTarget.style.borderColor = c.border; e.currentTarget.style.background = ""; e.currentTarget.style.transform = ""; }}
              title={`Open in editor: ${projectPath}`}
            >
              <svg className="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                <path strokeLinecap="round" strokeLinejoin="round" d="m10 20-7-7 7-7M17 20l7-7-7-7" />
              </svg>
              Editor
            </button>
          )}
          <button
            onClick={handleConfirmDelete}
            className="flex items-center justify-center gap-2 h-9 px-3 rounded-lg text-[13px] font-medium transition-all duration-150"
            style={{ border: `1px solid ${c.border}`, color: c.textDim }}
            onMouseEnter={(e) => { e.currentTarget.style.borderColor = "#f85149"; e.currentTarget.style.color = "#f85149"; e.currentTarget.style.background = "rgba(248,81,73,0.06)"; }}
            onMouseLeave={(e) => { e.currentTarget.style.borderColor = c.border; e.currentTarget.style.color = c.textDim; e.currentTarget.style.background = ""; }}
            title="Delete this card"
          >
            <svg className="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
              <path strokeLinecap="round" strokeLinejoin="round" d="m14.74 9-.346 9m-4.788 0L9.26 9m9.968-3.21c.342.052.682.107 1.022.166m-1.022-.165L18.16 19.673a2.25 2.25 0 0 1-2.244 2.077H8.084a2.25 2.25 0 0 1-2.244-2.077L4.772 5.79m14.456 0a48.108 48.108 0 0 0-3.478-.397m-12 .562c.34-.059.68-.114 1.022-.165m0 0a48.11 48.11 0 0 1 3.478-.397m7.5 0v-.916c0-1.18-.91-2.164-2.09-2.201a51.964 51.964 0 0 0-3.32 0c-1.18.037-2.09 1.022-2.09 2.201v.916m7.5 0a48.667 48.667 0 0 0-7.5 0" />
            </svg>
          </button>
        </div>
      </div>

      {/* Tabs */}
      {availableTabs.length > 1 && (
        <div className="flex px-5 shrink-0 gap-1" style={{ borderBottom: `1px solid ${c.border}` }}>
          {availableTabs.map((tab) => {
            const active = activeTab === tab;
            return (
              <button
                key={tab}
                onClick={() => setActiveTab(tab)}
                className="relative pb-2.5 pt-1.5 px-3 text-[12px] font-medium transition-colors duration-150"
                style={{
                  color: active ? c.textPrimary : c.textMuted,
                }}
                onMouseEnter={(e) => { if (!active) e.currentTarget.style.color = c.textSecondary; }}
                onMouseLeave={(e) => { if (!active) e.currentTarget.style.color = active ? c.textPrimary : c.textMuted; }}
              >
                {TAB_LABELS[tab]}
                {active && (
                  <div
                    className="absolute bottom-0 left-1/2 -translate-x-1/2 h-[2px] rounded-full"
                    style={{ width: "60%", background: "#4f8ef7" }}
                  />
                )}
              </button>
            );
          })}
        </div>
      )}

      {/* Tab content */}
      <div
        className="flex-1 overflow-hidden flex flex-col min-h-0"
        style={{ background: activeTab === "terminal" && terminalActive ? "#0a0a0c" : undefined }}
      >
        {activeTab === "terminal" && canTerminal && (
          terminalActive ? (
            <div className="flex-1 flex flex-col min-h-0">
              <QueuedPromptsBar
                prompts={queuedPrompts}
                onSendNow={handleSendNow}
                onEdit={handleEditPrompt}
                onRemove={handleRemovePrompt}
              />
              {useTmux && terminalTabs.length > 0 && (
                <div
                  className="flex items-center gap-1 px-2 py-1 shrink-0"
                  style={{ background: "#0a0a0c", borderBottom: `1px solid ${c.border}` }}
                >
                  {terminalTabs.map((w) => {
                    const isActive = w.index === activeTermTab;
                    return (
                      <div
                        key={w.index}
                        className="flex items-center gap-1 rounded px-2 py-0.5 text-[11px] cursor-pointer transition-colors"
                        style={{
                          background: isActive ? "#1a1a1f" : "transparent",
                          color: isActive ? "#e4e4e7" : "#6b7280",
                        }}
                        onClick={() => setActiveTermTab(w.index)}
                        title={w.name}
                      >
                        <span>
                          {w.index === 1 ? "Claude" : w.name || `tab ${w.index}`}
                        </span>
                        {w.index !== 1 && (
                          <button
                            onClick={(e) => {
                              e.stopPropagation();
                              handleCloseTermTab(w.index);
                            }}
                            className="opacity-60 hover:opacity-100 ml-1"
                            style={{ color: "#9ca3af" }}
                            title="Close tab"
                          >
                            ×
                          </button>
                        )}
                      </div>
                    );
                  })}
                  <button
                    onClick={handleAddTermTab}
                    className="ml-1 rounded px-2 py-0.5 text-[11px] hover:opacity-100"
                    style={{ color: "#6b7280", background: "transparent" }}
                    title="New shell tab"
                  >
                    +
                  </button>
                </div>
              )}
              <TerminalView
                ptyId={`term-${card.id}-${activeTermTab}`}
                command={shellCommand}
                initialInput={terminalInput}
                onExit={() => {}}
                writeRef={terminalWriteRef}
                fontSize={terminalFontSize}
              />
            </div>
          ) : (
            <div className="flex flex-col items-center justify-center flex-1 gap-4 p-8">
              <div
                className="w-12 h-12 rounded-2xl flex items-center justify-center"
                style={{ background: c.bgAccent("0.04") }}
              >
                <svg className="w-6 h-6" style={{ color: c.textDim }} fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
                  <path strokeLinecap="round" strokeLinejoin="round" d="m5.25 4.5 7.5 7.5-7.5 7.5m6-15 7.5 7.5-7.5 7.5" />
                </svg>
              </div>
              <div className="text-center">
                <p className="text-[13px] font-medium" style={{ color: c.textSecondary }}>
                  Ready to resume
                </p>
                <p className="text-[12px] mt-1" style={{ color: c.textDim }}>
                  Click Resume to start an interactive Claude session
                </p>
              </div>
            </div>
          )
        )}

        {activeTab === "history" && (
          <div className="overflow-y-auto flex-1 flex flex-col min-h-0">
            <HistoryTab
              turns={turns}
              transcriptPage={transcriptPage}
              loading={loadingTranscript}
              onLoadMore={() => {
                if (sessionId && transcriptPage?.hasMore)
                  loadTranscript(sessionId, transcriptPage.nextOffset, false);
              }}
              searchText={searchText}
              searchMatches={searchMatches}
              currentMatchIdx={currentMatchIdx}
              isSearching={isSearching}
              onSearchChange={setSearchText}
              onNextMatch={() => goToMatch("next")}
              onPrevMatch={() => goToMatch("prev")}
              onCheckpoint={sessionId ? handleCheckpoint : undefined}
            />
          </div>
        )}

        {activeTab === "issue" && issue && (
          <div className="overflow-y-auto flex-1">
            <ContentTab
              title={issue.title ?? `Issue #${issue.number}`}
              body={issue.body}
              url={issue.url}
              onOpenInBrowser={
                projectPath
                  ? () => openGithubIssue(projectPath, issue.number).catch(() => {})
                  : undefined
              }
            />
          </div>
        )}
        {activeTab === "pr" && pr && (
          <div className="overflow-y-auto flex-1">
            <ContentTab
              title={pr.title ?? `PR #${pr.number}`}
              body={pr.body}
              url={pr.url}
              onOpenInBrowser={
                projectPath
                  ? () => openGithubPr(projectPath, pr.number).catch(() => {})
                  : undefined
              }
              mergeAction={
                projectPath && pr.status === "OPEN"
                  ? { onMerge: () => mergePr(projectPath, pr.number), number: pr.number }
                  : undefined
              }
              prMeta={{
                reviewDecision: pr.reviewDecision,
                approvalCount: pr.approvalCount,
                mergeStateStatus: pr.mergeStateStatus,
                checkRuns: pr.checkRuns ?? [],
                unresolvedThreads: pr.unresolvedThreads,
              }}
            />
          </div>
        )}
        {activeTab === "prompt" && card.link.promptBody && (
          <div className="overflow-y-auto flex-1 p-4">
            <div
              className="rounded-xl p-4"
              style={{ background: c.bgAccent("0.03") }}
            >
              <pre
                className="text-[13px] whitespace-pre-wrap break-words leading-[1.65] font-mono"
                style={{ color: c.textSecondary }}
              >
                {card.link.promptBody}
              </pre>
            </div>
          </div>
        )}
      </div>

      {/* Queued prompt dialog */}
      <QueuedPromptDialog
        open={showQueueDialog}
        onClose={() => { setShowQueueDialog(false); setEditingPrompt(null); }}
        onSave={editingPrompt ? handleUpdatePrompt : handleAddPrompt}
        editBody={editingPrompt?.body}
        editSendAuto={editingPrompt?.sendAutomatically}
      />

      {/* Launch confirmation dialog (fresh launches only) */}
      {showLaunchDialog && projectPath && (
        <LaunchConfirmationDialog
          projectPath={projectPath}
          initialPrompt={promptBody ?? ""}
          canCreateWorktree={false}
          initialSkipPermissions={false}
          buildCommand={(f) =>
            isUnixShell
              ? buildInnerBashCmd(projectPath, sessionId ?? null, f.prompt, f.dangerouslySkipPermissions, f.envPrefix)
              : buildInnerCmdShellCmd(projectPath, sessionId ?? null, f.prompt, f.dangerouslySkipPermissions, f.envPrefix)
          }
          onLaunch={(flags) => {
            setLaunchFlags(flags);
            setShowLaunchDialog(false);
            setTerminalActive(true);
          }}
          onCancel={() => setShowLaunchDialog(false)}
        />
      )}
    </div>
  );
}

/* ── Sub-components ──────────────────────────────────────────────── */

const CardMoreMenu = forwardRef<HTMLDivElement, {
  anchorRef: React.RefObject<HTMLButtonElement | null>;
  onClose: () => void;
  onCopy: (label: string, text: string | undefined | null) => void | Promise<void>;
  cardId: string;
  sessionId?: string;
  projectPath?: string;
  branch?: string;
  prUrl?: string;
  worktreePath?: string;
  onRemoveWorktree?: () => void | Promise<void>;
  onFork?: () => void | Promise<void>;
  copiedLabel: string | null;
  themeTokens: ReturnType<typeof t>;
  cardProjectPath?: string;
  availableProjects?: Project[];
  onMoveToProject?: (targetPath: string) => void | Promise<void>;
}>(function CardMoreMenu(
  { anchorRef, onClose, onCopy, cardId, sessionId, projectPath, branch, prUrl, worktreePath, onRemoveWorktree, onFork, copiedLabel, themeTokens: c, cardProjectPath, availableProjects, onMoveToProject },
  ref
) {
  useEffect(() => {
    const onDown = (e: MouseEvent) => {
      const target = e.target as Node;
      if (anchorRef.current?.contains(target)) return;
      // ref is forwarded → can be either object ref or null; only react to outside clicks
      const menuEl = (ref as React.RefObject<HTMLDivElement | null>)?.current;
      if (menuEl?.contains(target)) return;
      onClose();
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        e.stopPropagation();
        onClose();
      }
    };
    window.addEventListener("mousedown", onDown);
    window.addEventListener("keydown", onKey);
    return () => {
      window.removeEventListener("mousedown", onDown);
      window.removeEventListener("keydown", onKey);
    };
  }, [anchorRef, ref, onClose]);

  type Row = { label: string; subtitle?: string; text: string };
  const rows: Row[] = [];
  rows.push({ label: "Card ID", subtitle: cardId, text: cardId });
  if (sessionId) {
    rows.push({ label: "Session ID", subtitle: sessionId, text: sessionId });
    rows.push({
      label: "Resume command",
      subtitle: `claude --resume ${sessionId}`,
      text: `claude --resume ${sessionId}`,
    });
  }
  if (projectPath) rows.push({ label: "Project path", subtitle: projectPath, text: projectPath });
  if (branch) rows.push({ label: "Branch name", subtitle: branch, text: branch });
  if (prUrl) rows.push({ label: "PR URL", subtitle: prUrl, text: prUrl });

  return (
    <div
      ref={ref}
      className="absolute right-0 top-full mt-1.5 min-w-[260px] max-w-[360px] z-50 rounded-xl py-1 shadow-2xl animate-fade-in"
      style={{
        background: c.bgDialog,
        border: `1px solid ${c.borderBright}`,
      }}
    >
      <div
        className="px-3 pt-2 pb-1 text-[10.5px] font-semibold uppercase tracking-wider"
        style={{ color: c.textDim }}
      >
        Copy to clipboard
      </div>
      {rows.map((r) => {
        const justCopied = copiedLabel === r.label;
        return (
          <button
            key={r.label}
            onClick={() => onCopy(r.label, r.text)}
            className="w-full flex items-center gap-2 px-3 py-1.5 text-left transition-colors"
            onMouseEnter={(e) => { e.currentTarget.style.background = c.hoverBg; }}
            onMouseLeave={(e) => { e.currentTarget.style.background = ""; }}
          >
            <span className="w-3.5 h-3.5 flex-shrink-0 flex items-center justify-center" style={{ color: justCopied ? "#3fb950" : c.textDim }}>
              {justCopied ? (
                <svg fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2.5}>
                  <path strokeLinecap="round" strokeLinejoin="round" d="m4.5 12.75 6 6 9-13.5" />
                </svg>
              ) : (
                <svg fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.8}>
                  <path strokeLinecap="round" strokeLinejoin="round" d="M15.75 17.25v3.375c0 .621-.504 1.125-1.125 1.125h-9.75a1.125 1.125 0 0 1-1.125-1.125V7.875c0-.621.504-1.125 1.125-1.125H6.75a9.06 9.06 0 0 1 1.5.124m7.5 10.376h3.375c.621 0 1.125-.504 1.125-1.125V11.25c0-4.46-3.243-8.161-7.5-8.876a9.06 9.06 0 0 0-1.5-.124H9.375c-.621 0-1.125.504-1.125 1.125v3.5m7.5 10.375H9.375a1.125 1.125 0 0 1-1.125-1.125v-9.25m12 6.625v-1.875a3.375 3.375 0 0 0-3.375-3.375h-1.5a1.125 1.125 0 0 1-1.125-1.125v-1.5a3.375 3.375 0 0 0-3.375-3.375H9.75" />
                </svg>
              )}
            </span>
            <span className="flex-1 min-w-0">
              <span className="block text-[12.5px]" style={{ color: c.textPrimary, fontWeight: 500 }}>
                {r.label}
              </span>
              {r.subtitle && (
                <span className="block text-[10.5px] font-mono truncate" style={{ color: c.textDim }}>
                  {r.subtitle}
                </span>
              )}
            </span>
            {justCopied && (
              <span className="text-[10.5px] flex-shrink-0" style={{ color: "#3fb950" }}>Copied!</span>
            )}
          </button>
        );
      })}
      {onFork && (
        <>
          <div className="my-1 mx-2 h-px" style={{ background: c.border }} />
          <button
            onClick={() => onFork()}
            className="w-full flex items-center gap-2 px-3 py-1.5 text-left transition-colors"
            onMouseEnter={(e) => { e.currentTarget.style.background = c.hoverBg; }}
            onMouseLeave={(e) => { e.currentTarget.style.background = ""; }}
          >
            <span className="w-3.5 h-3.5 flex-shrink-0 flex items-center justify-center" style={{ color: "#4f8ef7" }}>
              <svg fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.8}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M6 3v12m0 0a2.25 2.25 0 1 0 0 4.5 2.25 2.25 0 0 0 0-4.5Zm12-9a2.25 2.25 0 1 0 0 4.5 2.25 2.25 0 0 0 0-4.5Zm0 0v6.75a3 3 0 0 1-3 3h-4.5" />
              </svg>
            </span>
            <span className="flex-1 min-w-0">
              <span className="block text-[12.5px]" style={{ color: c.textPrimary, fontWeight: 500 }}>
                Fork session
              </span>
              <span className="block text-[10.5px] truncate" style={{ color: c.textDim }}>
                Duplicate the .jsonl with a new id
              </span>
            </span>
          </button>
        </>
      )}
      {availableProjects && availableProjects.length > 0 && onMoveToProject && (() => {
        const targets = availableProjects.filter((p) => p.path !== cardProjectPath);
        if (targets.length === 0) return null;
        return (
          <>
            <div className="my-1 mx-2 h-px" style={{ background: c.border }} />
            <div
              className="px-3 pt-2 pb-1 text-[10.5px] font-semibold uppercase tracking-wider"
              style={{ color: c.textDim }}
            >
              Move to project
            </div>
            {targets.map((p) => (
              <button
                key={p.path}
                onClick={() => onMoveToProject(p.path)}
                className="w-full flex items-center gap-2 px-3 py-1.5 text-left transition-colors"
                onMouseEnter={(e) => { e.currentTarget.style.background = c.hoverBg; }}
                onMouseLeave={(e) => { e.currentTarget.style.background = ""; }}
              >
                <span className="w-3.5 h-3.5 flex-shrink-0 flex items-center justify-center" style={{ color: c.textDim }}>
                  <svg fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.8}>
                    <path strokeLinecap="round" strokeLinejoin="round" d="M3.75 9.776c.112-.017.227-.026.344-.026h15.812c.117 0 .232.009.344.026m-16.5 0a2.25 2.25 0 0 0-1.883 2.542l.857 6a2.25 2.25 0 0 0 2.227 1.932H19.05a2.25 2.25 0 0 0 2.227-1.932l.857-6a2.25 2.25 0 0 0-1.883-2.542m-16.5 0V6A2.25 2.25 0 0 1 6 3.75h3.879a1.5 1.5 0 0 1 1.06.44l2.122 2.12a1.5 1.5 0 0 0 1.06.44H18A2.25 2.25 0 0 1 20.25 9v.776" />
                  </svg>
                </span>
                <span className="flex-1 min-w-0">
                  <span className="block text-[12.5px]" style={{ color: c.textPrimary, fontWeight: 500 }}>
                    {p.name || p.path}
                  </span>
                  <span className="block text-[10.5px] font-mono truncate" style={{ color: c.textDim }}>
                    {p.path}
                  </span>
                </span>
              </button>
            ))}
          </>
        );
      })()}
      {worktreePath && onRemoveWorktree && (
        <>
          <div className="my-1 mx-2 h-px" style={{ background: c.border }} />
          <button
            onClick={() => onRemoveWorktree()}
            className="w-full flex items-center gap-2 px-3 py-1.5 text-left transition-colors"
            onMouseEnter={(e) => { e.currentTarget.style.background = "rgba(248,81,73,0.08)"; }}
            onMouseLeave={(e) => { e.currentTarget.style.background = ""; }}
          >
            <span className="w-3.5 h-3.5 flex-shrink-0 flex items-center justify-center" style={{ color: "#f85149" }}>
              <svg fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.8}>
                <path strokeLinecap="round" strokeLinejoin="round" d="m14.74 9-.346 9m-4.788 0L9.26 9m9.968-3.21c.342.052.682.107 1.022.166m-1.022-.165L18.16 19.673a2.25 2.25 0 0 1-2.244 2.077H8.084a2.25 2.25 0 0 1-2.244-2.077L4.772 5.79m14.456 0a48.108 48.108 0 0 0-3.478-.397m-12 .562c.34-.059.68-.114 1.022-.165m0 0a48.11 48.11 0 0 1 3.478-.397m7.5 0v-.916c0-1.18-.91-2.164-2.09-2.201a51.964 51.964 0 0 0-3.32 0c-1.18.037-2.09 1.022-2.09 2.201v.916m7.5 0a48.667 48.667 0 0 0-7.5 0" />
              </svg>
            </span>
            <span className="flex-1 min-w-0">
              <span className="block text-[12.5px]" style={{ color: "#f85149", fontWeight: 500 }}>
                Remove worktree
              </span>
              <span className="block text-[10.5px] font-mono truncate" style={{ color: c.textDim }}>
                {worktreePath}
              </span>
            </span>
          </button>
        </>
      )}
    </div>
  );
});

function PrMetaRow({
  meta,
  c,
}: {
  meta: {
    reviewDecision?: string;
    approvalCount?: number;
    mergeStateStatus?: string;
    checkRuns: { name: string; conclusion?: string }[];
    unresolvedThreads?: number;
  };
  c: ReturnType<typeof t>;
}) {
  const checks = meta.checkRuns;
  const checksByConclusion = checks.reduce<Record<string, number>>((acc, r) => {
    const key = r.conclusion ?? "PENDING";
    acc[key] = (acc[key] ?? 0) + 1;
    return acc;
  }, {});
  const failedCount =
    (checksByConclusion["FAILURE"] ?? 0) +
    (checksByConclusion["CANCELLED"] ?? 0) +
    (checksByConclusion["TIMED_OUT"] ?? 0) +
    (checksByConclusion["STARTUP_FAILURE"] ?? 0) +
    (checksByConclusion["ACTION_REQUIRED"] ?? 0);
  const pendingCount =
    (checksByConclusion["PENDING"] ?? 0) +
    (checksByConclusion["QUEUED"] ?? 0) +
    (checksByConclusion["IN_PROGRESS"] ?? 0);
  const successCount = checksByConclusion["SUCCESS"] ?? 0;

  const reviewColor =
    meta.reviewDecision === "APPROVED" ? "#3fb950"
    : meta.reviewDecision === "CHANGES_REQUESTED" ? "#f85149"
    : meta.reviewDecision === "REVIEW_REQUIRED" ? "#d29922"
    : c.textMuted;

  const mergeColor =
    meta.mergeStateStatus === "CLEAN" ? "#3fb950"
    : meta.mergeStateStatus === "BLOCKED" || meta.mergeStateStatus === "DIRTY" ? "#f85149"
    : meta.mergeStateStatus === "UNSTABLE" || meta.mergeStateStatus === "BEHIND" ? "#d29922"
    : c.textMuted;

  if (!meta.reviewDecision && !meta.mergeStateStatus && checks.length === 0 && meta.approvalCount == null) {
    return null;
  }

  return (
    <div className="flex flex-wrap items-center gap-2">
      {meta.reviewDecision && (
        <Chip color={reviewColor} c={c}>
          {meta.reviewDecision.replace(/_/g, " ").toLowerCase()}
          {meta.approvalCount != null && meta.approvalCount > 0 ? ` · ${meta.approvalCount}✓` : ""}
        </Chip>
      )}
      {meta.mergeStateStatus && (
        <Chip color={mergeColor} c={c}>merge: {meta.mergeStateStatus.toLowerCase()}</Chip>
      )}
      {meta.unresolvedThreads != null && meta.unresolvedThreads > 0 && (
        <Chip color="#d29922" c={c} title="Unresolved review threads">
          {meta.unresolvedThreads} unresolved thread{meta.unresolvedThreads === 1 ? "" : "s"}
        </Chip>
      )}
      {checks.length > 0 && (
        <Chip
          color={failedCount > 0 ? "#f85149" : pendingCount > 0 ? "#d29922" : "#3fb950"}
          c={c}
          title={checks.map((r) => `${r.name}: ${r.conclusion ?? "pending"}`).join("\n")}
        >
          {failedCount > 0
            ? `${failedCount}/${checks.length} failing`
            : pendingCount > 0
              ? `${pendingCount}/${checks.length} running`
              : `${successCount}/${checks.length} passing`}
        </Chip>
      )}
    </div>
  );
}

function Chip({
  children,
  color,
  c,
  title,
}: {
  children: React.ReactNode;
  color: string;
  c: ReturnType<typeof t>;
  title?: string;
}) {
  const _ = c; // theme reserved for future per-mode tinting
  return (
    <span
      className="text-[11px] font-semibold px-2 py-0.5 rounded-md cursor-default"
      style={{ color, background: color + "1f", border: `1px solid ${color}33` }}
      title={title}
    >
      {children}
    </span>
  );
}

function MetaBadge({ label, color, theme, title }: { label: string; color: string; theme: string; title?: string }) {
  return (
    <span
      className="text-[11px] font-semibold px-2 py-0.5 rounded-md transition-all duration-150 cursor-default"
      style={{
        color,
        background: color + (theme === "dark" ? "14" : "10"),
      }}
      title={title}
    >
      {label}
    </span>
  );
}

/* ── History Tab with Search ────────────────────────────────────── */

function HistoryTab({ turns, transcriptPage, loading, onLoadMore, searchText, searchMatches, currentMatchIdx, isSearching, onSearchChange, onNextMatch, onPrevMatch, onCheckpoint }: {
  turns: Turn[];
  transcriptPage: TranscriptPage | null;
  loading: boolean;
  onLoadMore: () => void;
  searchText: string;
  searchMatches: number[];
  currentMatchIdx: number;
  isSearching: boolean;
  onSearchChange: (q: string) => void;
  onNextMatch: () => void;
  onPrevMatch: () => void;
  onCheckpoint?: (turnIndex: number) => void | Promise<void>;
}) {
  const { theme } = useTheme();
  const c = t(theme);
  const currentMatchTurnIdx = searchMatches.length > 0 ? searchMatches[currentMatchIdx] : -1;
  const matchRef = useRef<HTMLDivElement>(null);

  // Scroll to current match
  useEffect(() => {
    if (matchRef.current) {
      matchRef.current.scrollIntoView({ behavior: "smooth", block: "center" });
    }
  }, [currentMatchIdx, searchMatches]);

  return (
    <>
      {/* Search bar */}
      <div
        className="shrink-0 flex items-center gap-2 px-3 py-2"
        style={{ background: "#141416", borderBottom: `1px solid rgba(255,255,255,0.04)` }}
      >
        <svg className="w-3.5 h-3.5 shrink-0" style={{ color: "#555" }} fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
          <path strokeLinecap="round" strokeLinejoin="round" d="m21 21-5.197-5.197m0 0A7.5 7.5 0 1 0 5.196 5.196a7.5 7.5 0 0 0 10.607 10.607Z" />
        </svg>
        <input
          type="text"
          value={searchText}
          onChange={(e) => onSearchChange(e.target.value)}
          placeholder="Search transcript..."
          className="flex-1 bg-transparent text-[12px] font-mono outline-none"
          style={{ color: "#e4e4e7" }}
          onKeyDown={(e) => {
            if (e.key === "Enter") {
              if (e.shiftKey) onPrevMatch();
              else onNextMatch();
            }
          }}
        />
        {searchText.length >= 2 && (
          <div className="flex items-center gap-1.5 shrink-0">
            {isSearching ? (
              <div className="w-3 h-3 border border-[#4f8ef7] border-t-transparent rounded-full animate-spin" />
            ) : (
              <span className="text-[11px] font-mono" style={{ color: "#666" }}>
                {searchMatches.length > 0
                  ? `${currentMatchIdx + 1}/${searchMatches.length}`
                  : "0 results"}
              </span>
            )}
            <button
              onClick={onPrevMatch}
              disabled={searchMatches.length === 0}
              className="p-0.5 rounded transition-colors disabled:opacity-30"
              style={{ color: "#888" }}
              title="Previous match (Shift+Enter)"
            >
              <svg className="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2.5}>
                <path strokeLinecap="round" strokeLinejoin="round" d="m4.5 15.75 7.5-7.5 7.5 7.5" />
              </svg>
            </button>
            <button
              onClick={onNextMatch}
              disabled={searchMatches.length === 0}
              className="p-0.5 rounded transition-colors disabled:opacity-30"
              style={{ color: "#888" }}
              title="Next match (Enter)"
            >
              <svg className="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2.5}>
                <path strokeLinecap="round" strokeLinejoin="round" d="m19.5 8.25-7.5 7.5-7.5-7.5" />
              </svg>
            </button>
            <button
              onClick={() => onSearchChange("")}
              className="p-0.5 rounded transition-colors"
              style={{ color: "#666" }}
              title="Clear search"
            >
              <svg className="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2.5}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M6 18 18 6M6 6l12 12" />
              </svg>
            </button>
          </div>
        )}
      </div>

      {/* Turns list */}
      {loading && turns.length === 0 ? (
        <div className="flex items-center justify-center p-12" style={{ background: "#141416" }}>
          <div className="w-5 h-5 border-2 border-[#4f8ef7] border-t-transparent rounded-full animate-spin" />
        </div>
      ) : turns.length === 0 ? (
        <div className="flex flex-col items-center justify-center p-12 gap-2" style={{ background: "#141416" }}>
          <svg className="w-8 h-8 text-[#555]" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1}>
            <path strokeLinecap="round" strokeLinejoin="round" d="M7.5 8.25h9m-9 3H12m-9.75 1.51c0 1.6 1.123 2.994 2.707 3.227 1.087.16 2.185.283 3.293.369V21l4.076-4.076a1.526 1.526 0 0 1 1.037-.443 48.2 48.2 0 0 0 5.887-.512c1.584-.233 2.707-1.626 2.707-3.228V6.741c0-1.602-1.123-2.995-2.707-3.228A48.394 48.394 0 0 0 12 3c-2.392 0-4.744.175-7.043.513C3.373 3.746 2.25 5.14 2.25 6.741v6.018Z" />
          </svg>
          <span className="text-[12px] text-[#555]">No conversation history</span>
        </div>
      ) : (
        <div
          className="flex flex-col px-3 pt-2 pb-3 gap-0.5 font-mono overflow-y-auto flex-1"
          style={{ background: "#141416" }}
        >
          {turns.map((turn) => {
            const isMatch = searchMatches.includes(turn.index);
            const isCurrent = turn.index === currentMatchTurnIdx;
            return (
              <div key={turn.index} ref={isCurrent ? matchRef : undefined}>
                <TurnItem
                  turn={turn}
                  searchQuery={searchText.length >= 2 ? searchText : ""}
                  isSearchMatch={isMatch}
                  isCurrentMatch={isCurrent}
                  onCheckpoint={onCheckpoint}
                />
              </div>
            );
          })}
          {transcriptPage?.hasMore && (
            <button
              onClick={onLoadMore}
              disabled={loading}
              className="mt-2 py-2 rounded-lg text-[11px] font-mono font-medium transition-all duration-150 disabled:opacity-40"
              style={{ color: "#666", background: "rgba(255,255,255,0.03)" }}
              onMouseEnter={(e) => { e.currentTarget.style.background = "rgba(255,255,255,0.06)"; }}
              onMouseLeave={(e) => { e.currentTarget.style.background = "rgba(255,255,255,0.03)"; }}
            >
              {loading ? "Loading..." : `Load more (${transcriptPage.totalTurns - turns.length} remaining)`}
            </button>
          )}
        </div>
      )}
    </>
  );
}

/* ── Turn rendering with search highlighting ────────────────────── */

function TurnItem({ turn, searchQuery, isSearchMatch, isCurrentMatch, onCheckpoint }: {
  turn: Turn;
  searchQuery: string;
  isSearchMatch: boolean;
  isCurrentMatch: boolean;
  onCheckpoint?: (turnIndex: number) => void | Promise<void>;
}) {
  const isUser = turn.role === "user";
  const blocks = turn.contentBlocks;
  const [hovered, setHovered] = useState(false);

  let borderStyle: string | undefined;
  if (isCurrentMatch) borderStyle = "rgba(249,115,22,0.5)";
  else if (isSearchMatch) borderStyle = "rgba(234,179,8,0.3)";

  return (
    <div
      className="rounded px-2 py-1 transition-colors duration-100 relative group"
      style={{
        background: isCurrentMatch
          ? "rgba(249,115,22,0.08)"
          : isSearchMatch
          ? "rgba(234,179,8,0.05)"
          : isUser && blocks.some(b => b.kind === "text")
          ? "rgba(255,255,255,0.04)"
          : undefined,
        outline: borderStyle ? `1px solid ${borderStyle}` : undefined,
      }}
      onMouseEnter={(e) => {
        setHovered(true);
        if (!isCurrentMatch && !isSearchMatch) e.currentTarget.style.background = "rgba(255,255,255,0.06)";
      }}
      onMouseLeave={(e) => {
        setHovered(false);
        if (!isCurrentMatch && !isSearchMatch) {
          e.currentTarget.style.background = isUser && blocks.some(b => b.kind === "text") ? "rgba(255,255,255,0.04)" : "";
        }
      }}
    >
      {onCheckpoint && hovered && (
        <button
          onClick={(e) => { e.stopPropagation(); onCheckpoint(turn.index); }}
          className="absolute right-1 top-1 px-1.5 py-0.5 rounded text-[10px] font-mono font-medium transition-colors"
          style={{
            background: "rgba(163,113,247,0.18)",
            color: "#c9a5ff",
            border: "1px solid rgba(163,113,247,0.35)",
          }}
          title={`Truncate session to keep through turn ${turn.index + 1}. Original is backed up as <session>.jsonl.bkp.`}
        >
          ✂ Checkpoint
        </button>
      )}
      {blocks.length > 0 ? (
        blocks.map((block, i) => (
          <BlockLine key={i} block={block} isUser={isUser} isFirst={i === 0} searchQuery={searchQuery} />
        ))
      ) : (
        <div className="flex gap-1.5 items-start">
          <span className="text-[12px] leading-[1.6] shrink-0" style={{ color: isUser ? "#3fb950" : "#d4d4d4" }}>
            {isUser ? "\u276F" : "\u25CF"}
          </span>
          <span className="text-[12px] leading-[1.6] line-clamp-6" style={{ color: isUser ? "#e4e4e7" : "rgba(220,220,220,0.85)" }}>
            <HighlightedText text={turn.textPreview || "(empty)"} query={searchQuery} />
          </span>
        </div>
      )}
    </div>
  );
}

function BlockLine({ block, isUser, isFirst, searchQuery }: {
  block: { kind: string; text: string };
  isUser: boolean;
  isFirst: boolean;
  searchQuery: string;
}) {
  if (block.kind === "text") {
    const trimmed = block.text.trim();
    if (!trimmed) return null;
    return (
      <div className="flex gap-1.5 items-start">
        <span className="text-[12px] leading-[1.6] shrink-0" style={{ color: isUser ? "#3fb950" : "#d4d4d4" }}>
          {isFirst ? (isUser ? "\u276F" : "\u25CF") : "\u00A0\u00A0"}
        </span>
        <span
          className="text-[12px] leading-[1.6]"
          style={{
            color: isUser ? "#e4e4e7" : "rgba(220,220,220,0.85)",
            display: "-webkit-box",
            WebkitLineClamp: isUser ? undefined : 20,
            WebkitBoxOrient: "vertical",
            overflow: "hidden",
          }}
        >
          <HighlightedText text={trimmed} query={searchQuery} />
        </span>
      </div>
    );
  }

  if (block.kind === "tool_use") {
    const name = block.text.split("(")[0] || block.text;
    const args = block.text.includes("(") ? block.text.slice(block.text.indexOf("(")) : "";
    return (
      <div className="flex gap-1.5 items-start">
        <span className="text-[12px] leading-[1.6] shrink-0 text-[#3fb950]">{"\u00A0\u00A0\u25CF"}</span>
        <span className="text-[12px] leading-[1.6]">
          <span style={{ color: "rgba(63,185,80,0.8)" }}><HighlightedText text={name} query={searchQuery} /></span>
          {args && <span className="line-clamp-2" style={{ color: "#555" }}>{args}</span>}
        </span>
      </div>
    );
  }

  if (block.kind === "tool_result") {
    return (
      <div className="flex gap-1.5 items-start">
        <span className="text-[12px] leading-[1.6] shrink-0" style={{ color: "#444" }}>{"\u00A0\u00A0\u23BF"}</span>
        <span className="text-[12px] leading-[1.6] line-clamp-3" style={{ color: "#444" }}>
          <HighlightedText text={block.text} query={searchQuery} />
        </span>
      </div>
    );
  }

  if (block.kind === "thinking") {
    return (
      <div className="flex gap-1.5 items-start">
        <span className="text-[12px] leading-[1.6] shrink-0" style={{ color: "#444" }}>{"\u00A0\u00A0\u2234"}</span>
        <span className="text-[12px] leading-[1.6] italic" style={{ color: "#444" }}>Thinking...</span>
      </div>
    );
  }

  return null;
}

/* ── Search text highlighting ───────────────────────────────────── */

function HighlightedText({ text, query }: { text: string; query: string }) {
  if (!query || query.length < 2) return <>{text}</>;

  const lowerText = text.toLowerCase();
  const lowerQuery = query.toLowerCase();
  const parts: { text: string; highlight: boolean }[] = [];
  let lastIdx = 0;

  let idx = lowerText.indexOf(lowerQuery, lastIdx);
  while (idx !== -1) {
    if (idx > lastIdx) {
      parts.push({ text: text.slice(lastIdx, idx), highlight: false });
    }
    parts.push({ text: text.slice(idx, idx + query.length), highlight: true });
    lastIdx = idx + query.length;
    idx = lowerText.indexOf(lowerQuery, lastIdx);
  }

  if (lastIdx < text.length) {
    parts.push({ text: text.slice(lastIdx), highlight: false });
  }

  if (parts.length === 0) return <>{text}</>;

  return (
    <>
      {parts.map((part, i) =>
        part.highlight ? (
          <mark
            key={i}
            style={{
              background: "rgba(234,179,8,0.35)",
              color: "inherit",
              borderRadius: 2,
              padding: "0 1px",
            }}
          >
            {part.text}
          </mark>
        ) : (
          <span key={i}>{part.text}</span>
        )
      )}
    </>
  );
}

/* ── Content Tab (Issue / PR) ───────────────────────────────────── */

function ContentTab({
  title,
  body,
  url,
  onOpenInBrowser,
  mergeAction,
  prMeta,
}: {
  title: string;
  body?: string;
  url?: string;
  onOpenInBrowser?: () => void;
  mergeAction?: { onMerge: () => Promise<string>; number: number };
  prMeta?: {
    reviewDecision?: string;
    approvalCount?: number;
    mergeStateStatus?: string;
    checkRuns: { name: string; conclusion?: string }[];
    unresolvedThreads?: number;
  };
}) {
  const { theme } = useTheme();
  const c = t(theme);
  const [merging, setMerging] = useState(false);
  const [mergeError, setMergeError] = useState<string | null>(null);
  const [mergeOk, setMergeOk] = useState<string | null>(null);

  const handleMerge = async () => {
    if (!mergeAction) return;
    setMergeError(null);
    setMergeOk(null);
    setMerging(true);
    try {
      const out = await mergeAction.onMerge();
      setMergeOk(out || `Merged PR #${mergeAction.number}`);
    } catch (e) {
      setMergeError(String(e));
    } finally {
      setMerging(false);
    }
  };

  const handleOpen = () => {
    if (onOpenInBrowser) onOpenInBrowser();
    else if (url) window.open(url, "_blank", "noreferrer");
  };

  return (
    <div className="p-5 flex flex-col gap-4">
      <div className="flex items-start justify-between gap-3">
        <h3 className="text-[15px] font-semibold leading-snug" style={{ color: c.textPrimary }}>{title}</h3>
        <div className="flex items-center gap-1 shrink-0">
          {mergeAction && (
            <button
              onClick={handleMerge}
              disabled={merging}
              className="flex items-center gap-1.5 px-2.5 py-1 rounded-lg text-[12px] font-semibold transition-all duration-150 disabled:opacity-60"
              style={{
                background: "#a371f7",
                color: "#fff",
              }}
              onMouseEnter={(e) => { if (!merging) e.currentTarget.style.background = "#b27cff"; }}
              onMouseLeave={(e) => { if (!merging) e.currentTarget.style.background = "#a371f7"; }}
              title={`Run the configured merge command for PR #${mergeAction.number}`}
            >
              {merging ? (
                <div className="w-3 h-3 border-[1.5px] border-white border-t-transparent rounded-full animate-spin" />
              ) : (
                <svg className="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                  <path strokeLinecap="round" strokeLinejoin="round" d="M9 6V18a2.25 2.25 0 0 0 2.25 2.25h.5A2.25 2.25 0 0 0 14 18.5V14a2.25 2.25 0 0 1 2.25-2.25H18M9 6a2.25 2.25 0 1 1 0 4.5 2.25 2.25 0 0 1 0-4.5ZM18 11.75a2.25 2.25 0 1 1 0 4.5 2.25 2.25 0 0 1 0-4.5Z" />
                </svg>
              )}
              {merging ? "Merging…" : "Merge"}
            </button>
          )}
          {(url || onOpenInBrowser) && (
            <button
              onClick={handleOpen}
              className="p-1.5 rounded-lg transition-all duration-150"
              style={{ color: "#4f8ef7" }}
              onMouseEnter={(e) => { e.currentTarget.style.background = "rgba(79,142,247,0.08)"; }}
              onMouseLeave={(e) => { e.currentTarget.style.background = ""; }}
              title="Open in browser"
            >
              <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M10 6H6a2 2 0 0 0-2 2v10a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-4M14 4h6m0 0v6m0-6L10 14" />
              </svg>
            </button>
          )}
        </div>
      </div>

      {prMeta && <PrMetaRow meta={prMeta} c={c} />}

      {mergeOk && (
        <div
          className="rounded-lg px-3 py-2 text-[12px]"
          style={{ background: "rgba(63,185,80,0.10)", color: "#3fb950", border: "1px solid rgba(63,185,80,0.30)" }}
        >
          {mergeOk}
        </div>
      )}
      {mergeError && (
        <div
          className="rounded-lg px-3 py-2 text-[12px]"
          style={{ background: "rgba(248,81,73,0.10)", color: "#f85149", border: "1px solid rgba(248,81,73,0.30)" }}
        >
          {mergeError}
        </div>
      )}

      {body ? (
        <div className="text-[13px] leading-[1.7] whitespace-pre-wrap break-words" style={{ color: c.textSecondary }}>
          {body}
        </div>
      ) : (
        <p className="text-[13px]" style={{ color: c.textDim }}>No description</p>
      )}
    </div>
  );
}
