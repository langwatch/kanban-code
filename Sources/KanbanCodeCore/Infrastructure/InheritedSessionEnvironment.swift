import Foundation

/// The variables an agent session sets for the commands it runs, and the
/// Anthropic key variables a shell may carry. An app
/// launched from such a session (`make run-app` in a card's shell) inherits
/// them, and passes them on to every session it starts: rush then files a
/// card's session under the one that launched the app (RUSH_SESSION), and
/// Claude Code takes a card's session for that one's child.
public enum InheritedSessionEnvironment {
    static let names: Set<String> = [
        "RUSH_SESSION", "KANBAN_CARD_ID", "KANBAN_CARD_TOKEN",
        "CLAUDECODE", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SESSION_ID",
        "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SESSION_ATTENDED", "CLAUDE_CODE_EXECPATH",
        "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN", "CLAUDE_CODE_TMPDIR",
        "CLAUDE_PID", "CLAUDE_JOB_DIR", "CLAUDE_ENV_FILE",
        // A shell that held an Anthropic API key would make every session
        // the app starts bill that key instead of the signed-in account.
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL",
    ]

    /// The variables a card's session gets from the tmux session itself
    /// (`new-session -e`), never typed into its pane.
    public static let sessionOwned: Set<String> = ["KANBAN_CARD_ID", "KANBAN_CARD_TOKEN"]

    /// The names in `environment` that came from the session the app was
    /// launched in. The temporary folder variables count when they point
    /// into a rush session's own folder.
    public static func inherited(in environment: [String: String]) -> [String] {
        var out = environment.keys.filter { names.contains($0) }
        for name in temporaryFolderNames {
            if let tmp = environment[name], isSessionFolder(tmp) { out.append(name) }
        }
        return out.sorted()
    }

    static let temporaryFolderNames = ["TMPDIR", "TMP", "TEMP"]

    /// A folder under a rush (or agtop) session: `~/.config/{rush,agtop}/sessions/<id>/…`.
    static func isSessionFolder(_ path: String) -> Bool {
        path.contains("/.config/agtop/sessions/") || path.contains("/.config/rush/sessions/")
    }

    /// One tmux invocation that removes the inherited variables from the
    /// server's global environment. A tmux server keeps the environment of
    /// the process that started it, so a server first started from an agent's
    /// shell would give every later pane that agent's card and session.
    public static func tmuxUnsetArguments(serverTMPDIR: String?) -> [String] {
        var names = names.sorted()
        if let tmp = serverTMPDIR, isSessionFolder(tmp) { names += temporaryFolderNames }
        var args: [String] = []
        for name in names {
            if !args.isEmpty { args.append(";") }
            args += ["set-environment", "-g", "-u", name]
        }
        return args
    }

    /// Takes the inherited variables out of this process's environment, so
    /// nothing it starts gets them. TMPDIR goes back to the user's own.
    public static func scrub() {
        let found = inherited(in: ProcessInfo.processInfo.environment)
        for name in found {
            unsetenv(name)
        }
        #if os(macOS)
        if found.contains("TMPDIR") {
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            if confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0 {
                setenv("TMPDIR", String(cString: buffer), 1)
            }
        }
        #endif
        if !found.isEmpty {
            KanbanCodeLog.info("env", "Dropped variables inherited from the agent session that launched the app: \(found.joined(separator: " "))")
        }
    }
}
