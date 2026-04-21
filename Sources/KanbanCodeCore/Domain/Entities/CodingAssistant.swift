import Foundation

/// Supported coding assistants that can be managed by Kanban Code.
public enum CodingAssistant: String, Codable, Sendable, CaseIterable {
    case claude
    case gemini
    case codex

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .gemini: "Gemini CLI"
        case .codex: "Codex CLI"
        }
    }

    public var cliCommand: String {
        switch self {
        case .claude: "claude"
        case .gemini: "gemini"
        case .codex: "codex"
        }
    }

    /// Text shown in the TUI when the assistant is ready for input.
    public var promptCharacter: String {
        switch self {
        case .claude: "❯"
        case .gemini: "Type your message"
        case .codex: "›"
        }
    }

    /// CLI flag to auto-approve all tool calls.
    public var autoApproveFlag: String {
        switch self {
        case .claude: "--dangerously-skip-permissions"
        case .gemini: "--yolo"
        case .codex: "--dangerously-bypass-approvals-and-sandbox"
        }
    }

    /// CLI flag to resume a session.
    public var resumeFlag: String {
        switch self {
        case .claude, .gemini: "--resume"
        case .codex: "resume"
        }
    }

    /// Whether this assistant supports git worktree creation.
    public var supportsWorktree: Bool {
        switch self {
        case .claude: true
        case .gemini, .codex: false
        }
    }

    /// Whether this assistant supports image upload via clipboard paste.
    public var supportsImageUpload: Bool {
        switch self {
        case .claude: true
        case .gemini, .codex: false
        }
    }

    /// Whether this assistant exposes a hooks settings file Kanban can install into.
    public var supportsHooks: Bool {
        switch self {
        case .claude, .gemini: true
        case .codex: false
        }
    }

    /// Whether prompt text should be submitted with bracketed paste semantics.
    public var submitsPromptWithPaste: Bool {
        switch self {
        case .claude: false
        case .gemini, .codex: true
        }
    }

    /// Whether remote execution needs Kanban's bash wrapper first on PATH.
    public var requiresRemotePathWrapper: Bool {
        switch self {
        case .claude: false
        case .gemini, .codex: true
        }
    }

    /// Native session file extension used by this assistant.
    public var sessionFileExtension: String {
        switch self {
        case .claude, .codex: "jsonl"
        case .gemini: "json"
        }
    }

    /// Extra flags required for interactive startup in a tmux pane.
    public var interactiveLaunchFlags: [String] {
        switch self {
        case .claude, .gemini: []
        case .codex: ["--no-alt-screen"]
        }
    }

    /// Name of the config directory under $HOME (e.g. ".claude", ".gemini").
    public var configDirName: String {
        switch self {
        case .claude: ".claude"
        case .gemini: ".gemini"
        case .codex: ".codex"
        }
    }

    /// Symbol used to mark user turns in conversation history UI.
    public var historyPromptSymbol: String {
        switch self {
        case .claude: "❯"
        case .gemini: "✦"
        case .codex: "›"
        }
    }

    /// npm package name for installation.
    public var installCommand: String {
        switch self {
        case .claude: "npm install -g @anthropic-ai/claude-code"
        case .gemini: "npm install -g @google/gemini-cli"
        case .codex: "npm install -g @openai/codex"
        }
    }

    public func launchCommand(skipPermissions: Bool, worktreeName: String?) -> String {
        var parts = [cliCommand]
        if skipPermissions { parts.append(autoApproveFlag) }
        parts.append(contentsOf: interactiveLaunchFlags)
        if supportsWorktree, let worktreeName {
            if worktreeName.isEmpty {
                parts.append("--worktree")
            } else {
                parts.append("--worktree")
                parts.append(worktreeName)
            }
        }
        return parts.joined(separator: " ")
    }

    public func resumeCommand(sessionId: String, skipPermissions: Bool) -> String {
        switch self {
        case .codex:
            var parts = [cliCommand, "resume"]
            if skipPermissions { parts.append(autoApproveFlag) }
            parts.append(contentsOf: interactiveLaunchFlags)
            parts.append(sessionId)
            return parts.joined(separator: " ")
        case .claude, .gemini:
            var parts = [cliCommand]
            if skipPermissions { parts.append(autoApproveFlag) }
            parts.append(resumeFlag)
            parts.append(sessionId)
            return parts.joined(separator: " ")
        }
    }
}
