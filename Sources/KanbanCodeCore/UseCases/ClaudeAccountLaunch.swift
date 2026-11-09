import Foundation

/// The Claude config folder a card's local session runs with, and how the
/// launch makes it so.
///
/// - A new card in a folder an account claims runs with that account's
///   folder. A folder no account claims is left to the shell (direnv, the
///   login environment), as before accounts existed.
/// - A resume runs with the folder its transcript is in: `claude --resume`
///   finds a session only there.
/// - `~/.claude` is reached by unsetting `CLAUDE_CONFIG_DIR` (`preamble`),
///   never by setting it (see `ClaudeConfigLayout.launchEnvironment`).
public struct ClaudeAccountLaunch: Sendable, Equatable {
    /// The folder Kanban picked, nil when it leaves the choice to the shell.
    public var directory: String?
    /// `CLAUDE_CONFIG_DIR` when `directory` is not `~/.claude`.
    public var environment: [String: String]
    /// The session must run without `CLAUDE_CONFIG_DIR`, whatever its shell
    /// or the tmux server carries.
    public var unsetsConfigDirectory: Bool

    public static let shellDecides = ClaudeAccountLaunch(directory: nil, environment: [:], unsetsConfigDirectory: false)

    init(directory: String?, environment: [String: String], unsetsConfigDirectory: Bool) {
        self.directory = directory
        self.environment = environment
        self.unsetsConfigDirectory = unsetsConfigDirectory
    }

    init(directory: String, layout: ClaudeConfigLayout) {
        let environment = layout.launchEnvironment(directory: directory)
        self.init(
            directory: directory, environment: environment,
            unsetsConfigDirectory: environment.isEmpty && !layout.isStandardOnly)
    }

    /// A new session of `assistant` in `projectPath`.
    public static func forNewSession(
        assistant: CodingAssistant, isLocal: Bool, projectPath: String, layout: ClaudeConfigLayout
    ) -> ClaudeAccountLaunch {
        guard assistant == .claude, isLocal,
              let account = layout.account(forPath: projectPath) else { return .shellDecides }
        return ClaudeAccountLaunch(directory: account.configDirectory, layout: layout)
    }

    /// A resume of `sessionId`, whose transcript was last seen at
    /// `sessionPath`, in `projectPath`.
    public static func forResume(
        assistant: CodingAssistant, isLocal: Bool, sessionId: String, sessionPath: String?,
        projectPath: String, layout: ClaudeConfigLayout
    ) -> ClaudeAccountLaunch {
        guard assistant == .claude, isLocal else { return .shellDecides }
        if let directory = transcriptDirectory(sessionId: sessionId, sessionPath: sessionPath, layout: layout) {
            return ClaudeAccountLaunch(directory: directory, layout: layout)
        }
        return forNewSession(assistant: assistant, isLocal: isLocal, projectPath: projectPath, layout: layout)
    }

    /// The config folder holding the transcript: the configured folder
    /// whose `projects/` holds `sessionPath`, the folder above a
    /// `projects/<key>/<id>.jsonl` path that is no longer configured, or
    /// the configured folder that has `<id>.jsonl` when no path is known.
    static func transcriptDirectory(sessionId: String, sessionPath: String?, layout: ClaudeConfigLayout) -> String? {
        let fm = FileManager.default
        if let sessionPath, fm.fileExists(atPath: sessionPath) {
            if let known = layout.directory(containingSession: sessionPath) { return known }
            let projects = ((sessionPath as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
            if (projects as NSString).lastPathComponent == "projects" {
                return (projects as NSString).deletingLastPathComponent
            }
            return nil
        }
        guard !sessionId.isEmpty, !sessionId.contains("/") else { return nil }
        for directory in layout.directories {
            let projects = directory + "/projects"
            for key in (try? fm.contentsOfDirectory(atPath: projects)) ?? []
            where fm.fileExists(atPath: "\(projects)/\(key)/\(sessionId).jsonl") {
                return directory
            }
        }
        return nil
    }

    /// The projects folders the new session's transcript may appear in.
    public func projectsDirectoriesToWatch(layout: ClaudeConfigLayout) -> [String] {
        if let directory { return [directory + "/projects"] }
        return layout.projectsDirectories
    }

    /// The shell step the launch runs before the command when the session
    /// must not inherit a `CLAUDE_CONFIG_DIR` (the pane's shell, direnv or
    /// the tmux server may carry one). A shell builtin, not `env -u`: the
    /// command stays a word the shell resolves, so an alias or function
    /// named `claude` (Claude Code's local install) keeps working, and a
    /// launch command of the user's own is covered too. `shell` is the
    /// pane's shell. fish has no `unset`, and its `set -e` would erase a
    /// universal variable for good: only the global one goes (an inherited
    /// or direnv value), a universal one stays and wins.
    public func preamble(shell: String?) -> String? {
        guard unsetsConfigDirectory else { return nil }
        if let shell, (shell as NSString).lastPathComponent == "fish" {
            return "begin; set -eg CLAUDE_CONFIG_DIR; true; end"
        }
        return "unset CLAUDE_CONFIG_DIR"
    }
}
