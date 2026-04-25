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

    /// True if the given session file path lives under this assistant's config directory.
    /// Used by per-assistant activity detectors so they ignore paths that belong to
    /// another assistant — otherwise, Codex's mtime-only polling (which has no way
    /// of knowing a file is actually a Claude transcript) will fabricate
    /// `.activelyWorking` for any recently-modified Claude session, and the composite
    /// detector's highest-priority merge will let that win over the Claude detector's
    /// correct state. Symptom: archived Claude cards un-archive themselves.
    public func owns(sessionPath: String) -> Bool {
        sessionPath.contains("/\(configDirName)/")
    }

    /// The assistant whose config directory contains this session path, or nil
    /// if the path is not under any known assistant directory (e.g. test fixtures).
    public static func owner(ofSessionPath path: String) -> CodingAssistant? {
        for assistant in CodingAssistant.allCases where assistant.owns(sessionPath: path) {
            return assistant
        }
        return nil
    }

    /// True if another assistant's config dir appears in this path. Detectors use
    /// this to drop clearly cross-assistant paths from polling while still
    /// accepting unowned test fixture paths.
    public func ownedByOther(sessionPath: String) -> Bool {
        guard let owner = CodingAssistant.owner(ofSessionPath: sessionPath) else { return false }
        return owner != self
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

    /// Environment variable used to override the API base URL for this assistant's backend.
    public var baseURLEnvKey: String? {
        switch self {
        case .claude: "ANTHROPIC_BASE_URL"
        case .codex:  "OPENAI_BASE_URL"
        case .gemini: nil
        }
    }

    /// Builds the tmux launch command, optionally wrapping with an `APIService`.
    ///
    /// Without service: `claude --dangerously-skip-permissions --worktree foo`
    /// With service:    `ollama launch claude --model qwen3 -- --dangerously-skip-permissions --worktree foo`
    public func launchCommand(skipPermissions: Bool, worktreeName: String?, service: APIService? = nil) -> String {
        var prefix: [String] = []
        if let launcher = service?.launcherPrefix { prefix.append(contentsOf: launcher.split(separator: " ").map(String.init)) }
        prefix.append(cliCommand)
        if let model = service?.modelFlag { prefix += ["--model", model] }

        var flags: [String] = []
        if skipPermissions { flags.append(autoApproveFlag) }
        flags.append(contentsOf: interactiveLaunchFlags)
        if supportsWorktree, let worktreeName {
            flags += worktreeName.isEmpty ? ["--worktree"] : ["--worktree", worktreeName]
        }

        let sep: [String] = service?.needsSeparator == true ? ["--"] : []
        return (prefix + sep + flags).joined(separator: " ")
    }

    /// Builds the tmux resume command, optionally wrapping with an `APIService`.
    ///
    /// Without service: `claude --dangerously-skip-permissions --resume <id>`
    /// With service:    `ollama launch claude --model qwen3 -- --dangerously-skip-permissions --resume <id>`
    public func resumeCommand(sessionId: String, skipPermissions: Bool, service: APIService? = nil) -> String {
        var prefix: [String] = []
        if let launcher = service?.launcherPrefix { prefix.append(contentsOf: launcher.split(separator: " ").map(String.init)) }
        prefix.append(cliCommand)
        if let model = service?.modelFlag { prefix += ["--model", model] }
        let sep: [String] = service?.needsSeparator == true ? ["--"] : []

        switch self {
        case .codex:
            // "resume" subcommand goes after -- when a separator is present
            var flags = ["resume"]
            if skipPermissions { flags.append(autoApproveFlag) }
            flags.append(contentsOf: interactiveLaunchFlags)
            flags.append(sessionId)
            return (prefix + sep + flags).joined(separator: " ")
        case .claude, .gemini:
            var flags: [String] = []
            if skipPermissions { flags.append(autoApproveFlag) }
            flags.append(resumeFlag)
            flags.append(sessionId)
            return (prefix + sep + flags).joined(separator: " ")
        }
    }
}
