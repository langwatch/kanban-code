import Foundation

/// Supported coding assistants that can be managed by Kanban Code.
public enum CodingAssistant: String, Codable, Sendable, CaseIterable {
    case claude
    case gemini
    case mastracode

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .gemini: "Gemini CLI"
        case .mastracode: "Mastra Code"
        }
    }

    public var cliCommand: String {
        switch self {
        case .claude: "claude"
        case .gemini: "gemini"
        case .mastracode: "mastracode"
        }
    }

    /// Text shown in the TUI when the assistant is ready for input.
    public var promptCharacter: String {
        switch self {
        case .claude: "❯"
        case .gemini: "Type your message"
        case .mastracode: "> "
        }
    }

    /// CLI flag to auto-approve all tool calls.
    public var autoApproveFlag: String {
        switch self {
        case .claude: "--dangerously-skip-permissions"
        case .gemini: "--yolo"
        case .mastracode: "/yolo"
        }
    }

    /// CLI flag to resume a session.
    public var resumeFlag: String? {
        switch self {
        case .claude, .gemini: "--resume"
        case .mastracode: nil
        }
    }

    /// Whether this assistant supports git worktree creation.
    public var supportsWorktree: Bool {
        switch self {
        case .claude: true
        case .gemini: false
        case .mastracode: false
        }
    }

    /// Whether this assistant supports image upload via clipboard paste.
    public var supportsImageUpload: Bool {
        switch self {
        case .claude: true
        case .gemini: false
        case .mastracode: false
        }
    }

    /// Name of the config directory under $HOME (may include nested directories).
    public var configDirName: String {
        switch self {
        case .claude: ".claude"
        case .gemini: ".gemini"
        case .mastracode: "Library/Application Support/mastracode"
        }
    }

    /// Symbol used to mark user turns in conversation history UI.
    public var historyPromptSymbol: String {
        switch self {
        case .claude: "❯"
        case .gemini: "✦"
        case .mastracode: ">"
        }
    }

    /// npm package name for installation.
    public var installCommand: String {
        switch self {
        case .claude: "npm install -g @anthropic-ai/claude-code"
        case .gemini: "npm install -g @google/gemini-cli"
        case .mastracode: "npm install -g mastracode"
        }
    }

    /// Whether prompt submission should use bracketed paste instead of per-key send.
    public var usesPastedPrompt: Bool {
        switch self {
        case .claude: false
        case .gemini, .mastracode: true
        }
    }

    /// Whether remote execution needs the wrapper directory prepended to PATH.
    public var needsRemotePathShim: Bool {
        switch self {
        case .claude: false
        case .gemini, .mastracode: true
        }
    }

    /// Session storage path suffix when file-backed.
    public var sessionFileExtension: String? {
        switch self {
        case .claude: ".jsonl"
        case .gemini: ".json"
        case .mastracode: nil
        }
    }
}
