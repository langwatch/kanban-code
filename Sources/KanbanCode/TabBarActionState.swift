/// Pure-value snapshot of tab bar state, used to derive which tmux session
/// the action buttons ("Copy tmux attach", "Queue Prompt") should target.
///
/// Extracted from CardDetailView so the logic is unit-testable.
struct TabBarActionState {
    /// The currently selected terminal session name, or nil when Claude tab is selected.
    let selectedTerminalSession: String?
    /// The currently selected browser tab id, or nil when no browser tab is selected.
    let selectedBrowserTabId: String?
    /// The live Claude tmux session name, if the primary session is alive.
    let claudeTmuxSession: String?
    /// All live shell session names (extras + shell-only primary).
    let shellSessions: [String]

    /// All live tmux sessions (Claude + shells).
    var allLiveSessions: [String] {
        var sessions: [String] = []
        if let claude = claudeTmuxSession { sessions.append(claude) }
        sessions.append(contentsOf: shellSessions)
        return sessions
    }

    /// Whether the Claude tab is selected (no terminal or browser tab selected).
    var isClaudeTabSelected: Bool {
        selectedTerminalSession == nil && selectedBrowserTabId == nil
    }

    /// The tmux session to show in the terminal content area.
    var effectiveActiveSession: String? {
        if isClaudeTabSelected { return claudeTmuxSession }
        return selectedTerminalSession
    }

    /// The tmux session to use for action buttons (Copy tmux attach, Queue Prompt).
    /// When a browser tab is selected, falls back to any live tmux session so
    /// the buttons remain visible and functional.
    var tmuxSessionForActions: String? {
        effectiveActiveSession ?? allLiveSessions.first
    }

    /// Whether the action buttons should be visible.
    var showActionButtons: Bool {
        tmuxSessionForActions != nil
    }

    /// Whether a browser tab is currently active.
    var isBrowserTabSelected: Bool {
        selectedBrowserTabId != nil
    }
}
