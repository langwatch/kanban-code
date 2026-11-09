import Foundation

/// `kanban-code-export`: prints a session as the Markdown the app copies with
/// "Copy conversation as Markdown". The `kanban export` CLI resolves the card
/// and runs this, so both share `ConversationMarkdownExporter`.
///
///   kanban-code-export --card <id> [--home <dir>] [--path <transcript>]
///   kanban-code-export --path <transcript> [--assistant claude|codex|gemini] [--title <t>] [--session-id <id>]
public struct ConversationExportCommand: Sendable, Equatable {
    public var cardId: String?
    public var home: String?
    public var sessionPath: String?
    public var assistant: CodingAssistant?
    public var title: String?
    public var sessionId: String?

    public init(
        cardId: String? = nil,
        home: String? = nil,
        sessionPath: String? = nil,
        assistant: CodingAssistant? = nil,
        title: String? = nil,
        sessionId: String? = nil
    ) {
        self.cardId = cardId
        self.home = home
        self.sessionPath = sessionPath
        self.assistant = assistant
        self.title = title
        self.sessionId = sessionId
    }

    public struct Failure: Error, Equatable, CustomStringConvertible {
        public let description: String
        public init(_ description: String) { self.description = description }
    }

    public static let usage = """
    usage: kanban-code-export --card <id> [--home <dir>] [--path <transcript>]
           kanban-code-export --path <transcript> [--assistant claude|codex|gemini] [--title <title>] [--session-id <id>]
    """

    public static func parse(_ args: [String]) throws -> ConversationExportCommand {
        var command = ConversationExportCommand()
        var index = 0
        func value() throws -> String {
            index += 1
            guard index < args.count else { throw Failure("missing value for \(args[index - 1])") }
            return args[index]
        }
        while index < args.count {
            switch args[index] {
            case "--card": command.cardId = try value()
            case "--home": command.home = try value()
            case "--path": command.sessionPath = try value()
            case "--title": command.title = try value()
            case "--session-id": command.sessionId = try value()
            case "--assistant":
                let raw = try value()
                guard let assistant = CodingAssistant(rawValue: raw) else {
                    throw Failure("unknown assistant \(raw), expected claude, codex or gemini")
                }
                command.assistant = assistant
            default: throw Failure("unknown argument \(args[index])")
            }
            index += 1
        }
        guard command.cardId != nil || command.sessionPath != nil else {
            throw Failure("pass --card or --path")
        }
        return command
    }

    /// The exporter inputs: from the card in `links.json`, each overridable by a flag.
    public struct Resolved: Sendable, Equatable {
        public var title: String
        public var assistant: CodingAssistant
        public var sessionId: String?
        public var sessionPath: String
    }

    public func resolve() async throws -> Resolved {
        var link: Link?
        if let cardId {
            link = try await CoordinationStore(basePath: home).linkById(cardId)
            guard link != nil else { throw Failure("no card \(cardId)") }
        }
        let path: String
        if let sessionPath {
            path = sessionPath
        } else if let link, let found = transcriptPath(for: link) {
            path = found
        } else {
            throw Failure("card \(cardId ?? "") has no session transcript on this machine")
        }
        guard FileManager.default.fileExists(atPath: path) else {
            throw Failure("transcript not found: \(path)")
        }
        return Resolved(
            title: title ?? link?.displayTitle ?? "",
            assistant: assistant ?? link?.effectiveAssistant ?? Self.guessAssistant(path: path),
            sessionId: sessionId ?? link?.sessionLink?.sessionId,
            sessionPath: path
        )
    }

    /// The card's transcript on this machine: its own path, the copy this master
    /// mirrors for a card another master owns, or a Claude session file found
    /// by id under `~/.claude/projects`.
    func transcriptPath(for link: Link) -> String? {
        Self.transcriptPath(for: link, kanbanHome: home)
    }

    /// The card's transcript on this machine, as `transcriptPath(for:)`
    /// finds it, with `kanbanHome` defaulting to `~/.kanban-code`.
    public static func transcriptPath(
        for link: Link, kanbanHome home: String?,
        userHome: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let fm = FileManager.default
        if let path = link.sessionLink?.sessionPath, fm.fileExists(atPath: path) { return path }
        guard let sessionId = link.sessionLink?.sessionId, !sessionId.isEmpty else { return nil }
        if let owner = link.ownerMachine {
            let kanbanHome = home ?? (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code")
            let mirror = PeerTranscriptMirror.mirrorPath(
                directory: (kanbanHome as NSString).appendingPathComponent("peers"),
                machineId: owner,
                sessionId: sessionId
            )
            if fm.fileExists(atPath: mirror) { return mirror }
        }
        // In the app or server: its Claude config folders. In the export
        // helper, its own process: this process's CLAUDE_CONFIG_DIR, then
        // every folder the settings name.
        let kanbanHome = home ?? (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code")
        let layout: ClaudeConfigLayout
        if ClaudeConfigDirectories.settingsPath
            == ((kanbanHome as NSString).appendingPathComponent("settings.json") as NSString).standardizingPath {
            layout = ClaudeConfigDirectories.current
        } else {
            let accounts = FileManager.default.contents(atPath: kanbanHome + "/settings.json")
                .flatMap { try? JSONDecoder().decode(Settings.self, from: $0) }?.claudeAccounts ?? []
            layout = ClaudeConfigLayout(home: userHome, environment: environment, accounts: accounts)
        }
        for projects in layout.projectsDirectories {
            for dir in (try? fm.contentsOfDirectory(atPath: projects)) ?? [] {
                let candidate = "\(projects)/\(dir)/\(sessionId).jsonl"
                if fm.fileExists(atPath: candidate) { return candidate }
            }
        }
        return nil
    }

    /// Resolves the inputs and streams the Markdown to `write`.
    public func run(write: (String) -> Void) async throws {
        let resolved = try await resolve()
        try await ConversationMarkdownExporter.streamMarkdown(
            title: resolved.title,
            assistant: resolved.assistant,
            sessionId: resolved.sessionId,
            sessionPath: resolved.sessionPath,
            sessionStore: Self.sessionStore(for: resolved.assistant),
            write: write
        )
    }

    static func sessionStore(for assistant: CodingAssistant) -> SessionStore {
        switch assistant {
        case .claude: ClaudeCodeSessionStore()
        case .codex: CodexSessionStore()
        case .gemini: GeminiSessionStore()
        }
    }

    /// Codex writes `rollout-*.jsonl` under `~/.codex/sessions`, Gemini writes
    /// `.json` session files; everything else is a Claude transcript.
    static func guessAssistant(path: String) -> CodingAssistant {
        let name = (path as NSString).lastPathComponent
        if name.hasPrefix("rollout-") || path.contains("/.codex/") { return .codex }
        if name.hasSuffix(".json") || path.contains("/.gemini/") { return .gemini }
        return .claude
    }
}
